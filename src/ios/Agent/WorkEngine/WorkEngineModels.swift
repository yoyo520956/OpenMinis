//
//  WorkEngineModels.swift
//  Minis - WorkEngine (the Codex-style work layer: project / task / phase / step)
//
//  Four-level work model + the seven statuses, the evidence types a step must
//  carry before it may be marked done, and the event-log row shape.
//
//  Conventions copied from the existing store (Agent/Chat):
//   - plain Codable structs, no persistence framework in the app target
//   - Date columns are REAL (timeIntervalSince1970), matching ChatStore
//   - ids are UUID strings, matching sessions.id / folders.id
//

import Foundation

// MARK: - Status

/// The seven work-item statuses. The UI legend maps them to circle + text:
/// ○ 未开始 / ◉ 正在执行 / ✓ 已完成 / ✕ 执行失败 / ⏸ 等待确认 / ‖ 已暂停 / ⊘ 已跳过
enum WorkStatus: String, Codable, CaseIterable, Sendable {
    case pending      // 未开始
    case running      // 正在执行
    case done         // 已完成
    case failed       // 执行失败
    case waitingUser  // 等待确认
    case paused       // 已暂停
    case skipped      // 已跳过
}

// MARK: - Levels

enum WorkLevel: String, Codable, Sendable {
    case project, task, phase, step
}

// MARK: - Project

/// A project is a data-layer workspace container. It is NOT the same thing as a
/// chat `folder` (which is a UI-only grouping): a project owns its files, its
/// memory, its instructions, its task tree and its progress.
struct WorkProject: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var desc: String?
    /// Project-only instruction text, appended to every conversation in this project.
    var instructions: String?
    /// Linux path of the project working directory, e.g. /var/minis/workspace/<id>
    var workspacePath: String?
    var gitRemoteURL: String?
    var gitDefaultBranch: String?
    /// Non-nil ⇒ archived: hidden from the list, data kept, restorable.
    var archivedAt: Date?
    let createdAt: Date
    var updatedAt: Date

    var isArchived: Bool { archivedAt != nil }
}

// MARK: - Task

struct WorkTask: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let projectId: String
    var name: String
    var desc: String?
    var status: WorkStatus
    /// Ascending order within the project.
    var sortIndex: Int
    /// Task ids that must finish before this one may leave `waitingUser`.
    var blockedByTaskIds: [String]
    let createdAt: Date
    var updatedAt: Date
    var finishedAt: Date?
}

// MARK: - Phase

struct WorkPhase: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let taskId: String
    var name: String
    var status: WorkStatus
    var sortIndex: Int
    let createdAt: Date
    var updatedAt: Date
    var finishedAt: Date?
}

// MARK: - Step

struct WorkStep: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let phaseId: String
    var name: String
    var status: WorkStatus
    var sortIndex: Int
    /// One line about what is happening right now; updated by the event stream.
    var currentAction: String?
    /// Proof of work. `done` is rejected while this is empty — see
    /// WorkEngineStateMachine.canMarkStepDone.
    var evidence: StepEvidence?
    var failureReason: String?
    var startedAt: Date?
    var finishedAt: Date?
    let createdAt: Date
    var updatedAt: Date
}

/// Evidence for a step. Every field optional; a step of a given kind fills the
/// matching ones. Empty ⇒ the step may only reach `failed` or `skipped`.
struct StepEvidence: Codable, Hashable, Sendable {
    var fileChanges: [FileChangeRef]?
    var commands: [CommandRef]?
    var testResults: [TestResultRef]?

    var isEmpty: Bool {
        (fileChanges?.isEmpty ?? true)
            && (commands?.isEmpty ?? true)
            && (testResults?.isEmpty ?? true)
    }
}

struct FileChangeRef: Codable, Hashable, Sendable {
    /// Path as reported by the watcher (absolute Linux path, or project-relative).
    let path: String
    /// changed | added | deleted | renamed
    let kind: String
    var addedLines: Int?
    var removedLines: Int?
    let at: Date
}

struct CommandRef: Codable, Hashable, Sendable {
    /// Redacted command text. Environment variable VALUES are never stored
    /// (the app already redacts them in logs; same rule here).
    let command: String
    let exitCode: Int32
    /// Bounded digest (≤ 8 KB) of stdout/stderr; the full text stays in logs.
    var outputDigest: String?
    let startedAt: Date
    /// Wall-clock duration in milliseconds.
    let durationMs: Int
    /// Which sandbox ran it: "ish" (on device) or "ci-macos".
    let executor: String
}

struct TestResultRef: Codable, Hashable, Sendable {
    let suite: String
    let passed: Int
    let failed: Int
    let skipped: Int
    /// Failing case names plus a short reason, capped at 20 entries.
    var failures: [String]?
    let at: Date
}

// MARK: - Event log

/// An append-only event row. The ONLY channel that may change a work item's
/// status: the store validates the transition and writes the event first, then
/// the new status. Model prose ("I already changed the file") is not an event.
struct WorkEvent: Codable, Sendable {
    let seq: Int64
    let level: WorkLevel
    let targetId: String
    let fromStatus: WorkStatus
    let toStatus: WorkStatus
    /// tool | fileWatcher | command | test | user | planner | recovery
    let source: String
    let note: String?
    let at: Date
    /// Which agent/device emitted it. Parallel agents are told apart by this.
    let actorId: String
}

// MARK: - Derived snapshots (UI reads these, one query per level, no N+1)

struct WorkProjectSnapshot: Codable, Sendable {
    let project: WorkProject
    let tasks: [WorkTaskSnapshot]
    var progress: WorkProgress
}

struct WorkTaskSnapshot: Codable, Sendable {
    let task: WorkTask
    let phases: [WorkPhaseSnapshot]
    var progress: WorkProgress
}

struct WorkPhaseSnapshot: Codable, Sendable {
    let phase: WorkPhase
    let steps: [WorkStep]
    var progress: WorkProgress
}

/// Counters over the direct children of a node. A single derivation rule keeps
/// the summary bar and the list from ever disagreeing.
struct WorkProgress: Codable, Sendable, Equatable {
    var total: Int = 0
    var done: Int = 0
    var running: Int = 0
    var failed: Int = 0
    var waitingUser: Int = 0
    var paused: Int = 0
    var pending: Int = 0
    var skipped: Int = 0

    static let empty = WorkProgress()

    /// Counts that ignore `skipped` so a deliberately skipped step never makes
    /// a finished phase look 80% done.
    var effectiveTotal: Int { total - skipped }

    var fraction: Double {
        guard effectiveTotal > 0 else { return 0 }
        return Double(done) / Double(effectiveTotal)
    }

    static func of(_ statuses: [WorkStatus]) -> WorkProgress {
        var p = WorkProgress()
        p.total = statuses.count
        for s in statuses {
            switch s {
            case .done:        p.done += 1
            case .running:     p.running += 1
            case .failed:      p.failed += 1
            case .waitingUser: p.waitingUser += 1
            case .paused:      p.paused += 1
            case .pending:     p.pending += 1
            case .skipped:     p.skipped += 1
            }
        }
        return p
    }
}
