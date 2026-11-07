//
//  WorkEngineEventBus.swift
//  Minis - WorkEngine
//
//  Actor-isolated fan-out for persisted work events.
//

import Foundation

actor WorkEngineEventBus {
    static let shared = WorkEngineEventBus()

    private var subscribers: [UUID: AsyncStream<WorkEvent>.Continuation] = [:]

    func stream() -> AsyncStream<WorkEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    func publish(_ event: WorkEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    @discardableResult
    func toolTransition(store: WorkEngineStore, level: WorkLevel, targetId: String,
                        toStatus: WorkStatus, note: String? = nil,
                        actorId: String) async throws -> WorkEvent {
        try await emit(store: store, level: level, targetId: targetId, toStatus: toStatus,
                       source: "tool", note: note, actorId: actorId)
    }

    @discardableResult
    func fileWatcherTransition(store: WorkEngineStore, level: WorkLevel, targetId: String,
                               toStatus: WorkStatus, note: String? = nil,
                               actorId: String) async throws -> WorkEvent {
        try await emitTransition(store: store, level: level, targetId: targetId,
            toStatus: toStatus, source: "fileWatcher", note: note, actorId: actorId)
    }

    @discardableResult
    func commandTransition(store: WorkEngineStore, level: WorkLevel, targetId: String,
                           toStatus: WorkStatus, note: String? = nil,
                           actorId: String) async throws -> WorkEvent {
        try await emit(store: store, level: level, targetId: targetId, toStatus: toStatus,
                       source: "command", note: note, actorId: actorId)
    }

    @discardableResult
    func testTransition(store: WorkEngineStore, level: WorkLevel, targetId: String,
                        toStatus: WorkStatus, note: String? = nil,
                        actorId: String) async throws -> WorkEvent {
        try await emit(store: store, level: level, targetId: targetId, toStatus: toStatus,
                       source: "test", note: note, actorId: actorId)
    }

    @discardableResult
    func plannerTransition(store: WorkEngineStore, level: WorkLevel, targetId: String,
                           toStatus: WorkStatus, note: String? = nil,
                           actorId: String = "planner") async throws -> WorkEvent {
        try await emit(store: store, level: level, targetId: targetId, toStatus: toStatus,
                       source: "planner", note: note, actorId: actorId)
    }

    @discardableResult
    func recoveryTransition(store: WorkEngineStore, level: WorkLevel, targetId: String,
                            toStatus: WorkStatus, note: String? = nil,
                            actorId: String = "recovery") async throws -> WorkEvent {
        try await emit(store: store, level: level, targetId: targetId, toStatus: toStatus,
                       source: "recovery", note: note, actorId: actorId)
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
