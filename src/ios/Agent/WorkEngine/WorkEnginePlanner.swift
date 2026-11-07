//
//  WorkEnginePlanner.swift
//  Minis - WorkEngine
//
//  Parses LLM plan JSON and materializes the task tree.
//

import Foundation

enum WorkEnginePlanner {

    struct Plan: Decodable {
        let tasks: [PlannedTask]
    }

    struct PlannedTask: Decodable {
        let name: String
        let desc: String?
        let blockedByTaskIds: [String]
        let phases: [PlannedPhase]

        enum CodingKeys: String, CodingKey {
            case name, desc, description, phases, blockedByTaskIds
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            desc = try c.decodeIfPresent(String.self, forKey: .desc)
                ?? c.decodeIfPresent(String.self, forKey: .description)
            phases = try c.decodeIfPresent([PlannedPhase].self, forKey: .phases) ?? []
            blockedByTaskIds = try c.decodeIfPresent([String].self, forKey: .blockedByTaskIds) ?? []
        }
    }

    struct PlannedPhase: Decodable {
        let name: String
        let steps: [PlannedStep]
    }

    struct PlannedStep: Decodable {
        let name: String
    }

    enum PlannerError: Error, Equatable {
        case emptyDocument
        case invalidJSON
        case emptyPlan
        case emptyName(String)
    }

    static func parse(_ text: String) throws -> Plan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlannerError.emptyDocument }
        let candidate = extractJSON(from: trimmed)
        guard let data = candidate.data(using: .utf8) else { throw PlannerError.invalidJSON }
        let decoder = JSONDecoder()
        let plan: Plan
        if let value = try? decoder.decode(Plan.self, from: data) {
            plan = value
        } else if let tasks = try? decoder.decode([PlannedTask].self, from: data) {
            plan = Plan(tasks: tasks)
        } else {
            throw PlannerError.invalidJSON
        }
        try validate(plan)
        return plan
    }

    static func createPlan(from text: String, projectId: String,
                           store: WorkEngineStore) async throws -> WorkProjectSnapshot {
        let plan = try parse(text)
        for (taskIndex, taskDocument) in plan.tasks.enumerated() {
            let task = await store.createTask(
                projectId: projectId, name: taskDocument.name,
                desc: taskDocument.desc, sortIndex: taskIndex,
                blockedByTaskIds: taskDocument.blockedByTaskIds
            )
            for (phaseIndex, phaseDocument) in taskDocument.phases.enumerated() {
                let phase = await store.createPhase(
                    taskId: task.id, name: phaseDocument.name, sortIndex: phaseIndex
                )
                for (stepIndex, stepDocument) in phaseDocument.steps.enumerated() {
                    _ = await store.createStep(
                        phaseId: phase.id, name: stepDocument.name, sortIndex: stepIndex
                    )
                }
            }
        }
        return try await store.snapshot(projectId: projectId)
    }

    private static func validate(_ plan: Plan) throws {
        guard !plan.tasks.isEmpty else { throw PlannerError.emptyPlan }
        for (taskIndex, task) in plan.tasks.enumerated() {
            guard !task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PlannerError.emptyName("tasks[\(taskIndex)]")
            }
            for (phaseIndex, phase) in task.phases.enumerated() {
                guard !phase.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PlannerError.emptyName("tasks[\(taskIndex)].phases[\(phaseIndex)]")
                }
                for step in phase.steps {
                    guard !step.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw PlannerError.emptyName("step")
                    }
                }
            }
        }
    }

    private static func extractJSON(from text: String) -> String {
        if text.hasPrefix("{") || text.hasPrefix("[") {
            return text
        }
        let objectStart = text.firstIndex(of: "{")
        if let start = objectStart, let end = objectEnd, start < end {
            return String(text[start...end])
        }
        if let start = arrayStart, let end = arrayEnd, start < end {
            return String(text[start...end])
        }
        return text
    }
}
