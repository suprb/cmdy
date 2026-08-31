import AppKit

public enum WindowGridAxis: String, Codable, Equatable {
    case vertical
    case horizontal
}

public enum WindowGridEdge: String, Codable, Equatable {
    case left
    case right
    case top
    case bottom
}

/// A recursive layout of independent native windows. Vertical splits place the
/// first child on the left; horizontal splits place the first child on top.
public indirect enum WindowGridNode: Codable, Equatable {
    case leaf(String)
    case split(
        axis: WindowGridAxis,
        ratio: CGFloat,
        first: WindowGridNode,
        second: WindowGridNode)

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case axis
        case ratio
        case first
        case second
    }

    private enum NodeType: String, Codable {
        case leaf
        case split
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(NodeType.self, forKey: .type) {
        case .leaf:
            self = .leaf(try values.decode(String.self, forKey: .id))
        case .split:
            let axis = try values.decode(WindowGridAxis.self, forKey: .axis)
            let ratio = try values.decode(CGFloat.self, forKey: .ratio)
            guard ratio.isFinite, ratio > 0, ratio < 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .ratio,
                    in: values,
                    debugDescription: "Window-grid split ratio must be between zero and one")
            }
            self = .split(
                axis: axis,
                ratio: ratio,
                first: try values.decode(WindowGridNode.self, forKey: .first),
                second: try values.decode(WindowGridNode.self, forKey: .second))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            try values.encode(NodeType.leaf, forKey: .type)
            try values.encode(id, forKey: .id)
        case .split(let axis, let ratio, let first, let second):
            try values.encode(NodeType.split, forKey: .type)
            try values.encode(axis, forKey: .axis)
            try values.encode(ratio, forKey: .ratio)
            try values.encode(first, forKey: .first)
            try values.encode(second, forKey: .second)
        }
    }
}

public struct WindowGridResizeBoundary: Equatable {
    public let splitPath: [Int]
    public let edge: WindowGridEdge
    public let containerFrame: CGRect
    public let gap: CGFloat
    public let minimumRatio: CGFloat
    public let maximumRatio: CGFloat

    public init(
        splitPath: [Int],
        edge: WindowGridEdge,
        containerFrame: CGRect,
        gap: CGFloat,
        minimumRatio: CGFloat,
        maximumRatio: CGFloat
    ) {
        self.splitPath = splitPath
        self.edge = edge
        self.containerFrame = containerFrame
        self.gap = gap
        self.minimumRatio = minimumRatio
        self.maximumRatio = maximumRatio
    }
}

public struct WindowGridStoredFrame: Codable, Equatable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public init(_ frame: CGRect) {
        x = frame.origin.x
        y = frame.origin.y
        width = frame.size.width
        height = frame.size.height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct WindowGridStoredState: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var trees: [String: WindowGridNode]
    public var manualFrames: [String: WindowGridStoredFrame]

    public init(
        version: Int = WindowGridStoredState.currentVersion,
        trees: [String: WindowGridNode] = [:],
        manualFrames: [String: WindowGridStoredFrame] = [:]
    ) {
        self.version = version
        self.trees = trees
        self.manualFrames = manualFrames
    }

    public var isSupported: Bool { version == Self.currentVersion }
}

public enum WindowGridLayout {
    /// Keep a native resize target without imposing a conventional app-window
    /// size. Very compact terminal tiles are an intentional grid use case.
    public static let defaultMinimumSize = CGSize(width: 120, height: 80)

    private struct LeafInfo {
        let id: String
        let path: [Int]
        let frame: CGRect
    }

    private struct InsertionCandidate {
        let path: [Int]
        let frame: CGRect
        let axis: WindowGridAxis
        let ratio: CGFloat
    }

    public static func resolvedGap(_ gap: CGFloat, scale: CGFloat) -> CGFloat {
        let safeScale = max(1, scale.isFinite ? scale : 1)
        return (max(0, gap) * safeScale).rounded() / safeScale
    }

