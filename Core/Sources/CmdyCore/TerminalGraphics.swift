import Foundation

/// The kitty graphics store: images by id + placement records. Payloads
/// stay encoded (PNG) or raw (RGBA) — decoding pixels for DISPLAY is the
/// renderer's job; core only needs dimensions and bookkeeping.
public final class KittyGraphicsStore {
    public struct Placement {
        public var imageId: UInt32
        public var placementId: UInt32
        public var col: Int
        public var row: Int            // absolute buffer row of attachment
        public var cols: Int
        public var rows: Int
        public var zIndex: Int
        public var pixelOffsetX: Int
        public var pixelOffsetY: Int
        public var isVirtual: Bool
        public var isAlternateBuffer: Bool
    }

    public final class Image {
        public let id: UInt32
        public let number: UInt32?
        public let payload: LineImage.Payload
        public let pixelWidth: Int
        public let pixelHeight: Int
        init(id: UInt32, number: UInt32?, payload: LineImage.Payload, width: Int, height: Int) {
            self.id = id
            self.number = number
            self.payload = payload
            self.pixelWidth = width
            self.pixelHeight = height
        }
    }

    public private(set) var imagesById: [UInt32: Image] = [:]
    public private(set) var placementsByKey: [String: Placement] = [:]
    public private(set) var nextImageId: UInt32 = 1
    public private(set) var nextPlacementId: UInt32 = 1
    public private(set) var payloadBytes = 0

    private static let maxImages = 256
    private static let maxPlacements = 4_096
    private static let maxPayloadBytes = 128 * 1024 * 1024

    @discardableResult
    func store(_ image: Image) -> Bool {
        guard image.id != 0, let cost = Self.payloadByteCount(image) else { return false }
        let previous = imagesById[image.id]
        let previousCost = previous.flatMap { Self.payloadByteCount($0) } ?? 0
        let base = max(0, payloadBytes - previousCost)
        let (newTotal, overflow) = base.addingReportingOverflow(cost)
        guard !overflow, newTotal <= Self.maxPayloadBytes,
              previous != nil || imagesById.count < Self.maxImages else {
            return false
        }

        if previous != nil {
            _ = removePlacements { $0.imageId == image.id }
        }
        imagesById[image.id] = image
        payloadBytes = newTotal
        nextImageId = nextAvailableImageID(after: image.id)
        return true
    }

    @discardableResult
    func place(_ placement: Placement) -> Bool {
        var value = placement
        if value.placementId == 0 {
            value.placementId = nextPlacementId
        }
        let key = Self.placementKey(
            imageId: value.imageId, placementId: value.placementId)
        guard placementsByKey[key] != nil
                || placementsByKey.count < Self.maxPlacements else {
            return false
        }
        placementsByKey[key] = value
        nextPlacementId = nextAvailablePlacementID(after: value.placementId)
        return true
    }

    func deleteImage(id: UInt32) {
        guard let image = imagesById.removeValue(forKey: id) else { return }
        let cost = Self.payloadByteCount(image) ?? 0
        payloadBytes = max(0, payloadBytes - cost)
        _ = removePlacements { $0.imageId == id }
    }

    func deletePlacements(imageId: UInt32) {
        _ = removePlacements { $0.imageId == imageId }
    }

    func deleteAll() {
        imagesById.removeAll(keepingCapacity: true)
        placementsByKey.removeAll(keepingCapacity: true)
        payloadBytes = 0
        nextImageId = 1
        nextPlacementId = 1
    }

    func newestImage(number: UInt32) -> Image? {
        imagesById.values
            .filter { $0.number == number }
            .max { $0.id < $1.id }
    }

    @discardableResult
    func removePlacements(where shouldRemove: (Placement) -> Bool) -> [Placement] {
        let keys = placementsByKey.compactMap { key, placement in
            shouldRemove(placement) ? key : nil
        }
        var removed: [Placement] = []
        removed.reserveCapacity(keys.count)
        for key in keys {
            if let placement = placementsByKey.removeValue(forKey: key) {
                removed.append(placement)
            }
        }
        return removed
    }

    func hasPlacement(imageId: UInt32) -> Bool {
        placementsByKey.values.contains { $0.imageId == imageId }
    }

