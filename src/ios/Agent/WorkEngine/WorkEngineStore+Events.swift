//
//  WorkEngineStore+Events.swift
//  Minis - WorkEngine
//
//  Atomic transitions, event replay, recovery, and derived snapshots.
//

import Foundation
import SQLite3

enum WorkEngineStoreError: Error, Equatable {
    case targetNotFound(WorkLevel, String)
    case invalidTransition(from: WorkStatus, to: WorkStatus)
    case stepCompletionRejected(String)
    case failureReasonRequired(targetId: String)
    case eventLogGap(Int64)
    case sqlite(String)
}

extension WorkEngineStore {

    @discardableResult
    func applyTransition(level: WorkLevel,
                         targetId: String,
                         toStatus: WorkStatus,
                         source: String,
                         note: String? = nil,
                         actorId: String,
                         at: Date = Date()) throws -> WorkEvent {
        guard level != .project else {
            throw WorkEngineStoreError.targetNotFound(.project, targetId)
        }
        let fromStatus = try currentStatus(level: level, targetId: targetId)
        guard WorkEngineStateMachine.canTransition(fromStatus, toStatus) else {
            throw WorkEngineStoreError.invalidTransition(from: fromStatus, to: toStatus)
        }
        if level == .step, let step = step(id: targetId) {
            if toStatus == .done && !WorkEngineStateMachine.canMarkStepDone(step) {
                throw WorkEngineStoreError.stepCompletionRejected(targetId)
            }
            if toStatus == .failed && !WorkEngineStateMachine.canMarkStepFailed(step) {
                throw WorkEngineStoreError.failureReasonRequired(targetId: targetId)
            }
        }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw WorkEngineStoreError.sqlite("Could not begin transition transaction")
        }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        let provisional = WorkEvent(
            seq: 0, level: level, targetId: targetId, fromStatus: fromStatus,
            toStatus: toStatus, source: source, note: note, at: at, actorId: actorId
        )
        try insertEvent(provisional)
        try updateStatus(level: level, id: targetId, status: toStatus, at: at)
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw WorkEngineStoreError.sqlite("Could not commit transition")
        }
        committed = true
        return WorkEvent(
            seq: sqlite3_last_insert_rowid(db), level: level, targetId: targetId,
            fromStatus: fromStatus, toStatus: toStatus, source: source,
            note: note, at: at, actorId: actorId
        )
    }

    func listEvents(targetId: String? = nil, afterSeq: Int64 = 0) -> [WorkEvent] {
        var sql = "SELECT seq, level, target_id, from_status, to_status, source, note, at, actor_id FROM work_events"
        var clauses: [String] = []
        if targetId != nil { clauses.append("target_id = ?") }
        if afterSeq > 0 { clauses.append("seq > ?") }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY seq"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var index: Int32 = 1
        if let targetId {
            bindText(stmt, index, targetId)
            index += 1
        }
        if afterSeq > 0 { bindInt64(stmt, index, afterSeq) }
        var events: [WorkEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW, let stmt {
            events.append(WorkEvent(
                seq: sqlite3_column_int64(stmt, 0),
                level: WorkLevel(rawValue: Self.colText(stmt, 1)) ?? .step,
                targetId: Self.colText(stmt, 2),
                fromStatus: WorkStatus(rawValue: Self.colText(stmt, 3)) ?? .pending,
                toStatus: WorkStatus(rawValue: Self.colText(stmt, 4)) ?? .pending,
                source: Self.colText(stmt, 5),
                note: Self.colTextOpt(stmt, 6),
                at: Self.colDate(stmt, 7),
                actorId: Self.colText(stmt, 8)
            ))
        }
        return events
    }

    func listEvents(projectId: String) -> [WorkEvent] {
        let ids = Set(listTasks(projectId: projectId).flatMap { task in
            [task.id] + listPhases(taskId: task.id).flatMap { phase in
                [phase.id] + listSteps(phaseId: phase.id).map(\.id)
            }
        })
        return listEvents().filter { idsForProject($0.targetId, ids: projectTargetIds(projectId)) }
    }

    func replayEvents(projectId: String) throws -> [String: WorkStatus] {
        var statuses = try currentStatuses(projectId: projectId)
        var firstEvent: Set<String> = []
        for event in listEvents(projectId: projectId) {
            if !firstTargets.contains(event.targetId) {
                statuses[event.targetId] = event.fromStatus
                firstTargets.insert(event.targetId)
            }
            guard statuses[event.targetId] == event.fromStatus else {
                throw WorkEngineStoreError.eventLogGap(event.seq)
            }
            statuses[event.targetId] = event.toStatus
        }
        return statuses
    }

    func recoverFromEventLog(projectId: String) throws -> WorkProjectSnapshot {
        let events = listEvents(projectId: projectId)
        let statuses = try replayEvents(projectId: projectId)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw WorkEngineStoreError.sqlite("Could not begin recovery")
        }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        for event in events {
            if let status = statuses[event.targetId] {
                try updateStatusOnly(level: event.level, targetId: event.targetId, status: status)
            }
        }
        committed = sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK
        guard committed else { throw WorkEngineStoreError.sqlite("Recovery commit failed") }
        return try snapshot(projectId: projectId)
    }

    func snapshot(projectId: String) throws -> WorkProjectSnapshot {
        guard let project = project(id: projectId) else {
            throw WorkEngineStoreError.targetNotFound(.project, projectId)
        }
        let tasks = listTasks(projectId: projectId)
        let taskSnapshots = tasks.map { task in
            let phases = listPhases(taskId: task.id).map { phase in
                let steps = listSteps(phaseId: phase.id)
                return WorkPhaseSnapshot(phase: phase, steps: steps, progress: WorkProgress.of(steps.map(\.status)))
            }
            return WorkTaskSnapshot(task: task, phases: phases, progress: WorkProgress.of(phases.map(\.status)))
        }
        return WorkProjectSnapshot(project: project, tasks: taskSnapshots, progress: WorkProgress.of(tasks.map(\.status)))
    }
}