    public static func leafIDs(in node: WindowGridNode?) -> [String] {
        guard let node else { return [] }
        switch node {
        case .leaf(let id):
            return [id]
        case .split(_, _, let first, let second):
            return leafIDs(in: first) + leafIDs(in: second)
        }
    }

    public static func contains(_ id: String, in node: WindowGridNode?) -> Bool {
        leafIDs(in: node).contains(id)
    }

    public static func frames(
        for node: WindowGridNode?,
        in frame: CGRect,
        gap: CGFloat,
        scale: CGFloat
    ) -> [String: CGRect] {
        guard let node else { return [:] }
        let resolved = resolvedGap(gap, scale: scale)
        var result: [String: CGRect] = [:]
        var leaves: [LeafInfo] = []
        collectFrames(
            node,
            frame: frame,
            gap: resolved,
            scale: max(1, scale),
            path: [],
            result: &result,
            leaves: &leaves)
        return result
    }

    /// Insert into the largest feasible leaf. Ties prefer rightmost, then
    /// bottommost. The requested 50/50 split is clamped to both child minimums.
    public static func inserting(
        _ id: String,
        into node: WindowGridNode?,
        in frame: CGRect,
        gap: CGFloat,
        scale: CGFloat,
        minimumSizes: [String: CGSize] = [:],
        defaultMinimumSize: CGSize = defaultMinimumSize
    ) -> WindowGridNode? {
        guard let node else { return .leaf(id) }
        guard !contains(id, in: node) else { return node }

        let resolved = resolvedGap(gap, scale: scale)
        var ignored: [String: CGRect] = [:]
        var leaves: [LeafInfo] = []
        collectFrames(
            node,
            frame: frame,
            gap: resolved,
            scale: max(1, scale),
            path: [],
            result: &ignored,
            leaves: &leaves)

        let newMinimum = minimumSizes[id] ?? defaultMinimumSize
        var candidates: [InsertionCandidate] = []
        for leaf in leaves {
            let existingMinimum = minimumSizes[leaf.id] ?? defaultMinimumSize
            let preferred: WindowGridAxis = leaf.frame.width >= leaf.frame.height
                ? .vertical : .horizontal
            let axes: [WindowGridAxis] = preferred == .vertical
                ? [.vertical, .horizontal] : [.horizontal, .vertical]
            for axis in axes {
                guard let ratio = feasibleRatio(
                    axis: axis,
                    frame: leaf.frame,
                    gap: resolved,
                    firstMinimum: existingMinimum,
                    secondMinimum: newMinimum)
                else { continue }
                candidates.append(InsertionCandidate(
                    path: leaf.path,
                    frame: leaf.frame,
                    axis: axis,
                    ratio: ratio))
                break
            }
        }

        guard let candidate = candidates.sorted(by: candidatePrecedes).first else {
            return nil
        }
        return replacing(node, at: candidate.path) { existing in
            .split(
                axis: candidate.axis,
                ratio: candidate.ratio,
                first: existing,
                second: .leaf(id))
        }
    }

