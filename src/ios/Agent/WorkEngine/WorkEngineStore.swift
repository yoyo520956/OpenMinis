//
//  WorkEngineStore.swift
//  Minis - WorkEngine
//
//  The actor that owns every WorkEngine row: projects, tasks, phases, steps and
//  the append-only event log.
//
//  Deliberate choices, matching Agent/Chat's existing store:
//   - raw SQLite3 on the SAME database file the chat store uses (minis.db)
//   - WAL + foreign_keys pragmas, same as ChatStore.openDatabase()
//   - incremental migrations via CREATE TABLE IF NOT EXISTS + PRAGMA table_info
//     checks, so opening an existing database never rewrites it
//   - plain structs in, plain structs out; no persistence framework
//
//  Hardest rule implemented here: a status may only change through
//  `applyTransition`, which writes the event row and the new status inside one
//  transaction, after validating the transition (and, for `done`, the evidence).
//

import Foundation
import SQLite3
import os.log

actor WorkEngineStore {

    static let shared = WorkEngineStore()

    let logger = AppLogger(category: "WorkEngine")

    /// Same constant the codebase uses elsewhere; SQLITE_TRANSIENT is a C macro
    /// that does not import cleanly into Swift, so bind with our own copy.
    static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    var db: OpaquePointer?
    let dbURL: URL

    // MARK: - Init

    init() {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let baseURL = libraryURL.appendingPathComponent("MinisChat", isDirectory: true)
        self.dbURL = baseURL.appendingPathComponent("minis.db")
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        openDatabase()
        createTables()
    }

    /// For tests and for a project-local database.
    init(baseURL: URL) {
        self.dbURL = baseURL.appendingPathComponent("minis.db")
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        openDatabase()
        createTables()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Database plumbing

    func openDatabase() {
        let result = sqlite3_open(dbURL.path, &db)
        if result != SQLITE_OK {
            logger.error("[WorkEngine] failed to open \(self.dbURL.path): \(result)")
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA foreign_keys=ON")
        exec("PRAGMA busy_timeout=3000")
    }

    func closeDatabase() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    func exec(_ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            logger.error("[WorkEngine] SQL error: \(msg) — \(sql)")
            sqlite3_free(errMsg)
        }
    }

    // MARK: Bind helpers

    func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, Self.SQLITE_TRANSIENT)
    }

    func bindTextOpt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(stmt, idx)
            return
        }
        sqlite3_bind_text(stmt, idx, value, -1, Self.SQLITE_TRANSIENT)
    }

    func bindDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, idx, value)
    }

    func bindInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, idx, Int64(value))
    }

    func bindInt64(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, idx, value)
    }

    // MARK: Read helpers

    static func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: ptr)
    }

    static func colTextOpt(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: ptr)
    }

    static func colDate(_ stmt: OpaquePointer?, _ idx: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(stmt, idx))
    }

    static func colDateOpt(_ stmt: OpaquePointer?, _ idx: Int32) -> Date? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, idx))
    }

    static func colInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, idx))
    }

    // MARK: - JSON helpers

    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}