    private static func payloadByteCount(_ image: Image) -> Int? {
        switch image.payload {
        case .png(let data):
            return data.count
        case .rgba(let bytes, _, _):
            return bytes.count
        }
    }

    private static func placementKey(imageId: UInt32, placementId: UInt32) -> String {
        "\(imageId):\(placementId)"
    }

    private func nextAvailableImageID(after id: UInt32) -> UInt32 {
        var candidate = id == UInt32.max ? 1 : id + 1
        for _ in 0...imagesById.count {
            if imagesById[candidate] == nil { return candidate }
            candidate = candidate == UInt32.max ? 1 : candidate + 1
        }
        return candidate
    }

    private func nextAvailablePlacementID(after id: UInt32) -> UInt32 {
        var candidate = id == UInt32.max ? 1 : id + 1
        for _ in 0...placementsByKey.count {
            let occupied = placementsByKey.values.contains {
                $0.placementId == candidate
            }
            if !occupied { return candidate }
            candidate = candidate == UInt32.max ? 1 : candidate + 1
        }
        return candidate
    }

}

// Kitty APC (ESC _ G … ESC \), sixel DCS, and iTerm2 OSC 1337 — the three
// inline-image dialects, all decoded to LineImage cells on buffer rows.
extension CmdyTerminal {
    private static let maxInlineImageEncodedBytes = 96 * 1024 * 1024
    private static let maxInlineImagePayloadBytes = 128 * 1024 * 1024
    private static let maxInlineImagePixels = 16 * 1024 * 1024
    private static let maxInlineImageDimension = 16_384
    private static let maxInlineImageCellSpan = 1_024

    // MARK: - Kitty

    enum KittyAction: Equatable {
        case transmit
        case transmitAndPlace
        case place
        case delete
        case query
        case unsupported(Character)
    }

    enum KittyFormat: Int {
        case rgb = 24
        case rgba = 32
        case png = 100
    }

    enum KittyCompression {
        case none
        case zlib
    }

    enum KittyProtocolError: String, Error {
        case invalid = "EINVAL"
        case missing = "ENOENT"
        case tooLarge = "E2BIG"
        case noSpace = "ENOSPC"
    }

    struct KittyControl {
        var action: KittyAction = .transmit
        var format: KittyFormat = .rgba
        var imageId: UInt32 = 0
        var imageNumber: UInt32 = 0
        var placementId: UInt32 = 0
        var width = 0
        var height = 0
        var cellCols = 0
        var cellRows = 0
        var sourceX = 0
        var sourceY = 0
        var zIndex = 0
        var more = false
        var quiet = 0
        var virtualPlacement = false
        var offsetX = 0
        var offsetY = 0
        var noCursorMove = false
        var compression: KittyCompression = .none
        var transmission: Character = "d"
        var deleteWhat: Character = "a"
    }

    struct KittyAPCResult {
        struct PlacementKey: Hashable {
            let imageId: UInt32
            let placementId: UInt32
        }

        struct Display {
            let imageId: UInt32
            let placementId: UInt32
            let isVirtual: Bool
        }

        var shouldApplyDisplayLineMotion = false
        var committedTransmissionImageId: UInt32?
        var display: Display?
        var removedPlacementKeys: Set<PlacementKey> = []

        static let none = KittyAPCResult()
    }

    private struct KittyEnvelope {
        let control: KittyControl
        let payload: ArraySlice<UInt8>
    }

    private enum KittyChunkStore {
        static func append(_ bytes: ArraySlice<UInt8>, to storage: inout [UInt8],
                           limit: Int) -> Bool {
            guard storage.count <= limit,
                  bytes.count <= limit - storage.count else {
                return false
            }
            storage.append(contentsOf: bytes)
            return true
        }
    }