    public static func removing(
        _ id: String,
        from node: WindowGridNode?
    ) -> WindowGridNode? {
        guard let node else { return nil }
        switch node {
        case .leaf(let leafID):
            return leafID == id ? nil : node
        case .split(let axis, let ratio, let first, let second):
            let nextFirst = removing(id, from: first)
            let nextSecond = removing(id, from: second)
            switch (nextFirst, nextSecond) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let a?, let b?):
                return .split(axis: axis, ratio: ratio, first: a, second: b)
            }
        }
    }

    /// Move a leaf ID into another existing slot and shift all intervening IDs.
    /// Tree topology and user-adjusted split ratios remain unchanged.
    public static func moving(
        _ id: String,
        to targetID: String,
        in node: WindowGridNode
    ) -> WindowGridNode {
        guard id != targetID else { return node }
        var ids = leafIDs(in: node)
        guard let sourceIndex = ids.firstIndex(of: id),
              let targetIndex = ids.firstIndex(of: targetID)
        else { return node }
        ids.remove(at: sourceIndex)
        ids.insert(id, at: min(targetIndex, ids.count))
        var iterator = ids.makeIterator()
        return replacingLeafIDs(in: node, iterator: &iterator)
    }

    public static func resizeBoundaries(
        for id: String,
        in node: WindowGridNode,
        frame: CGRect,
        gap: CGFloat,
        scale: CGFloat,
        minimumSizes: [String: CGSize] = [:],
        defaultMinimumSize: CGSize = defaultMinimumSize
    ) -> [WindowGridResizeBoundary] {
        let resolved = resolvedGap(gap, scale: scale)
        let allFrames = frames(
            for: node, in: frame, gap: resolved, scale: scale)
        guard let leafFrame = allFrames[id] else { return [] }
        var result: [WindowGridResizeBoundary] = []
        collectBoundaries(
            node,
            targetID: id,
            targetFrame: leafFrame,
            frame: frame,
            gap: resolved,
            scale: max(1, scale),
            minimumSizes: minimumSizes,
            defaultMinimumSize: defaultMinimumSize,
            path: [],
            result: &result)
        return result
    }

    public static func ratio(
        for windowFrame: CGRect,
        boundary: WindowGridResizeBoundary
    ) -> CGFloat {
        let container = boundary.containerFrame
        let raw: CGFloat
        switch boundary.edge {
        case .right:
            let usable = max(1, container.width - boundary.gap)
            raw = (windowFrame.maxX - container.minX) / usable
        case .left:
            let usable = max(1, container.width - boundary.gap)
            raw = (windowFrame.minX - container.minX - boundary.gap) / usable
        case .bottom:
            let usable = max(1, container.height - boundary.gap)
            raw = (container.maxY - windowFrame.minY) / usable
        case .top:
            let usable = max(1, container.height - boundary.gap)
            raw = (container.maxY - boundary.gap - windowFrame.maxY) / usable
        }
        return min(boundary.maximumRatio, max(boundary.minimumRatio, raw))
    }

    public static func settingRatio(
        _ ratio: CGFloat,
        at splitPath: [Int],
        in node: WindowGridNode
    ) -> WindowGridNode {
        replacing(node, at: splitPath) { existing in
            guard case .split(let axis, _, let first, let second) = existing else {
                return existing
            }
            return .split(
                axis: axis,
                ratio: min(0.999, max(0.001, ratio)),
                first: first,
                second: second)
        }
    }

    // MARK: - Internal geometry

    private static func feasibleRatio(
        axis: WindowGridAxis,
        frame: CGRect,
        gap: CGFloat,
        firstMinimum: CGSize,
        secondMinimum: CGSize
    ) -> CGFloat? {
        let available: CGFloat
        let first: CGFloat
        let second: CGFloat
        switch axis {
        case .vertical:
            available = frame.width - gap
            first = firstMinimum.width
            second = secondMinimum.width
            guard frame.height >= max(firstMinimum.height, secondMinimum.height) else {
                return nil
            }
        case .horizontal:
            available = frame.height - gap
            first = firstMinimum.height
            second = secondMinimum.height
            guard frame.width >= max(firstMinimum.width, secondMinimum.width) else {
                return nil
            }
        }
        guard available > 0, available >= first + second else { return nil }
        let minimumRatio = first / available
        let maximumRatio = 1 - second / available
        guard minimumRatio <= maximumRatio else { return nil }
        return min(maximumRatio, max(minimumRatio, 0.5))
    }

    private static func candidatePrecedes(
        _ lhs: InsertionCandidate,
        _ rhs: InsertionCandidate
    ) -> Bool {
        let lhsArea = lhs.frame.width * lhs.frame.height
        let rhsArea = rhs.frame.width * rhs.frame.height
        if abs(lhsArea - rhsArea) > 0.5 { return lhsArea > rhsArea }
        if abs(lhs.frame.maxX - rhs.frame.maxX) > 0.5 {
            return lhs.frame.maxX > rhs.frame.maxX
        }
        if abs(lhs.frame.minY - rhs.frame.minY) > 0.5 {
            return lhs.frame.minY < rhs.frame.minY
        }
        return lhs.path.lexicographicallyPrecedes(rhs.path)
    }

    private static func collectFrames(
        _ node: WindowGridNode,
        frame: CGRect,
        gap: CGFloat,
        scale: CGFloat,
        path: [Int],
        result: inout [String: CGRect],
        leaves: inout [LeafInfo]
    ) {
        switch node {
        case .leaf(let id):
            result[id] = frame
            leaves.append(LeafInfo(id: id, path: path, frame: frame))
        case .split(let axis, let ratio, let first, let second):
            let children = childFrames(
                axis: axis,
                ratio: ratio,
                in: frame,
                gap: gap,
                scale: scale)
            collectFrames(
                first,
                frame: children.first,
                gap: gap,
                scale: scale,
                path: path + [0],
                result: &result,
                leaves: &leaves)
            collectFrames(
                second,
                frame: children.second,
                gap: gap,
                scale: scale,
                path: path + [1],
                result: &result,
                leaves: &leaves)
        }
    }

    private static func childFrames(
        axis: WindowGridAxis,
        ratio: CGFloat,
        in frame: CGRect,
        gap: CGFloat,
        scale: CGFloat
    ) -> (first: CGRect, second: CGRect) {
        let clamped = min(0.999, max(0.001, ratio))
        switch axis {
        case .vertical:
            let usable = max(0, frame.width - gap)
            let firstWidth = pixelRound(usable * clamped, scale: scale)
            let secondWidth = max(0, usable - firstWidth)
            return (
                CGRect(x: frame.minX, y: frame.minY,
                       width: firstWidth, height: frame.height),
                CGRect(x: frame.minX + firstWidth + gap, y: frame.minY,
                       width: secondWidth, height: frame.height))
        case .horizontal:
            let usable = max(0, frame.height - gap)
            let firstHeight = pixelRound(usable * clamped, scale: scale)
            let secondHeight = max(0, usable - firstHeight)
            return (
                CGRect(x: frame.minX, y: frame.maxY - firstHeight,
                       width: frame.width, height: firstHeight),
                CGRect(x: frame.minX, y: frame.minY,
                       width: frame.width, height: secondHeight))
        }
    }

    private static func pixelRound(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * max(1, scale)).rounded() / max(1, scale)
    }

    private static func replacing(
        _ node: WindowGridNode,
        at path: [Int],
        transform: (WindowGridNode) -> WindowGridNode
    ) -> WindowGridNode {
        guard let head = path.first else { return transform(node) }
        guard case .split(let axis, let ratio, let first, let second) = node else {
            return node
        }
        let tail = Array(path.dropFirst())
        if head == 0 {
            return .split(
                axis: axis,
                ratio: ratio,
                first: replacing(first, at: tail, transform: transform),
                second: second)
        }
        return .split(
            axis: axis,
            ratio: ratio,
            first: first,
            second: replacing(second, at: tail, transform: transform))
    }

    private static func replacingLeafIDs<I: IteratorProtocol>(
        in node: WindowGridNode,
        iterator: inout I
    ) -> WindowGridNode where I.Element == String {
        switch node {
        case .leaf:
            return .leaf(iterator.next() ?? "")
        case .split(let axis, let ratio, let first, let second):
            return .split(
                axis: axis,
                ratio: ratio,
                first: replacingLeafIDs(in: first, iterator: &iterator),
                second: replacingLeafIDs(in: second, iterator: &iterator))
        }
    }

    private static func minimumSize(
        of node: WindowGridNode,
        gap: CGFloat,
        minimumSizes: [String: CGSize],
        defaultMinimumSize: CGSize
    ) -> CGSize {
        switch node {
        case .leaf(let id):
            return minimumSizes[id] ?? defaultMinimumSize
        case .split(let axis, _, let first, let second):
            let a = minimumSize(
                of: first, gap: gap,
                minimumSizes: minimumSizes,
                defaultMinimumSize: defaultMinimumSize)
            let b = minimumSize(
                of: second, gap: gap,
                minimumSizes: minimumSizes,
                defaultMinimumSize: defaultMinimumSize)
            switch axis {
            case .vertical:
                return CGSize(
                    width: a.width + gap + b.width,
                    height: max(a.height, b.height))
            case .horizontal:
                return CGSize(
                    width: max(a.width, b.width),
                    height: a.height + gap + b.height)
            }
        }
    }

    private static func collectBoundaries(
        _ node: WindowGridNode,
        targetID: String,
        targetFrame: CGRect,
        frame: CGRect,
        gap: CGFloat,
        scale: CGFloat,
        minimumSizes: [String: CGSize],
        defaultMinimumSize: CGSize,
        path: [Int],
        result: inout [WindowGridResizeBoundary]
    ) {
        guard case .split(let axis, let ratio, let first, let second) = node else {
            return
        }
        let children = childFrames(
            axis: axis, ratio: ratio, in: frame, gap: gap, scale: scale)
        let inFirst = contains(targetID, in: first)
        let inSecond = contains(targetID, in: second)
        guard inFirst || inSecond else { return }

        let firstMinimum = minimumSize(
            of: first, gap: gap,
            minimumSizes: minimumSizes,
            defaultMinimumSize: defaultMinimumSize)
        let secondMinimum = minimumSize(
            of: second, gap: gap,
            minimumSizes: minimumSizes,
            defaultMinimumSize: defaultMinimumSize)
        let available = axis == .vertical
            ? max(1, frame.width - gap)
            : max(1, frame.height - gap)
        let minimumRatio = axis == .vertical
            ? firstMinimum.width / available
            : firstMinimum.height / available
        let maximumRatio = axis == .vertical
            ? 1 - secondMinimum.width / available
            : 1 - secondMinimum.height / available
        let epsilon = 1 / max(1, scale) + 0.01

        if inFirst {
            let edge: WindowGridEdge = axis == .vertical ? .right : .bottom
            let aligned = axis == .vertical
                ? abs(targetFrame.maxX - children.first.maxX) <= epsilon
                : abs(targetFrame.minY - children.first.minY) <= epsilon
            if aligned, minimumRatio <= maximumRatio {
                result.append(WindowGridResizeBoundary(
                    splitPath: path,
                    edge: edge,
                    containerFrame: frame,
                    gap: gap,
                    minimumRatio: minimumRatio,
                    maximumRatio: maximumRatio))
            }
            collectBoundaries(
                first,
                targetID: targetID,
                targetFrame: targetFrame,
                frame: children.first,
                gap: gap,
                scale: scale,
                minimumSizes: minimumSizes,
                defaultMinimumSize: defaultMinimumSize,
                path: path + [0],
                result: &result)
        } else if inSecond {
            let edge: WindowGridEdge = axis == .vertical ? .left : .top
            let aligned = axis == .vertical
                ? abs(targetFrame.minX - children.second.minX) <= epsilon
                : abs(targetFrame.maxY - children.second.maxY) <= epsilon
            if aligned, minimumRatio <= maximumRatio {
                result.append(WindowGridResizeBoundary(
                    splitPath: path,
                    edge: edge,
                    containerFrame: frame,
                    gap: gap,
                    minimumRatio: minimumRatio,
                    maximumRatio: maximumRatio))
            }
            collectBoundaries(
                second,
                targetID: targetID,
                targetFrame: targetFrame,
                frame: children.second,
                gap: gap,
                scale: scale,
                minimumSizes: minimumSizes,
                defaultMinimumSize: defaultMinimumSize,
                path: path + [1],
                result: &result)
        }
    }
}
