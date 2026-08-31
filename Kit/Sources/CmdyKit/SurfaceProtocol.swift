import Foundation

public enum SurfaceKind: String, Codable, CaseIterable, Sendable {
    case list
    case table
    case diff
    case task
    case form
    case text
}

public enum SurfaceState: String, Codable, Sendable {
    case live
    case waiting
    case complete
    case failed
    case disconnected
}

public enum SurfaceActionEffect: String, Codable, Sendable {
    case localView = "local-view"
    case read
    case mutate
    case approve
}

public enum SurfaceActionStyle: String, Codable, Sendable {
    case normal
    case primary
    case destructive
}

/// JSON scalar accepted in a table cell or form value. Deliberately excludes
/// nested objects and executable content: v1 surfaces describe bounded native
/// controls, not an arbitrary application runtime.
public enum SurfaceValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else {
            throw DecodingError.typeMismatch(
                SurfaceValue.self,
                .init(codingPath: decoder.codingPath,
                      debugDescription: "surface values must be strings, numbers, booleans, or null"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var description: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value.rounded() == value,
               value >= Double(Int64.min), value <= Double(Int64.max) {
                return String(Int64(value))
            }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return ""
        }
    }
}

public struct SurfaceAction: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var effect: SurfaceActionEffect
    public var style: SurfaceActionStyle
    public var disabled: Bool
    public var confirmation: String?

    public init(id: String, title: String,
                effect: SurfaceActionEffect = .read,
                style: SurfaceActionStyle = .normal,
                disabled: Bool = false,
                confirmation: String? = nil) {
        self.id = id
        self.title = title
        self.effect = effect
        self.style = style
        self.disabled = disabled
        self.confirmation = confirmation
    }

    enum CodingKeys: String, CodingKey { case id, title, effect, style, disabled, confirmation }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        effect = try values.decodeIfPresent(SurfaceActionEffect.self, forKey: .effect) ?? .read
        style = try values.decodeIfPresent(SurfaceActionStyle.self, forKey: .style) ?? .normal
        disabled = try values.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        confirmation = try values.decodeIfPresent(String.self, forKey: .confirmation)
    }
}

public struct SurfaceColumn: Codable, Equatable, Sendable {
    public enum Alignment: String, Codable, Sendable { case leading, center, trailing }

    public var id: String
    public var title: String
    public var alignment: Alignment
    public var width: Double?

    public init(id: String, title: String, alignment: Alignment = .leading,
                width: Double? = nil) {
        self.id = id
        self.title = title
        self.alignment = alignment
        self.width = width
    }

    enum CodingKeys: String, CodingKey { case id, title, alignment, width }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        alignment = try values.decodeIfPresent(Alignment.self, forKey: .alignment) ?? .leading
        width = try values.decodeIfPresent(Double.self, forKey: .width)
    }
}

public struct SurfaceRow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var cells: [String: SurfaceValue]
    public var state: String?
    public var detail: String?
    public var actions: [SurfaceAction]

    public init(id: String, cells: [String: SurfaceValue], state: String? = nil,
                detail: String? = nil, actions: [SurfaceAction] = []) {
        self.id = id
        self.cells = cells
        self.state = state
        self.detail = detail
        self.actions = actions
    }

    enum CodingKeys: String, CodingKey { case id, cells, state, detail, actions }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        cells = try values.decode([String: SurfaceValue].self, forKey: .cells)
        state = try values.decodeIfPresent(String.self, forKey: .state)
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
        actions = try values.decodeIfPresent([SurfaceAction].self, forKey: .actions) ?? []
    }
}

