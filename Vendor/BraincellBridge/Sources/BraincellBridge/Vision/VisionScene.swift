import Foundation
import CoreGraphics

/// Snapshot of recognized text on a captured image, in image-space pixel
/// coordinates (top-left origin) so callers don't have to think about
/// Vision's flipped normalized coords. One scene = one screenshot — there's
/// no notion of staleness here; the caller decides how long a scene is good
/// for.
///
/// `VisionFinder.index(_:)` produces these from a CGImage; downstream code
/// uses `match(query:)` to answer "where is X?" without round-tripping
/// through the model.
struct VisionScene: Sendable {
    /// One recognized text region. `bounds` is in image-space pixels with the
    /// origin at the top-left, matching what AppKit / CG expect when you draw
    /// over the image. `confidence` is whatever Vision reports (0–1, but
    /// `.accurate` mode usually clusters above 0.5).
    struct TextItem: Codable, Hashable, Sendable {
        let text: String
        let bounds: CGRect
        let confidence: Float
    }

    let items: [TextItem]
    let imageSize: CGSize
    let capturedAt: Date

    /// Rank candidates against `query` using a tiered match: exact (case-
    /// insensitive equality) > prefix > substring, with confidence as the
    /// tiebreaker. `threshold` filters by confidence after tier sorting; items
    /// below it are dropped entirely. Returns at most `limit` matches.
    ///
    /// Intentionally simple. Real disambiguation ("the *second* Submit
    /// button", "the one in the sidebar") will live elsewhere — this is the
    /// substrate, not the strategy.
    func match(query: String, threshold: Float = 0.5, limit: Int = 5) -> [TextItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        // Tier values are sortable: lower = better.
        func tier(_ text: String) -> Int {
            let t = text.lowercased()
            if t == q { return 0 }
            if t.hasPrefix(q) { return 1 }
            if t.contains(q) { return 2 }
            return Int.max
        }

        let scored: [(item: TextItem, tier: Int)] = items.compactMap { item in
            guard item.confidence >= threshold else { return nil }
            let t = tier(item.text)
            guard t < Int.max else { return nil }
            return (item, t)
        }

        let ranked = scored.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            return lhs.item.confidence > rhs.item.confidence
        }
        return Array(ranked.prefix(min(max(limit, 0), 1_000))).map { $0.item }
    }
}
