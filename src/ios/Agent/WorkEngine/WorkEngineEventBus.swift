//
//  WorkEngineEventBus.swift
//  Minis - WorkEngine
//
//  Actor-isolated fan-out for persisted work events.
//

import Foundation

actor WorkEngineEventBus {
    static let shared = WorkEngineEventBus()

    private var continuations: [UUID: AsyncStream<WorkEvent>.Continuation] = [:]

    func stream(targetId: String? = nil) -> AsyncStream<WorkEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    func publish(_ event: WorkEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    @discardableResult
    func transition(store: WorkEngineStore,
                    level: WorkLevel,
                    targetId: String,
                    toStatus: WorkStatus,
                    source: String,
                    note: String? = nil,
                    actorId: String) async throws -> WorkEvent {
        let event = try await store.applyTransition(
            level: level, targetId: targetId, toStatus: toStatus,
            source: source, note: note, actorId: actorId
        )
        publish(event)
        return event
    }

    func toolTransition(store: WorkEngineStore, level: WorkLevel, targetId: String,
                        toStatus: WorkStatus, note: String? = nil,
                        actorId: String) async throws -> WorkEvent {
        try await transition(store: store, level: level, targetId: targetId,
                             toStatus: toStatus, source: "tool", note: note, actorId: actorId)
    }

    func fileWatcherTransition(store: WorkEngineStore, level: WorkLevel, targetId: String,
                               toStatus: WorkStatus, note: String? = nil,
                               actorId: String) async throws -> WorkEvent {
        try await transition(store: store, level: level, targetId: targetId, toStatus: toStatus,
            source: "fileWatcher", note: note, actorId: actorId)
    }

    func commandTransition(store: WorkEngineStore, level: WorkLevel, targetId: String,
                           toStatus: WorkStatus, note: String? = nil,
                           actorId: String) async throws -> WorkEvent {
        try await transition(store: store, level: level, targetId: targetId, toStatus: toStatus,
                       source: "command", note: note, actorId: actorId)
    }

    func testTransition(store: WorkEngineStore, level: WorkLevel, targetId: String,
                        toStatus: WorkStatus, note: String? = nil,
                        actorId: String) async throws -> WorkEvent {
        try await transition(store: store, level: level, targetId: targetId, toStatus: toStatus,
                       source: "test", note: note, actorId: actorId)
    }

    func plannerTransition(store: WorkEngineStore, level: WorkLevel, targetId: String,
                           toStatus: WorkStatus, note: String? = nil,
                           actorId: String = "planner") async throws -> WorkEvent {
        try await transition(store: store, level: level, targetId: targetId, toStatus: toStatus,
                       source: "planner", note: note, actorId: actorId)
    }

    func recoveryTransition(store: WorkEngineStore, level: WorkLevel, targetId: String,
                            toStatus: WorkStatus, note: String? = nil,
                            actorId: String = "recovery") async throws -> WorkEvent {
        try await transition(store: store, level: level, targetId: targetId, toStatus: toStatus,
                       source: "recovery", note: note, actorId: actorId)
    }

    private func removeSubscriber(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