public struct SurfaceTask: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending
        case running
        case passed
        case failed
        case skipped
        case cancelled
    }

    public var id: String
    public var label: String
    public var status: Status
    public var detail: String?
    public var progress: Double?
    public var durationMs: Int?
    public var actions: [SurfaceAction]

    public init(id: String, label: String, status: Status,
                detail: String? = nil, progress: Double? = nil,
                durationMs: Int? = nil, actions: [SurfaceAction] = []) {
        self.id = id
        self.label = label
        self.status = status
        self.detail = detail
        self.progress = progress
        self.durationMs = durationMs
        self.actions = actions
    }

    enum CodingKeys: String, CodingKey {
        case id, label, status, detail, progress, durationMs, actions
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        status = try values.decode(Status.self, forKey: .status)
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
        progress = try values.decodeIfPresent(Double.self, forKey: .progress)
        durationMs = try values.decodeIfPresent(Int.self, forKey: .durationMs)
        actions = try values.decodeIfPresent([SurfaceAction].self, forKey: .actions) ?? []
    }
}

public struct SurfaceField: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case text
        case secure
        case toggle
        case choice
    }

    public var id: String
    public var label: String
    public var kind: Kind
    public var value: SurfaceValue
    public var placeholder: String?
    public var options: [String]
    public var required: Bool
    public var disabled: Bool

    public init(id: String, label: String, kind: Kind = .text,
                value: SurfaceValue = .string(""), placeholder: String? = nil,
                options: [String] = [], required: Bool = false,
                disabled: Bool = false) {
        self.id = id
        self.label = label
        self.kind = kind
        self.value = value
        self.placeholder = placeholder
        self.options = options
        self.required = required
        self.disabled = disabled
    }

    enum CodingKeys: String, CodingKey {
        case id, label, kind, value, placeholder, options, required, disabled
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        value = try values.decodeIfPresent(SurfaceValue.self, forKey: .value) ?? .string("")
        placeholder = try values.decodeIfPresent(String.self, forKey: .placeholder)
        options = try values.decodeIfPresent([String].self, forKey: .options) ?? []
        required = try values.decodeIfPresent(Bool.self, forKey: .required) ?? false
        disabled = try values.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }
}

public enum SurfaceProtocolError: LocalizedError, Equatable {
    case invalid(String)
    case limit(String)
    case sequence(expected: Int, received: Int)

    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "Invalid surface: \(detail)"
        case .limit(let detail): return "Surface exceeds its resource budget: \(detail)"
        case .sequence(let expected, let received):
            return "Surface update sequence gap (expected \(expected), received \(received))"
        }
    }
}

public struct SurfaceDocument: Codable, Equatable, Sendable, Identifiable {
    public static let protocolVersion = 1
    public static let maxRows = 10_000
    public static let maxTasks = 5_000
    public static let maxColumns = 64
    public static let maxActions = 64
    public static let maxActionsPerItem = 16
    public static let maxFields = 256
    public static let maxOptionsPerField = 256
    public static let maxTextBytes = 2_000_000

    public var protocolVersion: Int
    public var id: String
    public var kind: SurfaceKind
    public var title: String
    public var pane: String?
    public var block: String
    public var sequence: Int
    public var state: SurfaceState
    public var summary: String?
    public var fallback: String
    public var columns: [SurfaceColumn]
    public var rows: [SurfaceRow]
    public var tasks: [SurfaceTask]
    public var diff: String?
    public var fields: [SurfaceField]
    public var actions: [SurfaceAction]

