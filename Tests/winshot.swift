import CoreGraphics
import Foundation

// usage: swift winshot.swift <pid> <outfile>
// Captures the frontmost layer-0 window OWNED BY <pid> — never anyone else's.
guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]) else {
    print("usage: winshot <pid> <out.png>"); exit(2)
}
let out = CommandLine.arguments[2]
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in info {
    guard let ownerPID = w[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
          let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
          let num = w[kCGWindowNumber as String] as? Int else { continue }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-o", "-x", "-l", "\(num)", out]
    try! task.run()
    task.waitUntilExit()
    print("captured window \(num) of pid \(pid) -> \(out)")
    exit(task.terminationStatus)
}
print("no on-screen window for pid \(pid)")
exit(1)
