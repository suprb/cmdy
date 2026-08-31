import Foundation
import AppKit

/// Common surface every target adapter exposes so the rest of the bridge
/// (preflight, lifecycle, wire overlay) can talk to them uniformly.
///
/// **Why this protocol exists.** Every time we add a target adapter
/// (Mac App, then iOS Simulator, then Native App) we discover the same
/// set of switch sites in `BridgeMCPServer` (preflight),
/// `BridgeAppDelegate.unbindSession` (cleanup), and `WireOverlayController`
/// (visibility + recompute). Each site silently breaks for the new variant
/// if you forget it (boolean projections default to `false`; see
/// `feedback_audit_enum_sites.md`). The protocol turns those switch sites
/// into a single closed iteration over `[any TargetAdapter]` — adding a 5th
/// adapter no longer requires audit-every-switch-site discipline.
///
/// **Per-tool dispatch stays per-adapter.** This protocol intentionally
/// does NOT abstract `dispatch(tool:arguments:) async throws -> Any` —
/// the tool surface is so different across targets (Chrome's 32 web tools
/// vs Mac's 22 AX tools vs Sim's 23 idb tools vs Native's 16 AX tools)
/// that a unified dispatch would be dishonest. `BridgeToolRouter` keeps
/// its prefix-routed switch (`tool.hasPrefix("mac_") → dispatchMacApp`);
/// this protocol covers only the cross-cutting "is the surface alive /
/// where's its window / clean it up" parts.
@MainActor
protocol TargetAdapter: AnyObject {
    /// Process ID we should anchor visuals + the wire overlay to.
    /// - Chrome: the Chrome process pid
    /// - Mac App: the spawned app's runningPid
    /// - Sim: the Simulator.app pid (shared across all booted sims)
    /// - Native: the bound app's NSRunningApplication pid
    /// Nil when the underlying surface isn't alive (Chrome window closed,
    /// Mac app exited, sim shut down, native app quit). Wire/cursor
    /// visuals skip this session when nil.
    var anchorPid: pid_t? { get }

    /// Frame of the bound surface in top-left CG screen coords. Used by
    /// cursor visuals (`showScreenshotCapture`) and as a fallback for
    /// the wire overlay's polling-based pid lookup. Nil when the surface
    /// isn't on screen.
    func windowFrame() -> CGRect?

    /// Fired when the underlying target dies — Chrome window closed,
    /// Mac app exited, sim shut down, native app quit. Wired by
    /// `BridgeAppDelegate` at bind time to call `unbindSession(sessionId:)`
    /// — universal close-target → unbind lifecycle (see
    /// `project_bridge_lifecycle_ephemeral.md`).
    var onTerminated: (() -> Void)? { get set }

    /// Release this adapter's resources — the binding is going away.
    /// Per-adapter:
    /// - Chrome: terminates Chrome process + closes CDP
    /// - Mac App: stops the spawned Process
    /// - Sim: invalidates the state-watcher Timer (we don't shut down
    ///   the user's actual simulator — they own it)
    /// - Native: removes NSWorkspace observer (we don't quit the user's
    ///   running app)
    /// Idempotent — calling on an already-shutdown adapter is a no-op.
    /// Named `shutdown` to avoid clash with `ChromeAdapter.terminate()`
    /// (sync, kills the Process) and `SimulatorAdapter.terminate(bundleId:)`
    /// (a tool that quits an app inside the sim).
    func shutdown() async
}