    public init(id: String, kind: SurfaceKind, title: String,
                pane: String? = nil, block: String = "current",
                sequence: Int = 0, state: SurfaceState = .live,
                summary: String? = nil, fallback: String,
                columns: [SurfaceColumn] = [], rows: [SurfaceRow] = [],
                tasks: [SurfaceTask] = [], diff: String? = nil,
                fields: [SurfaceField] = [], actions: [SurfaceAction] = []) throws {
        protocolVersion = Self.protocolVersion
        self.id = id
        self.kind = kind
        self.title = title
        self.pane = pane
        self.block = block
        self.sequence = sequence
        self.state = state
        self.summary = summary
        self.fallback = fallback
        self.columns = columns
        self.rows = rows
        self.tasks = tasks
        self.diff = diff
        self.fields = fields
        self.actions = actions
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "v"
        case id, kind, title, pane, block, sequence, state, summary, fallback
        case columns, rows, tasks, diff, fields, actions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(SurfaceKind.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        pane = try values.decodeIfPresent(String.self, forKey: .pane)
        block = try values.decodeIfPresent(String.self, forKey: .block) ?? "current"
        sequence = try values.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        state = try values.decodeIfPresent(SurfaceState.self, forKey: .state) ?? .live
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        fallback = try values.decode(String.self, forKey: .fallback)
        columns = try values.decodeIfPresent([SurfaceColumn].self, forKey: .columns) ?? []
        rows = try values.decodeIfPresent([SurfaceRow].self, forKey: .rows) ?? []
        tasks = try values.decodeIfPresent([SurfaceTask].self, forKey: .tasks) ?? []
        diff = try values.decodeIfPresent(String.self, forKey: .diff)
        fields = try values.decodeIfPresent([SurfaceField].self, forKey: .fields) ?? []
        actions = try values.decodeIfPresent([SurfaceAction].self, forKey: .actions) ?? []
    }

    public static func decode(_ data: Data) throws -> SurfaceDocument {
        do {
            let document = try JSONDecoder().decode(SurfaceDocument.self, from: data)
            try document.validate()
            return document
        } catch let error as SurfaceProtocolError {
            throw error
        } catch {
            throw SurfaceProtocolError.invalid(error.localizedDescription)
        }
    }

    public func encoded(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return try encoder.encode(self)
    }

    public func validate() throws {
        guard protocolVersion == Self.protocolVersion else {
            throw SurfaceProtocolError.invalid("unsupported protocol version \(protocolVersion)")
        }
        let validID = !id.isEmpty && id.utf8.count <= 128 && id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "."
                || $0 == "-" || $0 == "_")
        }
        guard validID else {
            throw SurfaceProtocolError.invalid(
                "id must contain 1...128 ASCII letters, numbers, dots, dashes, or underscores")
        }
        guard !title.isEmpty, title.utf8.count <= 512 else {
            throw SurfaceProtocolError.invalid("title must contain 1...512 bytes")
        }
        guard !block.isEmpty, block.utf8.count <= 128 else {
            throw SurfaceProtocolError.invalid("block attachment is invalid")
        }
        guard sequence >= 0 else { throw SurfaceProtocolError.invalid("sequence must be non-negative") }
        guard columns.count <= Self.maxColumns else {
            throw SurfaceProtocolError.limit("at most \(Self.maxColumns) columns")
        }
        guard rows.count <= Self.maxRows else {
            throw SurfaceProtocolError.limit("at most \(Self.maxRows) rows")
        }
        guard tasks.count <= Self.maxTasks else {
            throw SurfaceProtocolError.limit("at most \(Self.maxTasks) tasks")
        }
        guard actions.count <= Self.maxActions else {
            throw SurfaceProtocolError.limit("at most \(Self.maxActions) top-level actions")
        }
        guard fields.count <= Self.maxFields else {
            throw SurfaceProtocolError.limit("at most \(Self.maxFields) form fields")
        }
        let textBytes = fallback.utf8.count + (diff?.utf8.count ?? 0)
            + (summary?.utf8.count ?? 0)
        guard textBytes <= Self.maxTextBytes else {
            throw SurfaceProtocolError.limit("text content is larger than 2 MB")
        }
        let columnIDs = Set(columns.map(\.id))
        guard columnIDs.count == columns.count else {
            throw SurfaceProtocolError.invalid("column ids must be unique")
        }
        guard Set(rows.map(\.id)).count == rows.count else {
            throw SurfaceProtocolError.invalid("row ids must be unique")
        }
        guard Set(tasks.map(\.id)).count == tasks.count else {
            throw SurfaceProtocolError.invalid("task ids must be unique")
        }
        guard Set(fields.map(\.id)).count == fields.count else {
            throw SurfaceProtocolError.invalid("field ids must be unique")
        }
        let identified: [(String, String)] = columns.map { ("column", $0.id) }
            + rows.map { ("row", $0.id) }
            + tasks.map { ("task", $0.id) }
            + fields.map { ("field", $0.id) }
        if let invalid = identified.first(where: { !Self.isValidID($0.1) }) {
            throw SurfaceProtocolError.invalid("\(invalid.0) id '\(invalid.1)' is not a stable ASCII id")
        }
        for column in columns {
            if let width = column.width, !width.isFinite || width < 0 {
                throw SurfaceProtocolError.invalid("column '\(column.id)' width must be finite and non-negative")
            }
        }
        for task in tasks {
            if let progress = task.progress, !progress.isFinite || progress < 0 || progress > 1 {
                throw SurfaceProtocolError.invalid("task '\(task.id)' progress must be between 0 and 1")
            }
            if let duration = task.durationMs, duration < 0 {
                throw SurfaceProtocolError.invalid("task '\(task.id)' duration must be non-negative")
            }
        }
        if let field = fields.first(where: { $0.options.count > Self.maxOptionsPerField }) {
            throw SurfaceProtocolError.limit(
                "field '\(field.id)' has more than \(Self.maxOptionsPerField) choices")
        }
        let everyAction = actions + rows.flatMap(\.actions) + tasks.flatMap(\.actions)
        if let item = rows.first(where: { $0.actions.count > Self.maxActionsPerItem }) {
            throw SurfaceProtocolError.limit(
                "row '\(item.id)' has more than \(Self.maxActionsPerItem) actions")
        }
        if let item = tasks.first(where: { $0.actions.count > Self.maxActionsPerItem }) {
            throw SurfaceProtocolError.limit(
                "task '\(item.id)' has more than \(Self.maxActionsPerItem) actions")
        }
        if let invalid = everyAction.first(where: { !Self.isValidID($0.id) }) {
            throw SurfaceProtocolError.invalid(
                "action id '\(invalid.id)' is not a stable ASCII id")
        }
        guard Set(actions.map(\.id)).count == actions.count,
              rows.allSatisfy({ Set($0.actions.map(\.id)).count == $0.actions.count }),
              tasks.allSatisfy({ Set($0.actions.map(\.id)).count == $0.actions.count }) else {
            throw SurfaceProtocolError.invalid("action ids must be unique within their item")
        }
        if let unsafe = everyAction.first(where: {
            ($0.effect == .mutate || $0.effect == .approve)
                && ($0.confirmation?.isEmpty ?? true)
        }) {
            throw SurfaceProtocolError.invalid(
                "mutating action '\(unsafe.id)' requires explicit confirmation text")
        }
        switch kind {
        case .table where columns.isEmpty:
            throw SurfaceProtocolError.invalid("table surfaces require columns")
        case .task where tasks.isEmpty && state == .live:
            break // an empty live task run may receive tasks in the next patch
        case .diff where diff == nil:
            throw SurfaceProtocolError.invalid("diff surfaces require diff text")
        case .form where fields.isEmpty:
            throw SurfaceProtocolError.invalid("form surfaces require fields")
        default: break
        }
    }

    public mutating func apply(_ patch: SurfacePatch) throws {
        let expected = sequence + 1
        guard patch.sequence == expected else {
            throw SurfaceProtocolError.sequence(expected: expected, received: patch.sequence)
        }
        var next = self
        if let title = patch.title { next.title = title }
        if let state = patch.state { next.state = state }
        if let summary = patch.summary { next.summary = summary }
        if let fallback = patch.fallback { next.fallback = fallback }
        if let columns = patch.columns { next.columns = columns }
        if let rows = patch.rows { next.rows = rows }
        Self.merge(&next.rows, upserts: patch.upsertRows, removals: patch.removeRows)
        if let tasks = patch.tasks { next.tasks = tasks }
        Self.merge(&next.tasks, upserts: patch.upsertTasks, removals: patch.removeTasks)
        if let diff = patch.diff { next.diff = diff }
        if let fields = patch.fields { next.fields = fields }
        if let actions = patch.actions { next.actions = actions }
        next.sequence = patch.sequence
        try next.validate()
        self = next
    }

    private static func merge<T: Identifiable & Sendable>(_ values: inout [T],
                                                           upserts: [T], removals: [String])
    where T.ID == String {
        if !removals.isEmpty {
            let removed = Set(removals)
            values.removeAll { removed.contains($0.id) }
        }
        guard !upserts.isEmpty else { return }
        var indices = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($1.id, $0) })
        for value in upserts {
            if let index = indices[value.id] { values[index] = value }
            else {
                indices[value.id] = values.count
                values.append(value)
            }
        }
    }

    private static func isValidID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "."
                || $0 == "-" || $0 == "_")
        }
    }
}

