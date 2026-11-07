//
//  WorkEngineStore+Phases.swift
//  Minis - WorkEngine
//
//  Phase persistence. Status changes remain exclusive to the event log.
//

import Foundation
import SQLite3

extension WorkEngineStore {

    static func phaseRow(_ stmt: OpaquePointer) -> WorkPhase {
        WorkPhase(
            id: colText(stmt, 0),
            taskId: colText(stmt, 1),
            name: colText(stmt, 2),
            status: WorkStatus(rawValue: colText(stmt, 3)) ?? .pending,
            sortIndex: colInt(stmt, 4),
            createdAt: colDate(stmt, 5),
            updatedAt: colDate(stmt, 6),
            finishedAt: colDateOpt(stmt, 7)
        )
    }

    @discardableResult
    func createPhase(taskId: String, name: String, sortIndex: Int? = nil) -> WorkPhase {
        let now = Date()
        let phase = WorkPhase(
            id: UUID().uuidString,
            taskId: taskId,
            name: name,
            status: .pending,
            sortIndex: sortIndex ?? nextSortIndex(
                table: "work_phases", parentColumn: "task_id", parentId: taskId
            ),
            createdAt: now,
            updatedAt: now,
            finishedAt: nil
        )
        let sql = """
            INSERT INTO work_phases
                (id, task_id, name, status, sort_index, created_at, updated_at, finished_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("[WorkEngine] createPhase prepare failed")
            return phase
        }
        bindText(stmt, 1, phase.id)
        bindText(stmt, 2, phase.taskId)
        bindText(stmt, 3, phase.name)
        bindText(stmt, 4, phase.status.rawValue)
        bindInt(stmt, 5, phase.sortIndex)
        bindDouble(stmt, 6, phase.createdAt.timeIntervalSince1970)
        bindDouble(stmt, 7, phase.updatedAt.timeIntervalSince1970)
        if sqlite3_step(stmt) != SQLITE_DONE {
            logger.error("[WorkEngine] createPhase step failed")
        }
        return phase
    }

    func phase(id: String) -> WorkPhase? {
        let sql = """
            SELECT id, task_id, name, status, sort_index, created_at, updated_at, finished_at
            FROM work_phases WHERE id = ?
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW, let stmt else { return nil }
        return Self.phaseRow(stmt)
    }

    func listPhases(taskId: String) -> [WorkPhase] {
        let sql = """
            SELECT id, task_id, name, status, sort_index, created_at, updated_at, finished_at
            FROM work_phases WHERE task_id = ? ORDER BY sort_index, created_at, id
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bindText(stmt, 1, taskId)
        var phases: [WorkPhase] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let stmt { phases.append(Self.phaseRow(stmt)) }
        }
        return phases
    }

    @discardableResult
    func updatePhase(_ phase: WorkPhase) -> Bool {
        let sql = "UPDATE work_phases SET name = ?, sort_index = ?, updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        bindText(stmt, 1, phase.name)
        bindInt(stmt, 2, phase.sortIndex)
        bindDouble(stmt, 3, Date().timeIntervalSince1970)
        bindText(stmt, 4, phase.id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    @discardableResult
    func deletePhase(id: String) -> Bool {
        deleteRow(table: "work_phases", id: id)
    }
}
