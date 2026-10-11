import AppKit

// An owned, short-lived foreground process lets the terminal remain visible
// but inactive. It never activates or modifies an unrelated application.
let args = CommandLine.arguments
guard args.count == 2, let targetPID = Int32(args[1]),
      let target = NSRunningApplication(processIdentifier: targetPID),
      target.executableURL?.lastPathComponent == "cmdy", !target.isTerminated else { exit(2) }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 10, y: 10, width: 100, height: 80),
    styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.title = "CMDY test"
window.makeKeyAndOrderFront(nil)
app.finishLaunching()
app.activate(ignoringOtherApps: true)
let deadline = Date().addingTimeInterval(2)
while NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), !target.isHidden else {
    print("{\"ready\":false,\"pid\":\(getpid()),\"foregroundPID\":\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0),\"targetHidden\":\(target.isHidden)}")
    exit(3)
}
print("{\"ready\":true,\"pid\":\(getpid()),\"targetPID\":\(targetPID),\"targetHidden\":false}")
fflush(stdout)
let timer = Timer.scheduledTimer(withTimeInterval: 9, repeats: false) { _ in
    window.close(); print("{\"closed\":true}"); exit(0)
}
app.run()
