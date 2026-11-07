//
//  WorkEngineStore+Steps.swift
//  Minis - WorkEngine
//
//  Step persistence and evidence attachment.
//

import Foundation
import SQLite3

extension WorkEngineStore {

    static func stepRow(_ stmt: OpaquePointer) -> WorkStep {
        WorkStep(
            id: colText(stmt, 0),
            phaseId: colText(stmt, 1),
            name: colText(stmt, 2),
            status: WorkStatus(rawValue: colText(stmt, 3)) ?? .pending,
            sortIndex: colInt(stmt, 4),
            currentAction: colTextOpt(stmt, 5),
            evidence: colTextOpt(stmt, 6).flatMap { decodeJSON(StepEvidence.self, $0) },
            failureReason: colTextOpt(stmt, 7),
            startedAt: colDateOpt(stmt, 8),
            finishedAt: colDateOpt(stmt, 9),
            createdAt: colDate(stmt, 10),
            updatedAt: colDate(stmt, 11)
        )
    }

    @discardableResult
    func createStep(phaseId: String, name: String, sortIndex: Int? = nil) -> WorkStep {
        let now = Date()
        let step = WorkStep(
            id: UUID().uuidString,
            phaseId: phaseId,
            name: name,
            status: .pending,
            sortIndex: sortIndex ?? nextSortIndex(
                table: "work_steps", parentColumn: "phase_id", parentId: phaseId
            ),
            currentAction: nil,
            evidence: nil,
            failureReason: nil,
            startedAt: nil,
            finishedAt: nil,
            createdAt: now,
            updatedAt: now
        )
        let sql = """
            INSERT INTO work_steps
                (id, phase_id, name, status, sort_index, current_action, evidence,
                 failure_reason, started_at, finished_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL, ?, ?)
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("[WorkEngine] createStep prepare failed")
            return step
        }
        bindText(stmt, 1, step.id)
        bindText(stmt, 2, step.phaseId)
        bindText(stmt, 3, step.name)
        bindText(stmt, 4, step.status.rawValue)
        bindInt(stmt, 5, step.sortIndex)
        bindDouble(stmt, 6, step.createdAt.timeIntervalSince1970)
        bindDouble(stmt, 7, step.updatedAt.timeIntervalSince1970)
        if sqlite3_step(stmt) != SQLITE_DONE {
            logger.error("[WorkEngine] createStep step failed")
        }
        return step
    }

    func step(id: String) -> WorkStep? {
        let sql = """
            SELECT id, phase_id, name, status, sort_index, current_action, evidence,
                   failure_reason, started_at, finished_at, created_at, updated_at
            FROM work_steps WHERE id = ?
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW, let stmt else { return nil }
        return Self.stepRow(stmt)
    }

    func listSteps(phaseId: String) -> [WorkStep] {
        let sql = """
            SELECT id, phase_id, name, status, sort_index, current_action, evidence,
                   failure_reason, started_at, finished_at, created_at, updated_at
            FROM work_steps WHERE phase_id = ? ORDER BY sort_index, created_at, id
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bindText(stmt, 1, phaseId)
        var steps: [WorkStep] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let stmt { steps.append(Self.stepRow(stmt)) }
        }
        return steps
    }

    @discardableResult
    func updateStep(_ step: WorkStep) -> Bool {
        let sql = """
            UPDATE work_steps SET name = ?, sort_index = ?, current_action = ?,
                evidence = ?, failure_reason = ?, updated_at = ? WHERE id = ?
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        bindText(stmt, 1, step.name)
        bindInt(stmt, 2, step.sortIndex)
        bindTextOpt(stmt, 3, step.currentAction)
        bindTextOpt(stmt, 4, step.failureReason)
        bindDouble(stmt, 5, Date().timeIntervalSince1970)
        bindText(stmt, 6, step.id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    @discardableResult
    func attachEvidence(stepId: String, evidence: StepEvidence) -> Bool {
        let sql = "UPDATE work_steps SET evidence = ?, updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        bindText(stmt, 1, Self.encodeJSON(evidence))
        bindDouble(stmt, 2, Date().timeIntervalSince1970)
        bindText(stmt, 3, stepId)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    @discardableResult
    func deleteStep(id: String) -> Bool {
        deleteRow(table: "work_steps", id: id)
    }
}
