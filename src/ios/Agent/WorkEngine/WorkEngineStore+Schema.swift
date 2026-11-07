//
//  WorkEngineStore+Schema.swift
//  Minis - WorkEngine
//
//  Schema creation. All statements are idempotent so an existing minis.db is
//  never rebuilt or migrated destructively on upgrade.
//

import Foundation
import SQLite3

extension WorkEngineStore {

    func createTables() {
        // idempotent, so simply run every time
        exec("""
            CREATE TABLE IF NOT EXISTS work_events (
                seq        INTEGER PRIMARY KEY AUTOINCREMENT,
                level      TEXT NOT NULL,
                target_id  TEXT NOT NULL,
                from_status TEXT NOT NULL,
                to_status  TEXT NOT NULL,
                source     TEXT NOT NULL,
                note       TEXT,
                at         REAL NOT NULL,
                actor_id   TEXT NOT NULL
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_work_events_target ON work_events(target_id, seq)")

        exec("""
            CREATE TABLE IF NOT EXISTS work_projects (
                id                 TEXT PRIMARY KEY,
                name               TEXT NOT NULL,
                desc_text          TEXT,
                instructions       TEXT,
                workspace_path     TEXT,
                git_remote_url     TEXT,
                git_default_branch TEXT,
                archived_at        REAL,
                created_at         REAL NOT NULL,
                updated_at         REAL NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS work_tasks (
                id                  TEXT PRIMARY KEY,
                project_id          TEXT NOT NULL REFERENCES work_projects(id) ON DELETE CASCADE,
                name                TEXT NOT NULL,
                desc_text           TEXT,
                status              TEXT NOT NULL,
                sort_index          INTEGER NOT NULL,
                blocked_by_task_ids TEXT,
                created_at          REAL NOT NULL,
                updated_at          REAL NOT NULL,
                finished_at         REAL
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_work_tasks_project ON work_tasks(project_id, sort_index)")

        exec("""
            CREATE TABLE IF NOT EXISTS work_phases (
                id          TEXT PRIMARY KEY,
                task_id     TEXT NOT NULL REFERENCES work_tasks(id) ON DELETE CASCADE,
                name        TEXT NOT NULL,
                status      TEXT NOT NULL,
                sort_index  INTEGER NOT NULL,
                created_at  REAL NOT NULL,
                updated_at  REAL NOT NULL,
                finished_at REAL
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_work_phases_task ON work_phases(task_id, sort_index)")

        exec("""
            CREATE TABLE IF NOT EXISTS work_steps (
                id            TEXT PRIMARY KEY,
                phase_id      TEXT NOT NULL REFERENCES work_phases(id) ON DELETE CASCADE,
                name          TEXT NOT NULL,
                status        TEXT NOT NULL,
                sort_index    INTEGER NOT NULL,
                current_action TEXT,
                evidence      TEXT,
                failure_reason TEXT,
                started_at    REAL,
                finished_at   REAL,
                created_at    REAL NOT NULL,
                updated_at    REAL NOT NULL
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_work_steps_phase ON work_steps(phase_id, sort_index)")

        // A conversation may point at one project. NULL = not project-scoped.
        // `sessions` already exists (created by ChatStore); add the column if
        // the database predates the WorkEngine upgrade.
        addColumnIfMissing(table: "sessions", column: "work_project_id", definition: "TEXT")
        exec("CREATE INDEX IF NOT EXISTS idx_sessions_work_project ON sessions(work_project_id)")

        logger.info("[WorkEngine] schema ready")
    }

    private func columnExists(table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cName = sqlite3_column_text(stmt, 1) {
                if String(cString: cName) == column { return true }
            }
        }
        return false
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) {
        if columnExists(table: table, column: column) { return }
        exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }
}
