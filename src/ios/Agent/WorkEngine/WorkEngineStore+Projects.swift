//
//  WorkEngineStore+Projects.swift
//  Minis - WorkEngine
//
//  Project rows: create / read / update / archive / delete.
//

import Foundation
import SQLite3

extension WorkEngineStore {

    private static let projectColumns = """
        id, name, desc_text, instructions, workspace_path, git_remote_url,
        git_default_branch, archived_at, created_at, updated_at
        """

    static func projectRow(_ stmt: OpaquePointer) -> WorkProject {
        WorkProject(
            id: colText(stmt, 0),
            name: colText(stmt, 1),
            desc: colTextOpt(stmt, 2),
            instructions: colTextOpt(stmt, 3),
            workspacePath: colTextOpt(stmt, 4),
            gitRemoteURL: colTextOpt(stmt, 5),
            gitDefaultBranch: colTextOpt(stmt, 6),
            archivedAt: colDateOpt(stmt, 7),
            createdAt: colDate(stmt, 8),
            updatedAt: colDate(stmt, 9)
        )
    }

    @discardableResult
    func createProject(name: String,
                       desc: String? = nil,
                       instructions: String? = nil,
                       workspacePath: String? = nil,
                       gitRemoteURL: String? = nil,
                       gitDefaultBranch: String? = nil) -> WorkProject {
        let now = Date()
        let project = WorkProject(
            id: UUID().uuidString,
            name: name,
            desc: desc,
            instructions: instructions,
            workspacePath: workspacePath,
            gitRemoteURL: gitRemoteURL,
            gitDefaultBranch: gitDefaultBranch,
            archivedAt: nil,
            createdAt: now,
            updatedAt: now
        )
        let sql = """
            INSERT INTO work_projects
                (id, name, desc_text, instructions, workspace_path,
                 git_remote_url, git_default_branch, archived_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("[WorkEngine] createProject prepare failed")
            return project
        }
        bindText(stmt, 1, project.id)
        bindText(stmt, 2, project.name)
        bindTextOpt(stmt, 3, project.desc)
        bindTextOpt(stmt, 4, project.instructions)
        bindTextOpt(stmt, 5, project.workspacePath)
        bindTextOpt(stmt, 6, project.gitRemoteURL)
        bindTextOpt(stmt, 7, project.gitDefaultBranch)
        bindDouble(stmt, 8, project.createdAt.timeIntervalSince1970)
        bindDouble(stmt, 9, project.updatedAt.timeIntervalSince1970)
        if sqlite3_step(stmt) != SQLITE_DONE {
            logger.error("[WorkEngine] createProject step failed")
        }
        return project
    }

    func project(id: String) -> WorkProject? {
        let sql = "SELECT \(Self.projectColumns) FROM work_projects WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("[WorkEngine] project prepare failed")
            return nil
        }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW, let stmt else { return nil }
        return Self.projectRow(stmt)
    }

    func listProjects(includeArchived: Bool = false) -> [WorkProject] {
        let filter = includeArchived ? "" : "WHERE archived_at IS NULL"
        let sql = """
            SELECT \(Self.projectColumns) FROM work_projects
            \(filter) ORDER BY archived_at IS NOT NULL, updated_at DESC, id
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("[WorkEngine] listProjects prepare failed")
            return []
        }
        var projects: [WorkProject] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let stmt { projects.append(Self.projectRow(stmt)) }
        }
        return projects
    }

    @discardableResult
    func updateProject(_ project: WorkProject) -> Bool {
        let sql = """
            UPDATE work_projects SET
                name = ?, desc_text = ?, instructions = ?, workspace_path = ?,
                git_remote_url = ?, git_default_branch = ?, archived_at = ?, updated_at = ?
            WHERE id = ?
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        bindText(stmt, 1, project.name)
        bindTextOpt(stmt, 2, project.desc)
        bindTextOpt(stmt, 3, project.instructions)
        bindTextOpt(stmt, 4, project.workspacePath)
        bindTextOpt(stmt, 5, project.gitRemoteURL)
        if let archivedAt = project.archivedAt {
            bindDouble(stmt, 7, archivedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        bindDouble(stmt, 8, Date().timeIntervalSince1970)
        bindText(stmt, 9, project.id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    @discardableResult
    func archiveProject(id: String, archived: Bool = true) -> Bool {
        let now = Date().timeIntervalSince1970
        let sql = "UPDATE work_projects SET archived_at = ?, updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        if archived {
            bindDouble(stmt, 1, now)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        bindDouble(stmt, 2, now)
        bindText(stmt, 3, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    @discardableResult
    func deleteProject(id: String) -> Bool {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        var committed = false
        defer {
            if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        }
        // Chat sessions outlive a project; only their project link is removed.
        var unlink: OpaquePointer?
        if sqlite3_prepare_v2(
            db,
            "UPDATE sessions SET work_project_id = NULL WHERE work_project_id = ?",
            -1,
            &unlink,
            nil
        ) == SQLITE_OK {
            bindText(unlink, 1, id)
            guard sqlite3_step(unlink) == SQLITE_DONE else {
                sqlite3_finalize(unlink)
                return false
            }
        }
        sqlite3_finalize(unlink)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM work_projects WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        bindText(stmt, 1, id)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        let deleted = sqlite3_changes(db) > 0
        sqlite3_finalize(stmt)
        guard ok && deleted else { return false }
        committed = sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK
        return committed
    }

    func listSessions(projectId: String) -> [ChatSession] {
        let sql = """
            SELECT id, title, model_id, created_at, updated_at, category, source,
                   last_synced_at, remote_origin_device_id, pinned_at, folder_id,
                   parent_session_id, parent_tool_use_id, preview_text
            FROM sessions WHERE work_project_id = ? ORDER BY updated_at DESC, id
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bindText(stmt, 1, projectId)
        var rows: [ChatSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row = ChatSession(
                id: Self.colText(stmt, 0),
                title: Self.colTextOpt(stmt, 1),
                category: Self.colTextOpt(stmt, 2),
                modelId: Self.colText(stmt, 3),
                createdAt: Self.colDate(stmt, 4),
                updatedAt: Self.colDate(stmt, 5),
                lastMessage: Self.colTextOpt(stmt, 6),
                source: Self.colTextOpt(stmt, 7),
                lastSyncedAt: Self.colDateOpt(stmt, 8),
                remoteDeviceId: Self.colTextOpt(stmt, 9),
                pinnedAt: Self.colDateOpt(stmt, 10),
                folderId: Self.colTextOpt(stmt, 11)
            )
            row.parentSessionId = Self.colTextOpt(stmt, 12)
            row.parentToolUseId = Self.colTextOpt(stmt, 13)
            rows.append(row)
        }
        return rows
    }
}
