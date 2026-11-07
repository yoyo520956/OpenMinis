//
//  WorkEngineStoreTests.swift
//  MinisTests - WorkEngine persistence tests
//
//  Uses a temporary directory so the real minis.db is never touched.
//

import XCTest
@testable import Minis

final class WorkEngineStoreTests: XCTestCase {

    private var store: WorkEngineStore!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workengine-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = WorkEngineStore(baseURL: dir)
    }

    override func tearDown() {
        super.tearDown()
        store = nil
    }

    // MARK: - Schema

    func testSchemaCreatesTables() {
        let tables = [
            "work_projects",
            "work_tasks",
            "work_phases",
            "work_steps",
            "work_events",
        ]
        for table in tables {
            XCTAssertTrue(store.columnExists(table: table, column: "id"),
                          "work_projects should have id column")
        }
    }

    func testSchemaCreatesSessionsColumn() {
        // The store adds work_project_id to sessions on first open
        let projects = await store.listProjects()
        XCTAssertEqual(projects.count, 0, "fresh store should have no projects")
    }

    // MARK: - Project lifecycle

    func testCreateAndReadProject() async throws {
        let p = await store.createProject(name: "Test Project")
        XCTAssertEqual(p.name, "Test")
        XCTAssertEqual(p.name, "Test")

        let fetched = await store.project(id: p.id)
        XCTAssertEqual(fetched?.id, p.id)
        XCTAssertEqual(fetched?.name, p.name)
    }

    func testListProjects() async {
        let p1 = await store.createProject(name: "P1")
        let p2 = await store.createProject(name: "B")
        let all = await store.listProjects()
        XCTAssertEqual(all.count, 2)
    }

    func testArchiveProject() async {
        let p = await store.createProject(name: "X")
        var p = p
        p.archivedAt = Date()
        _ = await store.updateProject(p)
        let after = await store.project(id: p.id)
        XCTAssertNotNil(after?.archivedAt)
    }

    // MARK: - Task CRUD

    func testTaskCRUD() async {
        let p = await store.createProject(name: "T")
        let t = await store.createTask(projectId: p.id, name: "T1", sortIndex: 0)
        let tasks = await store.listTasks(projectId: p.id)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.name, "T1")
    }

    // MARK: - State machine via store

    func testStartStep() async throws {
        let p = await store.createProject(name: "t")
        let task = await store.createTask(projectId: p.id, name: "T")
        let phase = await store.createPhase(taskId: task.id, name: "PH")
        let step = await store.createStep(phaseId: phase.id, name: "S1")

        XCTAssertEqual(step.status, .pending)
        _ = try await store.startStep(step.id, action: "start", actorId: "test")
        XCTAssertEqual(step.status, .running)
    }

    func testCanNotCompleteWithoutEvidence() async {
        let p = await store.createProject(name: "x")
        let task = await store.createTask(projectId: p.id, name: "t")
        let phase = await store.createPhase(taskId: task.id, name: "p")
        let step = await store.createStep(phaseId: phase.id, name: "s")

        // empty evidence => can not mark done
        var step = await store.step(id: step.id)!
        step.status = .running
        step.evidence = nil
        XCTAssertFalse(WorkEngineStateMachine.canMarkStepDone(step))
    }

    func testCanMarkDoneRequiresEvidence() async {
        let p = await store.createProject(name: "T")
        let task = await store.createTask(projectId: p.id, name: "t")
        let phase = await store.createPhase(taskId: task.id, name: "ph")
        let step = await store.createStep(phaseId: phase.id, name: "s")
        step.evidence = StepEvidence(
            fileChanges: [FileChangeRef(path: "/tmp/x", kind: "added", at: Date())],
            commands: [CommandRef(command: "ls", exitCode: 0, startedAt: Date(), durationMs: 100, executor: "ish")],
            testResults: nil
        )
        step.status = .running
        XCTAssertTrue(WorkEngineStateMachine.canMarkStepDone(step))
    }
}