    private static func decodeKittyEnvelope(
        _ bytes: ArraySlice<UInt8>
    ) -> Result<KittyEnvelope, KittyProtocolError> {
        guard bytes.first == UInt8(ascii: "G") else { return .failure(.invalid) }
        let body = bytes.dropFirst()
        let separator = body.firstIndex(of: UInt8(ascii: ";"))
        let controls = separator.map { body[..<$0] } ?? body[...]
        let payload = separator.map { body[body.index(after: $0)...] }
            ?? body[body.endIndex...]

        guard let text = String(bytes: controls, encoding: .ascii) else {
            return .failure(.invalid)
        }
        var control = KittyControl()

        func uint32(_ text: Substring) -> UInt32? {
            guard !text.isEmpty, text.allSatisfy(\.isNumber) else { return nil }
            return UInt32(text)
        }

        func nonnegativeInt(_ text: Substring) -> Int? {
            guard let value = uint32(text) else { return nil }
            return Int(exactly: value)
        }

        func signedInt32(_ text: Substring) -> Int? {
            guard let value = Int32(String(text)) else { return nil }
            return Int(value)
        }

        if !text.isEmpty {
            for item in text.split(separator: ",", omittingEmptySubsequences: false) {
                let pair = item.split(separator: "=", maxSplits: 1,
                                      omittingEmptySubsequences: false)
                guard pair.count == 2, pair[0].count == 1 else {
                    return .failure(.invalid)
                }
                let key = pair[0].first!
                let value = pair[1]
                switch key {
                case "a":
                    guard value.count == 1, let action = value.first else {
                        return .failure(.invalid)
                    }
                    switch action {
                    case "t": control.action = .transmit
                    case "T": control.action = .transmitAndPlace
                    case "p": control.action = .place
                    case "d": control.action = .delete
                    case "q": control.action = .query
                    default: control.action = .unsupported(action)
                    }
                case "f":
                    guard let raw = Int(value), let format = KittyFormat(rawValue: raw) else {
                        return .failure(.invalid)
                    }
                    control.format = format
                case "i":
                    guard let parsed = uint32(value) else { return .failure(.invalid) }
                    control.imageId = parsed
                case "I":
                    guard let parsed = uint32(value) else { return .failure(.invalid) }
                    control.imageNumber = parsed
                case "p":
                    guard let parsed = uint32(value) else { return .failure(.invalid) }
                    control.placementId = parsed
                case "s":
                    guard let parsed = nonnegativeInt(value) else { return .failure(.invalid) }
                    control.width = parsed
                case "v":
                    guard let parsed = nonnegativeInt(value) else { return .failure(.invalid) }
                    control.height = parsed
                case "c":
                    guard let parsed = nonnegativeInt(value) else { return .failure(.invalid) }
                    control.cellCols = parsed
                case "r":
                    guard let parsed = nonnegativeInt(value) else { return .failure(.invalid) }
                    control.cellRows = parsed
                case "x":
                    guard let parsed = nonnegativeInt(value) else { return .failure(.invalid) }
                    control.sourceX = parsed
                case "y":
                    guard let parsed = nonnegativeInt(value) else { return .failure(.invalid) }
                    control.sourceY = parsed
                case "z":
                    guard let parsed = signedInt32(value) else { return .failure(.invalid) }
                    control.zIndex = parsed
                case "m":
                    guard value == "0" || value == "1" else { return .failure(.invalid) }
                    control.more = value == "1"
                case "q":
                    guard let parsed = Int(value), (0...2).contains(parsed) else {
                        return .failure(.invalid)
                    }
                    control.quiet = parsed
                case "U":
                    guard value == "0" || value == "1" else { return .failure(.invalid) }
                    control.virtualPlacement = value == "1"
                case "X":
                    guard let parsed = nonnegativeInt(value) else { return .failure(.invalid) }
                    control.offsetX = parsed
                case "Y":
                    guard let parsed = nonnegativeInt(value) else { return .failure(.invalid) }
                    control.offsetY = parsed
                case "C":
                    guard value == "0" || value == "1" else { return .failure(.invalid) }
                    control.noCursorMove = value == "1"
                case "o":
                    guard value == "z" else { return .failure(.invalid) }
                    control.compression = .zlib
                case "t":
                    guard value.count == 1, let medium = value.first else {
                        return .failure(.invalid)
                    }
                    control.transmission = medium
                case "d":
                    guard value.count == 1, let selector = value.first else {
                        return .failure(.invalid)
                    }
                    control.deleteWhat = selector
                default:
                    continue
                }
            }
        }
        guard control.imageId == 0 || control.imageNumber == 0 else {
            return .failure(.invalid)
        }
        return .success(KittyEnvelope(control: control, payload: payload))
    }