public struct SurfacePatch: Codable, Equatable, Sendable {
    public var sequence: Int
    public var title: String?
    public var state: SurfaceState?
    public var summary: String?
    public var fallback: String?
    public var columns: [SurfaceColumn]?
    public var rows: [SurfaceRow]?
    public var upsertRows: [SurfaceRow]
    public var removeRows: [String]
    public var tasks: [SurfaceTask]?
    public var upsertTasks: [SurfaceTask]
    public var removeTasks: [String]
    public var diff: String?
    public var fields: [SurfaceField]?
    public var actions: [SurfaceAction]?

    public init(sequence: Int, title: String? = nil, state: SurfaceState? = nil,
                summary: String? = nil, fallback: String? = nil,
                columns: [SurfaceColumn]? = nil, rows: [SurfaceRow]? = nil,
                upsertRows: [SurfaceRow] = [], removeRows: [String] = [],
                tasks: [SurfaceTask]? = nil, upsertTasks: [SurfaceTask] = [],
                removeTasks: [String] = [], diff: String? = nil,
                fields: [SurfaceField]? = nil, actions: [SurfaceAction]? = nil) {
        self.sequence = sequence
        self.title = title
        self.state = state
        self.summary = summary
        self.fallback = fallback
        self.columns = columns
        self.rows = rows
        self.upsertRows = upsertRows
        self.removeRows = removeRows
        self.tasks = tasks
        self.upsertTasks = upsertTasks
        self.removeTasks = removeTasks
        self.diff = diff
        self.fields = fields
        self.actions = actions
    }

