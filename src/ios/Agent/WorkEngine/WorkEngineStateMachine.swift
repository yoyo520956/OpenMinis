//
//  WorkEngineStateMachine.swift
//  Minis - WorkEngine
//
//  The seven-status transition table and the completion rule.
//
//  Every transition the store applies goes through `canTransition`. Illegal
//  ones are REJECTED and logged — never silently coerced into a "close enough"
//  state. Silent coercion is exactly how a UI ends up showing ✓ for work that
//  never happened.
//

import Foundation

enum WorkEngineStateMachine {

    /// Key = current status, value = reachable statuses.
    static let transitions: [WorkStatus: Set<WorkStatus>] = [
        // Not started: the planner may still pull it back out of the queue.
        .pending:     [.running, .waitingUser, .paused, .skipped],
        // Running: four exits, no direct return to `pending` (a redo goes
        // through failed/skipped or an explicit replan, both of which leave a
        // record).
        .running:     [.done, .failed, .waitingUser, .paused, .skipped],
        // Done is terminal for normal flow; only a replan may reopen it.
        .done:        [.pending],
        // Failed: retry, hand to the user, or abandon.
        .failed:      [.running, .waitingUser, .skipped],
        // Waiting on the user: resume, pause, abandon, or (if the confirmation
        // itself completed the work) finish.
        .waitingUser: [.running, .paused, .skipped, .done],
        // Paused: resume or abandon.
        .paused:      [.running, .skipped],
        // Skipped: only a replan reopens it.
        .skipped:     [.pending],
    ]

    static func canTransition(_ from: WorkStatus, _ to: WorkStatus) -> Bool {
        from == to || (transitions[from]?.contains(to) ?? false)
    }

    static func isTerminal(_ status: WorkStatus) -> Bool {
        status == .done || status == .skipped
    }

    // MARK: Labels

    /// Chinese label shared by the card, the legend and the work panel, so the
    /// three can never drift apart.
    static func label(_ status: WorkStatus) -> String {
        switch status {
        case .pending:     return "未开始"
        case .running:     return "正在执行"
        case .done:        return "已完成"
        case .failed:      return "执行失败"
        case .waitingUser: return "等待确认"
        case .paused:      return "已暂停"
        case .skipped:     return "已跳过"
        }
    }

    /// Circle glyph. Always rendered together with `label(_:)` — a bare circle
    /// with no text is not allowed in the UI (hard requirement).
    static func symbol(_ status: WorkStatus) -> String {
        switch status {
        case .pending:     return "○"
        case .running:     return "◉"
        case .done:        return "✓"
        case .failed:      return "✕"
        case .waitingUser: return "⏸"
        case .paused:      return "‖"
        case .skipped:     return "⊘"
        }
    }

    // MARK: Completion rule

    /// Whether a step is allowed to become `.done`.
    ///
    /// Rules, in order:
    ///  1. It must carry evidence (at least one ref of any kind).
    ///  2. If it ran commands, every one must have exited 0.
    ///  3. If it touched files, every recorded path must be non-empty and the
    ///     caller must have verified the change (the store only guards empty
    ///     declarations here; on-disk verification belongs to the emitter).
    ///  4. A `failed` reason may not be present at the same time.
    static func canMarkStepDone(_ step: WorkStep) -> Bool {
        guard let evidence = step.evidence, !evidence.isEmpty else { return false }
        if let commands = evidence.commands, !commands.isEmpty {
            guard commands.allSatisfy({ $0.exitCode == 0 }) else { return false }
        }
        if let files = evidence.fileChanges, !files.isEmpty {
            guard !files.contains(where: { $0.path.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        }
        if let reason = step.failureReason, !reason.isEmpty { return false }
        return true
    }

    /// Whether a step may be marked `failed`. Always allowed from an active
    /// state, but a reason is mandatory so the UI never shows a bare ✕.
    static func canMarkStepFailed(_ step: WorkStep) -> Bool {
        guard step.status == .running || step.status == .waitingUser else { return false }
        guard let reason = step.failureReason, !reason.isEmpty else { return false }
        return true
    }

    // MARK: Aggregation

    /// Roll the children up into the parent's status. Used by the store when a
    /// child moves, so a phase reflects its steps without a second source of
    /// truth.
    static func rollup(_ childStatuses: [WorkStatus]) -> WorkStatus {
        let nonSkipped = childStatuses.filter { $0 != .skipped }
        guard !nonSkipped.isEmpty else { return .skipped }
        if nonSkipped.contains(.failed) { return .failed }
        if nonSkipped.contains(.running) { return .running }
        if nonSkipped.contains(.waitingUser) { return .waitingUser }
        if nonSkipped.contains(.paused) { return .paused }
        if nonSkipped.contains(.pending) { return .pending }
        return .done
    }
}
