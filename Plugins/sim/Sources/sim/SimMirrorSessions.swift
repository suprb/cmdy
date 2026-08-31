import CoreGraphics
import Darwin
import Foundation

/// Stable ownership for streamed Simulator mirrors. Each Cmdy native tab
/// is an NSWindow with its own WindowServer id, so that id is the correct
/// lifetime and routing key for both ordinary windows and sidebar tabs.
struct SimMirrorSlot: Equatable {
    let windowNumber: CGWindowID
    let port: Int
    let device: String?
    let generation: UUID

    var url: URL {
        URL(string: "http://localhost:\(port)")!
    }
}

/// Reserves one preview port per Cmdy window without conflating the
/// process lifecycle with the pure allocation policy. Keeping this small and
/// deterministic makes the multi-window behavior straightforward to test.
struct SimMirrorSlots {
    static let defaultPorts = 3200...3299

    private(set) var byWindow: [CGWindowID: SimMirrorSlot] = [:]

    func slot(for windowNumber: CGWindowID) -> SimMirrorSlot? {
        byWindow[windowNumber]
    }

    mutating func reserve(
        for windowNumber: CGWindowID,
        device: String?,
        ports: ClosedRange<Int> = Self.defaultPorts,
        isPortAvailable: (Int) -> Bool
    ) -> (slot: SimMirrorSlot, inserted: Bool)? {
        if let existing = byWindow[windowNumber] {
            return (existing, false)
        }
        let reserved = Set(byWindow.values.map(\.port))
        guard let port = ports.first(where: {
            !reserved.contains($0) && isPortAvailable($0)
        }) else {
            return nil
        }
        let slot = SimMirrorSlot(
            windowNumber: windowNumber,
            port: port,
            device: device,
            generation: UUID())
        byWindow[windowNumber] = slot
        return (slot, true)
    }

    @discardableResult
    mutating func release(_ windowNumber: CGWindowID) -> SimMirrorSlot? {
        byWindow.removeValue(forKey: windowNumber)
    }

    var all: [SimMirrorSlot] {
        byWindow.values.sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.windowNumber < $1.windowNumber
        }
    }
}

enum SimMirrorPortProbe {
    /// Test a loopback TCP port immediately before handing it to serve-sim.
    /// The close-to-launch race is unavoidable without owning serve-sim's
    /// listener, but excluding both live listeners and our reserved slots
    /// keeps that race extremely narrow.
    static func isAvailable(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
