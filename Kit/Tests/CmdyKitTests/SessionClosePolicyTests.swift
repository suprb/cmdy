import Darwin
import Foundation
import XCTest
@testable import CmdyKit

final class SessionClosePolicyTests: XCTestCase {
    func testIdleShellsAndCompletedHistoryDoNotRequireConfirmation() {
        let history = BlockStore()
        history.commandStarted(row: 1, promptRow: 0, command: "echo hello", cwd: "/tmp")
        history.commandFinished(row: 2, exitCode: 0)
        let state = SessionCloseState(
            runningCommand: history.isRunning ? history.blocks.last?.commandText : nil)
        XCTAssertFalse(SessionClosePolicy.assess([state, SessionCloseState()]).requiresTerminalConfirmation)
    }

    func testEveryKindOfCurrentWorkIsProtectedAndSummaryIsBounded() {
        let states = [
            SessionCloseState(runningCommand: "sleep 120"),
            SessionCloseState(runningProcesses: ["sleep"]),
            SessionCloseState(processStateUnknown: true),
            SessionCloseState(isAlternateScreen: true),
            SessionCloseState(hasDraftInput: true),
            SessionCloseState(hasActiveSurface: true),
        ]
        for state in states { XCTAssertTrue(state.requiresConfirmation) }
        let assessment = SessionClosePolicy.assess(states, dirtyDocumentCount: 2)
        XCTAssertEqual(assessment.affectedPanes.count, 6)
        XCTAssertTrue(assessment.explanation.contains("sleep 120"))
        XCTAssertTrue(assessment.explanation.contains("1 more terminal panes"))
        XCTAssertTrue(assessment.explanation.contains("2 unsaved documents"))
    }

    func testApprovalDoesNotCoverNewCommandsOrNewInput() {
        let approved = SessionCloseState(runningCommand: "make", runningProcesses: ["make"])
        XCTAssertTrue(SessionCloseState().isCovered(by: approved))
        XCTAssertTrue(SessionCloseState(runningCommand: "make", runningProcesses: ["clang"]).isCovered(by: approved))
        XCTAssertFalse(SessionCloseState(runningCommand: "deploy").isCovered(by: approved))
        XCTAssertFalse(SessionCloseState(hasDraftInput: true).isCovered(by: approved))
    }

    func testProcessInspectionFindsJobsWithoutShellIntegration() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 30 & child=$!; trap 'kill $child 2>/dev/null' EXIT; trap 'exit 0' TERM; wait"]
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        defer { shell.terminate(); shell.waitUntilExit() }

        var found = false
        for _ in 0..<100 {
            if SessionProcessInspector.inspect(shellPID: shell.processIdentifier)
                .runningPrograms.contains("sleep") {
                found = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(found, "background children must be protected even without OSC markers")
    }

    func testRealUsedIdleShellIsNotClassifiedAsRunningWork() throws {
        let shell = Process()
        let input = Pipe()
        let output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-f"]
        shell.standardInput = input
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        defer { shell.terminate(); shell.waitUntilExit() }
        try input.fileHandleForWriting.write(contentsOf: Data("printf 'ready\\n'\n".utf8))
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 6), Data("ready\n".utf8))

        // The shell has executed a command and now waits for input. On Darwin
        // its BSD status is still SRUN, which must not cause a close warning.
        let result = SessionProcessInspector.inspect(shellPID: shell.processIdentifier)
        XCTAssertFalse(result.isUnknown)
        XCTAssertEqual(result.runningPrograms, [])
        XCTAssertTrue(shell.isRunning)
    }

    func testProcessReplacingShellPIDIsProtected() throws {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/sleep")
        command.arguments = ["30"]
        try command.run()
        defer { command.terminate(); command.waitUntilExit() }
        let result = SessionProcessInspector.inspect(shellPID: command.processIdentifier)
        XCTAssertTrue(result.runningPrograms.contains("sleep"))
        XCTAssertFalse(SessionProcessInspector.inspect(shellPID: -1).isUnknown)
    }
}
