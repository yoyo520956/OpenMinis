//
//  WorkEngineStore+Tasks.swift
//  Minis - WorkEngine
//
//  Task persistence and dependency serialization.
//

import Foundation
import SQLite3

extension WorkEngineStore {

    static func taskRow(_ stmt: OpaquePointer) -> WorkTask {
        WorkTask(
            id: colText(stmt, 0),
            projectId: colText(stmt, 1),
            name: colText(stmt, 2),
            desc: colTextOpt(stmt, 3),
            status: WorkStatus(rawValue: colText(stmt, 4)) ?? .pending,
            sortIndex: colInt(stmt, 5),
            blockedByTaskIds: decodeJSON([String].self, colTextOpt(stmt, 6) ?? "[]") ?? [],
            createdAt: colDate(stmt, 7),
            updatedAt: colDate(stmt, 8),
            finishedAt: colDateOpt(stmt, 9)
        )
    }

    @discardableResult
    func createTask(projectId: String,
                    name: String,
                    desc: String? = nil,
                    sortIndex: Int? = nil,
                    blockedByTaskIds: [String] = []) -> WorkTask {
        let now = Date()
        let task = WorkTask(
            id: UUID().uuidString,
            projectId: projectId,
            name: name,
            desc: desc,
            status: .pending,
                        sortIndex: sortIndex ?? nextSortIndex(
                table: "work_tasks", parentColumn: "project_id", parentId: projectId
            ),
            blockedByTaskIds: blockedByTaskIds,
            createdAt: now,
            updatedAt: now,
            finishedAt: nil
        )
        let sql = """
            INSERT INTO work_tasks
                (id, project_id, name, desc_text, status, sort_index,
                 blocked_by_task_ids, created_at, updated_at, finished_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("[WorkEngine] createTask prepare failed")
            return task
        }
        bindText(stmt, 1, task.id)
        bindText(stmt, 2, task.projectId)
        bindText(stmt, 3, task.name)
        bindTextOpt(stmt, 4, task.desc)
        bindText(stmt, 5, task.status.rawValue)
        bindInt(stmt, 6, task.sortIndex)
        bindText(stmt, 7, Self.encodeJSON(task.blockedByTaskIds))
        bindDouble(stmt, 8, task.createdAt.timeIntervalSince1970)
        bindDouble(stmt, 9, task.updatedAt.timeIntervalSince1970)
        if sqlite3_step(stmt) != SQLITE_DONE {
            logger.error("[WorkEngine] createTask step failed")
        }
        return task
    }

    func task(id: String) -> WorkTask? {
        let sql = """
            SELECT id, project_id, name, desc_text, status, sort_index,
                   blocked_by_task_ids, created_at, updated_at, finished_at
            FROM work_tasks WHERE id = ?
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW, let stmt else { return nil }
        return Self.taskRow(stmt)
    }

    func listTasks(projectId: String) -> [WorkTask] {
        let sql = """
            SELECT id, project_id, name, desc_text, status, sort_index,
                   blocked_by_task_ids, created_at, updated_at, finished_at
            FROM work_tasks WHERE project_id = ? ORDER BY sort_index, created_at, id
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bindText(stmt, 1, projectId)
        var tasks: [WorkTask] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let stmt { tasks.append(Self.taskRow(stmt)) }
        }
        return tasks
    }

    @discardableResult
    func updateTask(_ task: WorkTask) -> Bool {
        let sql = """
            UPDATE work_tasks SET name = ?, desc_text = ?, sort_index = ?,
                blocked_by_task_ids = ?, updated_at = ? WHERE id = ?
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        bindText(stmt, 1, task.name)
        bindTextOpt(stmt, 2, task.desc)
        bindInt(stmt, 3, task.sortIndex)
        bindText(stmt, 4, Self.encodeJSON(task.blockedByTaskIds))
        bindDouble(stmt, 5, Date().timeIntervalSince1970)
        bindText(stmt, 6, task.id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    @discardableResult
    func deleteTask(id: String) -> Bool {
        deleteRow(table: "work_tasks", id: id)
    }

    func nextSortIndex(table: String, parentColumn: String, parentId: String) -> Int {
        let sql = "SELECT COALESCE(MAX(sort_index) + 1, 0) FROM \(table) WHERE \(parentColumn) = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        bindText(stmt, 1, parentId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Self.colInt(stmt, 0)
    }

    func deleteRow(table: String, id: String) -> Bool {
        let allowedTables: Set<String> = ["work_tasks", "work_phases", "work_steps"]
        guard allowedTables.contains(table) else { return false }
        let sql = "DELETE FROM \(table) WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }
}
