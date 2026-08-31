// swift-tools-version:5.9
import PackageDescription

// swarm — every AI session across every window and split, one list, one
// keystroke away (⌃⌥A). Pure SDK composition: /v1/panes already knows each
// pane's window, split position, AI tool, and attention state; this plugin
// provides a native switcher plus a form that gathers selected/all live agent
// panes into a new grid window without restarting their processes.
let package = Package(
    name: "swarm",
    platforms: [.macOS("26.0")],
    dependencies: [ .package(path: "../CmdySDK") ],
    targets: [ .executableTarget(name: "swarm", dependencies: ["CmdySDK"]) ]
)
