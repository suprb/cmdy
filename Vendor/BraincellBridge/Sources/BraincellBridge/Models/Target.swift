import Foundation

/// What a terminal session is "pointed at" — the thing Claude controls and we route input to.
enum Target: Codable, Equatable, Hashable {
    /// A Chrome window we launched with CDP enabled. The Chrome process is owned by the bridge.
    case chrome(profileDir: String, cdpPort: Int)

    /// A macOS app project we build, run, and drive. `projectPath` points
    /// at a Swift Package or Xcode project root. The bridge owns the
    /// running process; tools cover the build/run/observe/drive loop.
    /// First non-Chrome adapter shipped — proves the multi-target abstraction.
    case macAppProject(projectPath: String)

    /// Future: iOS Simulator (controlled via simctl/idb).
    case simulator(udid: String)

    /// Future: any native macOS app driven by AX + CGEvent (binding to an
    /// already-running app like Slack, distinct from `macAppProject` which
    /// builds the app from source).
    case nativeApp(bundleId: String)

    var label: String {
        switch self {
        case .chrome: return "Chrome"
        case .macAppProject(let p): return (p as NSString).lastPathComponent
        case .simulator(let udid): return "Simulator \(udid.prefix(8))"
        case .nativeApp(let bid): return bid
        }
    }

    var symbolName: String {
        switch self {
        case .chrome: return "globe"
        case .macAppProject: return "hammer"
        case .simulator: return "iphone"
        case .nativeApp: return "app.dashed"
        }
    }
}
