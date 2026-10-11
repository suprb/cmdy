
// Private test seam appended to the copied production file, so tests can
// force capture boundaries without wall-clock sleeps or native app launches.
import CmdyNative
@_spi(CmdyApp) @testable import CmdyCore

extension TerminalModel {
    func captureForTesting() {
        sync {
            publicationScheduler.resetPendingCapture()
            publishSnapshot()
        }
    }
    func performWorkerTurnForTesting(_ operation: (TerminalModel) -> Void) {
        sync { operation(self) }
    }
}

extension TerminalModel {
    var workerStateForTesting: (generation: UInt64,
                               kind: SnapshotPublicationScheduler.Kind?,
                               deadline: Double?, services: Int) {
        sync {
            snapshotLock.lock()
            let generation = publishedSnapshotGeneration
            snapshotLock.unlock()
            return (generation, publicationScheduler.pending?.kind,
                    publicationScheduler.responseDeadline,
                    publicationScheduler.queuedServiceCount)
        }
    }
    func afterWorkerTurnForTesting(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}

extension TerminalModel {
    var historyStateForTesting: (cursor: Int, enabled: Bool, needsWork: Bool,
                                 queued: Bool, active: Bool) {
        sync {
            (historyMaintenance.nextAbsoluteRow, historyMaintenance.enabled,
             historyMaintenance.needsWork, historyMaintenance.queuedService != nil,
             historyMaintenance.activeBatch != nil)
        }
    }

    func materializeHistoryRowForTesting(_ row: Int) -> Bool {
        sync {
            guard let line = cmdy_zig_buffer_line(terminal.normalBuffer.native, row) else { return false }
            defer { cmdy_zig_line_release(line) }
            return cmdy_zig_line_prepare_read(line) == 0
        }
    }

    // Deferred blank cells also lack a contiguous cell view. Materialize the
    // selected fixture row before observing its dense-to-compact transition.
    // This read itself does not materialize or install a host wrapper.
    func historyRowHasDenseCellsForTesting(_ row: Int) -> Bool? {
        sync {
            guard let line = cmdy_zig_buffer_line(terminal.normalBuffer.native, row) else { return nil }
            defer { cmdy_zig_line_release(line) }
            var count = 0
            return cmdy_zig_line_cells(line, &count) != nil
        }
    }
}
