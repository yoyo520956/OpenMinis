import XCTest
@testable import Minis

final class WorkEngineStateMachineTests: XCTestCase {

    func testTransitionTableMatchesDeclaredRules() {
        for from in WorkStatus.allCases {
            for to in WorkStatus.allCases {
                let expected = from == to || (WorkEngineStateMachine.transitions[from]?.contains(to) ?? false)
                XCTAssertEqual(WorkEngineStateMachine.canTransition(from, to), expected, "\(from) to \(to)")
            }
        }
    }

    func testTerminalStatesOnlyReopenToPending() {
        for terminal in [WorkStatus.done, .skipped] {
            XCTAssertTrue(WorkEngineStateMachine.isTerminal(terminal))
            XCTAssertTrue(WorkEngineStateMachine.canTransition(terminal, .pending))
            XCTAssertFalse(WorkEngineStateMachine.canTransition(terminal, .running))
        }
    }

    func testEveryStatusHasLabelAndSymbol() {
        for status in WorkStatus.allCases {
            XCTAssertFalse(WorkEngineStateMachine.label(status).isEmpty)
            XCTAssertFalse(WorkEngineStateMachine.symbol(status).isEmpty)
        }
    }

    func testStepDoneRequiresEvidence() {
        var step = makeStep()
        XCTAssertFalse(WorkEngineStateMachine.canMarkStepDone(step))
        step.evidence = StepEvidence(fileChanges: nil, commands: nil, testResults: nil)
        XCTAssertFalse(WorkEngineStateMachine.canMarkStepDone(step))
        step.evidence = StepEvidence(
            fileChanges: [FileChangeRef(path: "Sources/a.swift", kind: "changed", at: Date())],
            commands: nil, testResults: nil
        )
        XCTAssertTrue(WorkEngineStateMachine.canMarkStepDone(step))
    }

    func testDoneRejectsFailedCommandsAndFailureReason() {
        var step = makeStep()
        let badCommand = CommandRef(command: "false", exitCode: 1, outputDigest: nil,
                                    startedAt: Date(), durationMs: 1, executor: "ish")
        step.evidence = StepEvidence(fileChanges: nil, commands: [badCommand], testResults: nil)
        XCTAssertFalse(WorkEngineStateMachine.canMarkStepDone(step))
        step.evidence?.commands = nil
        step.evidence?.fileChanges = [FileChangeRef(path: "Sources/a.swift", kind: "changed", at: Date())]
        XCTAssertTrue(WorkEngineStateMachine.canMarkStepDone(step))
        step.failureReason = "old failure"
        XCTAssertFalse(WorkEngineStateMachine.canMarkStepDone(step))
    }

    func testFailedRequiresActiveStateAndReason() {
        var step = makeStep()
        step.status = .running
        XCTAssertFalse(WorkEngineStateMachine.canMarkStepDone(step))
        XCTAssertFalse(WorkEngineStateMachine.canMarkStepFailed(step))
        step.failureReason = "Build failed"
        XCTAssertTrue(WorkEngineStateMachine.canMarkStepFailed(step))
        XCTAssertFalse(WorkEngineStateMachine.canMarkStepDone(step))
    }

    func testRollupAndProgressRules() {
        XCTAssertEqual(WorkEngineStateMachine.rollup([.pending, .skipped]), .pending)
        XCTAssertEqual(WorkEngineStateMachine.rollup([.done, .running]), .running)
        XCTAssertEqual(WorkEngineStateMachine.rollup([.done, .failed, .running]), .failed)
        XCTAssertEqual(WorkEngineStateMachine.rollup([.skipped, .skipped]), .skipped)
        let progress = WorkProgress.of([.done, .skipped, .running, .failed])
        XCTAssertEqual(progress.total, 4)
        XCTAssertEqual(progress.effectiveTotal, 3)
        XCTAssertEqual(progress.fraction, 0.5)
    }

    private func makeStep() -> WorkStep {
        WorkStep(
            id: "step", phaseId: "phase", name: "Test", status: .pending, sortIndex: 0,
            currentAction: nil, evidence: nil, failureReason: nil,
            startedAt: nil, finishedAt: nil, createdAt: Date(), updatedAt: Date()
        )
    }
}