    /// Returns normalized metadata for terminal-owned cursor and logical-line
    /// bookkeeping. Image decoding, storage, placement, and replies remain
    /// owned here; callers do not need to parse the APC a second time.
    @discardableResult
    func handleAPCResult(_ bytes: ArraySlice<UInt8>) -> KittyAPCResult {
        guard bytes.first == UInt8(ascii: "G") else { return .none }
        switch Self.decodeKittyEnvelope(bytes) {
        case .failure:
            kittyChunkControl = nil
            kittyChunkData.removeAll(keepingCapacity: true)
            return .none
        case .success(let envelope):
            return executeKitty(envelope)
        }
    }

    @discardableResult
    func handleAPC(_ bytes: ArraySlice<UInt8>) -> Bool {
        handleAPCResult(bytes).shouldApplyDisplayLineMotion
    }

    private func executeKitty(_ envelope: KittyEnvelope) -> KittyAPCResult {
        let control = envelope.control
        if case .delete = control.action {
            kittyChunkControl = nil
            kittyChunkData.removeAll(keepingCapacity: true)
            let removed = handleKittyDelete(control)
            kittyReply(control, error: nil)
            return KittyAPCResult(
                removedPlacementKeys: Set(removed.map {
                    KittyAPCResult.PlacementKey(
                        imageId: $0.imageId, placementId: $0.placementId)
                }))
        }

        switch control.action {
        case .transmit, .transmitAndPlace, .query:
            return receiveKittyPayload(control: control, payload: envelope.payload)
        case .place:
            guard let image = resolveKittyImage(control) else {
                kittyReply(control, error: .missing)
                return .none
            }
            guard let placementId = placeKittyImage(image, control: control) else {
                kittyReply(control, imageId: image.id, error: .noSpace)
                return .none
            }
            kittyReply(control, imageId: image.id, error: nil)
            return KittyAPCResult(
                shouldApplyDisplayLineMotion:
                    !control.virtualPlacement && !control.noCursorMove,
                display: KittyAPCResult.Display(
                    imageId: image.id,
                    placementId: placementId,
                    isVirtual: control.virtualPlacement))
        case .delete:
            return .none
        case .unsupported:
            kittyReply(control, error: .invalid)
            return .none
        }
    }

    private func receiveKittyPayload(control: KittyControl,
                                     payload: ArraySlice<UInt8>) -> KittyAPCResult {
        if let initial = kittyChunkControl {
            guard KittyChunkStore.append(
                payload, to: &kittyChunkData,
                limit: Self.maxInlineImageEncodedBytes) else {
                kittyChunkControl = nil
                kittyChunkData.removeAll(keepingCapacity: true)
                kittyReply(initial, error: .tooLarge)
                return .none
            }
            if control.more { return .none }
            let encoded = kittyChunkData
            kittyChunkControl = nil
            kittyChunkData.removeAll(keepingCapacity: true)
            return finishKittyTransmission(control: initial, encoded: encoded)
        }

        if control.more {
            guard KittyChunkStore.append(
                payload, to: &kittyChunkData,
                limit: Self.maxInlineImageEncodedBytes) else {
                kittyReply(control, error: .tooLarge)
                return .none
            }
            kittyChunkControl = control
            return .none
        }
        return finishKittyTransmission(control: control, encoded: Array(payload))
    }

    private func finishKittyTransmission(control: KittyControl,
                                         encoded: [UInt8]) -> KittyAPCResult {
        switch decodeKittyImage(control, base64: encoded) {
        case .failure(let error):
            kittyReply(control, error: error)
            return .none
        case .success(let image):
            if case .query = control.action {
                kittyReply(control, imageId: image.id, error: nil)
                return .none
            }
            let replacedPlacements = kittyGraphics.placementsByKey.values.filter {
                $0.imageId == image.id
            }
            guard kittyGraphics.store(image) else {
                kittyReply(control, imageId: image.id, error: .noSpace)
                return .none
            }
            if case .transmitAndPlace = control.action {
                guard let placementId = placeKittyImage(image, control: control) else {
                    kittyReply(control, imageId: image.id, error: .noSpace)
                    return KittyAPCResult(
                        committedTransmissionImageId: image.id,
                        removedPlacementKeys: Set(replacedPlacements.map {
                            KittyAPCResult.PlacementKey(
                                imageId: $0.imageId,
                                placementId: $0.placementId)
                        }))
                }
                kittyReply(control, imageId: image.id, error: nil)
                return KittyAPCResult(
                    shouldApplyDisplayLineMotion:
                        !control.virtualPlacement && !control.noCursorMove,
                    committedTransmissionImageId: image.id,
                    display: KittyAPCResult.Display(
                        imageId: image.id,
                        placementId: placementId,
                        isVirtual: control.virtualPlacement),
                    removedPlacementKeys: Set(replacedPlacements.map {
                        KittyAPCResult.PlacementKey(
                            imageId: $0.imageId,
                            placementId: $0.placementId)
                    }))
            }
            kittyReply(control, imageId: image.id, error: nil)
            return KittyAPCResult(
                committedTransmissionImageId: image.id,
                removedPlacementKeys: Set(replacedPlacements.map {
                    KittyAPCResult.PlacementKey(
                        imageId: $0.imageId,
                        placementId: $0.placementId)
                }))
        }
    }

