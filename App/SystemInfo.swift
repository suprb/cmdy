import Foundation
import ProductIdentity
import CmdyKit
import Darwin

/// Builds the boot banner: the product mark on the left and a spec sheet of
/// real Mac data on the right.
enum SystemInfo {
    static func bootBanner() -> String {
        let ram = humanBytes(ProcessInfo.processInfo.physicalMemory)
        let free = humanBytes(freeMemoryBytes())
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let cores = ProcessInfo.processInfo.processorCount
        let model = sysctl("hw.model") ?? "Apple Mac"
        let chip = sysctl("machdep.cpu.brand_string") ?? "Apple Silicon"
        #if arch(arm64)
        let arch = "ARM64"
        #else
        let arch = "X86-64"
        #endif

        let reset = "\u{1b}[0m"
        // Truecolor so the logo is vivid & consistent on every theme (256-color
        // indices get remapped through each theme's palette and look muddy).
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> String { "\u{1b}[38;2;\(r);\(g);\(b)m" }

        // A terminal-cell reduction of Brand/Assets/cmdy-logo-source.png. Each
        // glyph carries two vertical source pixels so the tall, condensed cmdy
        // geometry survives in a compact terminal badge.
        let logo = [
            "▄████▄ ███   ██  ██████▄ ██   ██",
            "█   ▀█ ███   ██▄ █▀   ██ ▀█▄ ▄█",
            "█    █ ███▄  ███ █    ██  ██ ██",
            "█      ████ ████ █    ██  ▀█▄█",
            "█      ██ █ █ ██ █    ██   ███",
            "█      ██ █ █ ██ █    ██   ▀█",
            "█    ▄ ██ █▄█ ██ █    ██    █",
            "█    █ ██ ███ ██ █    ██    █",
            "█   ▄█ ██ ▀█▀ ██ █▄   ██    █",
            "▀████▀ ██  █  ██ ██████▀    █",
        ]

        // Spec sheet, beside the middle logo rows (ChiCLI style).
        let specs = [
            "MODEL   \(model)",
            "CHIP    \(chip)  ·  \(cores) cores",
            "MEMORY  \(ram)  ·  \(free) free",
            "SYSTEM  macOS \(os)",
        ]

        // The supplied logo is white on black. Preserve that treatment on
        // every theme instead of recoloring the badge through the palette.
        let logoWidth = logo.map(\.count).max() ?? 0
        let badgeForeground = rgb(248, 248, 248)
        let badgeBackground = "\u{1b}[48;2;0;0;0m"
        let blankBadgeRow = badgeBackground + String(
            repeating: " ", count: logoWidth + 2) + reset
        var canvasRows: [String] = [blankBadgeRow]
        for line in logo {
            let padded = line.padding(toLength: logoWidth, withPad: " ", startingAt: 0)
            canvasRows.append(
                badgeBackground + badgeForeground + " " + padded + " " + reset)
        }
        canvasRows.append(blankBadgeRow)

        var out = "\r\n   " + rgb(150, 150, 150)
            + "\(ProductIdentity.current.displayName) v1  ·  (c) 2026  ·  \(arch)"
            + reset + "\r\n\r\n"
        for i in 0..<canvasRows.count {
            // specs sit beside the middle rows of the mark
            let spec = (i >= 3 && i - 3 < specs.count) ? "    " + specs[i - 3] : ""
            out += "   " + canvasRows[i] + spec + "\r\n"
        }
        out += "\r\n   " + rgb(80, 220, 100) + "Ready!" + reset + "\r\n\r\n"
        return out
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }

    private static func humanBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1 { return "\(Int(gb.rounded()))G" }
        return "\(Int((Double(bytes) / 1_048_576.0).rounded()))M"
    }

    private static func freeMemoryBytes() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_page_size)
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
        return pages * pageSize
    }
}
