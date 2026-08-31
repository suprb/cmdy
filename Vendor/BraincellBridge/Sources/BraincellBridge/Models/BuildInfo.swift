import Foundation

/// "When was this binary built?" — read from the executable's mtime at
/// runtime. Cheaper than baking a constant via Package.swift codegen
/// (which would need a build-tool plugin) and updates automatically
/// every rebuild. Surfaced in the popover so the user can confirm at
/// a glance which binary they're running, without `stat`-ing the file.
enum BuildInfo {
    /// Modification time of `Bundle.main.executableURL` — equals the
    /// link timestamp for SwiftPM-built binaries.
    static var binaryDate: Date? {
        guard let path = Bundle.main.executableURL?.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    /// Compact stamp for the popover header. Today's builds → "15:12";
    /// older → "May 2 15:12". Date is noise during a dev session (you
    /// rebuild repeatedly the same day), so dropping it for today's
    /// binaries keeps the pill on one line in the constrained header.
    /// Locale-stable (no AM/PM, no commas — just calendar.month + 24h).
    static var shortStamp: String {
        guard let d = binaryDate else { return "?" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let isToday = Calendar(identifier: .gregorian).isDateInToday(d)
        f.dateFormat = isToday ? "HH:mm" : "MMM d HH:mm"
        return f.string(from: d)
    }
}