    private func resolveKittyImage(_ control: KittyControl) -> KittyGraphicsStore.Image? {
        if control.imageId != 0 {
            return kittyGraphics.imagesById[control.imageId]
        }
        if control.imageNumber != 0 {
            return kittyGraphics.newestImage(number: control.imageNumber)
        }
        return nil
    }

    private func decodeKittyImage(
        _ control: KittyControl, base64: [UInt8]
    ) -> Result<KittyGraphicsStore.Image, KittyProtocolError> {
        guard control.transmission == "d",
              base64.count <= Self.maxInlineImageEncodedBytes,
              let encoded = Data(base64Encoded: Data(base64)),
              encoded.count <= Self.maxInlineImagePayloadBytes else {
            return .failure(.invalid)
        }

        let data: Data
        switch control.compression {
        case .none:
            data = encoded
        case .zlib:
            guard let inflated = encoded.zlibInflated(
                maxOutputSize: Self.maxInlineImagePayloadBytes) else {
                return .failure(.tooLarge)
            }
            data = inflated
        }

        let id = control.imageId == 0 ? kittyGraphics.nextImageId : control.imageId
        let number = control.imageNumber == 0 ? nil : control.imageNumber
        switch control.format {
        case .png:
            guard data.count <= Self.maxInlineImagePayloadBytes,
                  let (width, height) = Self.pngDimensions(data) else {
                return .failure(.invalid)
            }
            return .success(KittyGraphicsStore.Image(
                id: id, number: number, payload: .png(data),
                width: width, height: height))

        case .rgba:
            guard let pixels = Self.validatedPixelCount(
                width: control.width, height: control.height),
                  let expected = Self.checkedProduct(pixels, 4),
                  expected == data.count else {
                return .failure(.invalid)
            }
            return .success(KittyGraphicsStore.Image(
                id: id, number: number,
                payload: .rgba(bytes: Array(data), width: control.width,
                               height: control.height),
                width: control.width, height: control.height))

        case .rgb:
            guard let pixels = Self.validatedPixelCount(
                width: control.width, height: control.height),
                  let expected = Self.checkedProduct(pixels, 3),
                  expected == data.count,
                  let rgbaCount = Self.checkedProduct(pixels, 4) else {
                return .failure(.invalid)
            }
            var rgba: [UInt8] = []
            rgba.reserveCapacity(rgbaCount)
            for index in stride(from: 0, to: data.count, by: 3) {
                rgba.append(data[index])
                rgba.append(data[index + 1])
                rgba.append(data[index + 2])
                rgba.append(255)
            }
            return .success(KittyGraphicsStore.Image(
                id: id, number: number,
                payload: .rgba(bytes: rgba, width: control.width,
                               height: control.height),
                width: control.width, height: control.height))
        }
    }

    static func pngDimensions(_ data: Data) -> (Int, Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 24,
              Array(data.prefix(8)) == signature,
              Array(data[8..<12]) == [0, 0, 0, 13],
              Array(data[12..<16]) == [0x49, 0x48, 0x44, 0x52] else {
            return nil
        }

        func bigEndian32(at offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
        }
        let widthValue = bigEndian32(at: 16)
        let heightValue = bigEndian32(at: 20)
        guard let width = Int(exactly: widthValue),
              let height = Int(exactly: heightValue),
              validatedPixelCount(width: width, height: height) != nil else {
            return nil
        }
        return (width, height)
    }