    enum CodingKeys: String, CodingKey {
        case sequence, title, state, summary, fallback, columns, rows
        case upsertRows, removeRows, tasks, upsertTasks, removeTasks, diff, fields, actions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try values.decode(Int.self, forKey: .sequence)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        state = try values.decodeIfPresent(SurfaceState.self, forKey: .state)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        fallback = try values.decodeIfPresent(String.self, forKey: .fallback)
        columns = try values.decodeIfPresent([SurfaceColumn].self, forKey: .columns)
        rows = try values.decodeIfPresent([SurfaceRow].self, forKey: .rows)
        upsertRows = try values.decodeIfPresent([SurfaceRow].self, forKey: .upsertRows) ?? []
        removeRows = try values.decodeIfPresent([String].self, forKey: .removeRows) ?? []
        tasks = try values.decodeIfPresent([SurfaceTask].self, forKey: .tasks)
        upsertTasks = try values.decodeIfPresent([SurfaceTask].self, forKey: .upsertTasks) ?? []
        removeTasks = try values.decodeIfPresent([String].self, forKey: .removeTasks) ?? []
        diff = try values.decodeIfPresent(String.self, forKey: .diff)
        fields = try values.decodeIfPresent([SurfaceField].self, forKey: .fields)
        actions = try values.decodeIfPresent([SurfaceAction].self, forKey: .actions)
    }
}