    private static func checkedProduct(_ left: Int, _ right: Int) -> Int? {
        let (product, overflow) = left.multipliedReportingOverflow(by: right)
        return overflow || product > maxInlineImagePayloadBytes ? nil : product
    }

    private static func validatedPixelCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0,
              width <= maxInlineImageDimension,
              height <= maxInlineImageDimension else {
            return nil
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxInlineImagePixels else { return nil }
        return pixels
    }

    @discardableResult
    private func placeKittyImage(
        _ image: KittyGraphicsStore.Image, control: KittyControl
    ) -> UInt32? {
        let columns = control.cellCols == 0 ? 1 : control.cellCols
        let rows = control.cellRows == 0 ? 1 : control.cellRows
        guard columns > 0, rows > 0,
              columns <= Self.maxInlineImageCellSpan,
              rows <= Self.maxInlineImageCellSpan else {
            return nil
        }

        let buf = buffer
        let placementId = control.placementId == 0
            ? kittyGraphics.nextPlacementId : control.placementId
        let placement = KittyGraphicsStore.Placement(
            imageId: image.id,
            placementId: placementId,
            col: buf.x,
            row: buf.yBase + buf.y,
            cols: columns,
            rows: rows,
            zIndex: control.zIndex,
            pixelOffsetX: control.offsetX,
            pixelOffsetY: control.offsetY,
            isVirtual: control.virtualPlacement,
            isAlternateBuffer: isAlternateBuffer)
        guard kittyGraphics.place(placement) else { return nil }

        if !control.virtualPlacement {
            let line = buf.liveLine(buf.y)
            let lineImage = LineImage(
                payload: image.payload,
                pixelWidth: image.pixelWidth,
                pixelHeight: image.pixelHeight,
                col: buf.x)
            lineImage.kittyIsKitty = true
            lineImage.kittyImageId = image.id
            lineImage.kittyPlacementId = placementId
            lineImage.kittyZIndex = control.zIndex
            lineImage.kittyPixelOffsetX = control.offsetX
            lineImage.kittyPixelOffsetY = control.offsetY
            var images = line.images ?? []
            images.removeAll {
                $0.kittyIsKitty && $0.kittyImageId == image.id
                    && $0.kittyPlacementId == placementId
            }
            images.append(lineImage)
            line.images = images
            markDirty(absoluteRow: buf.yBase + buf.y)
        }

        if !control.virtualPlacement && !control.noCursorMove {
            // Cmdy's frozen placement behavior moves below the rectangle and
            // resets to column zero. C=1 suppresses this transition entirely.
            buf.x = 0
            buf.y = min(buf.rows - 1, max(0, buf.y + rows))
        }
        return placementId
    }

    private func handleKittyDelete(
        _ control: KittyControl
    ) -> [KittyGraphicsStore.Placement] {
        let selector = control.deleteWhat
        let deleteData = selector.isUppercase
        let normalized = Character(selector.lowercased())
        let targetImageId: UInt32? = control.imageId != 0
            ? control.imageId
            : (control.imageNumber != 0
                ? kittyGraphics.newestImage(number: control.imageNumber)?.id : nil)

        let removed: [KittyGraphicsStore.Placement]
        switch normalized {
        case "i", "n":
            guard let targetImageId else { return [] }
            if control.placementId != 0 {
                removed = kittyGraphics.removePlacements {
                    $0.imageId == targetImageId
                        && $0.placementId == control.placementId
                }
            } else {
                removed = kittyGraphics.removePlacements {
                    $0.imageId == targetImageId
                }
            }
        case "z":
            removed = kittyGraphics.removePlacements { $0.zIndex == control.zIndex }
        case "x":
            removed = kittyGraphics.removePlacements {
                control.sourceX >= $0.col
                    && control.sourceX < $0.col + $0.cols
            }
        case "y":
            let row = buffer.yBase + control.sourceY
            removed = kittyGraphics.removePlacements {
                row >= $0.row && row < $0.row + $0.rows
            }
        case "p", "q":
            let column = control.sourceX
            let row = buffer.yBase + control.sourceY
            removed = kittyGraphics.removePlacements {
                column >= $0.col && column < $0.col + $0.cols
                    && row >= $0.row && row < $0.row + $0.rows
                    && (normalized != "q" || $0.zIndex == control.zIndex)
            }
        case "c":
            let row = buffer.yBase + buffer.y
            removed = kittyGraphics.removePlacements {
                !$0.isVirtual
                    && buffer.x >= $0.col && buffer.x < $0.col + $0.cols
                    && row >= $0.row && row < $0.row + $0.rows
            }
        default:
            removed = kittyGraphics.removePlacements { !$0.isVirtual }
        }

        let removedKeys = Set(removed.map { "\($0.imageId):\($0.placementId)" })
        stripLineImages { image in
            guard image.kittyIsKitty,
                  let imageId = image.kittyImageId,
                  let placementId = image.kittyPlacementId else {
                return false
            }
            return removedKeys.contains("\(imageId):\(placementId)")
        }

        guard deleteData else { return removed }
        let candidates = Set(removed.map(\.imageId))
        for imageId in candidates where !kittyGraphics.hasPlacement(imageId: imageId) {
            kittyGraphics.deleteImage(id: imageId)
        }
        return removed
    }

    private func stripLineImages(_ predicate: (LineImage) -> Bool) {
        for screen in [normalBuffer, altBuffer] {
            for line in screen.lines {
                guard let images = line.images else { continue }
                let retained = images.filter { !predicate($0) }
                if retained.count != images.count {
                    line.images = retained.isEmpty ? nil : retained
                }
            }
        }
        markAllDirty()
    }

    private func kittyReply(_ control: KittyControl, imageId: UInt32? = nil,
                            error: KittyProtocolError?) {
        if error == nil, control.quiet >= 1 { return }
        if error != nil, control.quiet >= 2 { return }

        var identifiers: [String] = []
        let resolvedImageId = imageId ?? control.imageId
        if resolvedImageId != 0 { identifiers.append("i=\(resolvedImageId)") }
        if control.imageNumber != 0 { identifiers.append("I=\(control.imageNumber)") }
        if control.placementId != 0 { identifiers.append("p=\(control.placementId)") }
        let prefix = identifiers.isEmpty ? "" : identifiers.joined(separator: ",")
        let status = error?.rawValue ?? "OK"
        sendResponse("\u{1b}_G\(prefix);\(status)\u{1b}\\")
    }

    func resetGraphics() {
        kittyGraphics.deleteAll()
        stripLineImages { _ in true }
        sixelDecoder = nil
        dcsKind = .none
        decrqssBuffer.removeAll(keepingCapacity: false)
        kittyChunkControl = nil
        kittyChunkData.removeAll(keepingCapacity: false)
        inlineImagePayloadBytes = 0
    }

    // MARK: - DCS routing (sixel + DECRQSS)

    func dcsHook(final: UInt8, params: [Int], collect: [UInt8]) {
        if final == UInt8(ascii: "q") && collect.isEmpty {
            dcsKind = .sixel
            sixelDecoder = SixelDecoder()
        } else if final == UInt8(ascii: "q") && collect == [UInt8(ascii: "$")] {
            dcsKind = .decrqss
            decrqssBuffer.removeAll()
        } else {
            dcsKind = .other
        }
    }

    func dcsPut(_ bytes: ArraySlice<UInt8>) {
        switch dcsKind {
        case .sixel: sixelDecoder?.feed(bytes)
        case .decrqss:
            guard bytes.count <= 4_096 - decrqssBuffer.count else {
                decrqssBuffer.removeAll(keepingCapacity: false)
                dcsKind = .other
                return
            }
            decrqssBuffer.append(contentsOf: bytes)
        default: break
        }
    }

    func dcsUnhook() {
        defer { dcsKind = .none; sixelDecoder = nil }
        switch dcsKind {
        case .sixel:
            guard let decoder = sixelDecoder, let (rgba, w, h) = decoder.finish() else { return }
            attachImage(payload: .rgba(bytes: rgba, width: w, height: h), width: w, height: h)
        case .decrqss:
            handleDECRQSS(String(decoding: decrqssBuffer, as: UTF8.self))
        default:
            break
        }
    }

    private func handleDECRQSS(_ request: String) {
        switch request {
        case "m":
            sendResponse("\u{1b}P1$r0m\u{1b}\\")
        case "r":
            sendResponse("\u{1b}P1$r\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r\u{1b}\\")
        case " q":
            let n: Int
            switch cursorStyle {
            case .blinkBlock: n = 1
            case .steadyBlock: n = 2
            case .blinkUnderline: n = 3
            case .steadyUnderline: n = 4
            case .blinkBar: n = 5
            case .steadyBar: n = 6
            }
            sendResponse("\u{1b}P1$r\(n) q\u{1b}\\")
        default:
            sendResponse("\u{1b}P0$r\u{1b}\\")
        }
    }

    // MARK: - iTerm2 OSC 1337

    func handleITerm2(_ payload: ArraySlice<UInt8>) {
        let text = String(decoding: payload, as: UTF8.self)
        guard text.hasPrefix("File=") else { return }
        guard let colon = text.firstIndex(of: ":") else { return }
        let args = text[text.index(text.startIndex, offsetBy: 5)..<colon]
        var inline = false
        for pair in args.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "inline", kv[1] == "1" { inline = true }
        }
        guard inline else { return }
        let b64 = String(text[text.index(after: colon)...])
        guard let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]) else { return }
        guard data.count <= Self.maxInlineImageEncodedBytes,
              let (w, h) = CmdyTerminal.pngDimensions(data),
              Self.validatedPixelCount(width: w, height: h) != nil else { return }
        attachImage(payload: .png(data), width: w, height: h)
    }

    /// Shared sixel/iTerm2 attachment: image lands at the cursor and the
    /// cursor advances past it.
    func attachImage(payload: LineImage.Payload, width: Int, height: Int) {
        guard Self.validatedPixelCount(width: width, height: height) != nil else { return }
        let payloadBytes: Int
        switch payload {
        case .png(let data):
            guard data.count <= Self.maxInlineImageEncodedBytes,
                  let dimensions = Self.pngDimensions(data),
                  dimensions.0 == width, dimensions.1 == height else { return }
            payloadBytes = data.count
        case .rgba(let bytes, let payloadWidth, let payloadHeight):
            guard payloadWidth == width, payloadHeight == height,
                  let pixelCount = Self.validatedPixelCount(
                    width: payloadWidth, height: payloadHeight) else { return }
            let (expectedBytes, byteOverflow) = pixelCount.multipliedReportingOverflow(
                by: 4)
            guard !byteOverflow, bytes.count == expectedBytes else { return }
            payloadBytes = bytes.count
        }
        let (newTotal, overflow) = inlineImagePayloadBytes.addingReportingOverflow(
            payloadBytes)
        guard !overflow, newTotal <= Self.maxInlineImagePayloadBytes else { return }
        inlineImagePayloadBytes = newTotal
        let buf = buffer
        let cellH = 20
        let rows = max(1, (height + cellH - 1) / cellH)
        let image = LineImage(payload: payload, pixelWidth: width, pixelHeight: height,
                              col: buf.x)
        for _ in 0..<max(0, rows - 1) { lineFeed() }
        let anchor = buf.liveLine(buf.y)
        anchor.images = (anchor.images ?? []) + [image]
        lineFeed()
        buf.x = 0
    }
}

// zlib inflate via the raw zlib stream header (RFC 1950) — Foundation's
// Compression wrapper, no AppKit anywhere near this.
import Compression

extension Data {
    func zlibInflated(maxOutputSize: Int) -> Data? {
        // Strip the 2-byte zlib header + 4-byte adler tail; COMPRESSION_ZLIB
        // in Compression is raw deflate.
        guard count > 6, maxOutputSize > 0 else { return nil }
        let deflate = subdata(in: 2..<(count - 4))
        var capacity = Swift.min(maxOutputSize, Swift.max(count * 8, 1 << 16))
        while capacity > 0, capacity <= maxOutputSize {
            var dst = Data(count: capacity)
            let written = dst.withUnsafeMutableBytes { dstPtr in
                deflate.withUnsafeBytes { srcPtr in
                    compression_decode_buffer(
                        dstPtr.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        srcPtr.bindMemory(to: UInt8.self).baseAddress!, deflate.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            // `compression_decode_buffer` returns the destination capacity
            // when output was truncated, so only a short write proves the
            // complete stream fit.
            if written > 0, written < capacity {
                dst.removeSubrange(written..<dst.count)
                return dst
            }
            if capacity == maxOutputSize { return nil }
            capacity = Swift.min(maxOutputSize, capacity * 2)
        }
        return nil
    }
}
