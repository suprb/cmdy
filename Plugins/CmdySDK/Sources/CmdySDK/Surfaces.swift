import Foundation

public enum CmdyHookBoundary: String, Codable, Sendable {
    case command = "command.submit"
    case paste
    case paneSplit = "pane.split"
    case paneClose = "pane.close"
    case notification
}

public enum CmdyDecision: String, Codable, Sendable {
    case `continue`, replace, cancel
}

public enum CmdySurfaceKind: String, Codable, Sendable {
    case list, table, diff, task, form, text
}

public enum CmdySurfaceState: String, Codable, Sendable {
    case live, waiting, complete, failed, disconnected
}

public enum CmdySurfaceEffect: String, Codable, Sendable {
    case localView = "local-view"
    case read, mutate, approve
}

public enum CmdySurfaceValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else { self = .string(try value.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let text): try value.encode(text)
        case .number(let number): try value.encode(number)
        case .bool(let flag): try value.encode(flag)
        case .null: try value.encodeNil()
        }
    }
}

public struct CmdySurfaceAction: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Sendable { case normal, primary, destructive }

    public var id: String
    public var title: String
    public var effect: CmdySurfaceEffect
    public var style: Style
    public var disabled: Bool
    public var confirmation: String?

    public init(id: String, title: String, effect: CmdySurfaceEffect = .read,
                style: Style = .normal, disabled: Bool = false,
                confirmation: String? = nil) {
        self.id = id
        self.title = title
        self.effect = effect
        self.style = style
        self.disabled = disabled
        self.confirmation = confirmation
    }
}

public struct CmdySurfaceColumn: Codable, Equatable, Sendable {
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
}

public struct CmdySurfaceRow: Codable, Equatable, Sendable {
    public var id: String
    public var cells: [String: CmdySurfaceValue]
    public var state: String?
    public var detail: String?
    public var actions: [CmdySurfaceAction]

    public init(id: String, cells: [String: CmdySurfaceValue],
                state: String? = nil, detail: String? = nil,
                actions: [CmdySurfaceAction] = []) {
        self.id = id
        self.cells = cells
        self.state = state
        self.detail = detail
        self.actions = actions
    }
}

public struct CmdySurfaceTask: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, running, passed, failed, skipped, cancelled
    }
    public var id: String
    public var label: String
    public var status: Status
    public var detail: String?
    public var progress: Double?
    public var durationMs: Int?
    public var actions: [CmdySurfaceAction]

    public init(id: String, label: String, status: Status,
                detail: String? = nil, progress: Double? = nil,
                durationMs: Int? = nil, actions: [CmdySurfaceAction] = []) {
        self.id = id
        self.label = label
        self.status = status
        self.detail = detail
        self.progress = progress
        self.durationMs = durationMs
        self.actions = actions
    }
}

public struct CmdySurfaceField: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, secure, toggle, choice }
    public var id: String
    public var label: String
    public var kind: Kind
    public var value: CmdySurfaceValue
    public var placeholder: String?
    public var options: [String]
    public var required: Bool
    public var disabled: Bool

    public init(id: String, label: String, kind: Kind = .text,
                value: CmdySurfaceValue = .string(""),
                placeholder: String? = nil, options: [String] = [],
                required: Bool = false, disabled: Bool = false) {
        self.id = id
        self.label = label
        self.kind = kind
        self.value = value
        self.placeholder = placeholder
        self.options = options
        self.required = required
        self.disabled = disabled
    }
}

public struct CmdySurfaceDocument: Codable, Equatable, Sendable {
    public var protocolVersion = 1
    public var id: String
    public var kind: CmdySurfaceKind
    public var title: String
    public var pane: String?
    public var block: String
    public var sequence: Int
    public var state: CmdySurfaceState
    public var summary: String?
    public var fallback: String
    public var columns: [CmdySurfaceColumn]
    public var rows: [CmdySurfaceRow]
    public var tasks: [CmdySurfaceTask]
    public var diff: String?
    public var fields: [CmdySurfaceField]
    public var actions: [CmdySurfaceAction]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "v"
        case id, kind, title, pane, block, sequence, state, summary, fallback
        case columns, rows, tasks, diff, fields, actions
    }

    public init(id: String, kind: CmdySurfaceKind, title: String,
                pane: String? = nil, block: String = "current", sequence: Int = 0,
                state: CmdySurfaceState = .live, summary: String? = nil,
                fallback: String, columns: [CmdySurfaceColumn] = [],
                rows: [CmdySurfaceRow] = [], tasks: [CmdySurfaceTask] = [],
                diff: String? = nil, fields: [CmdySurfaceField] = [],
                actions: [CmdySurfaceAction] = []) {
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
    }
}

public struct CmdySurfacePatch: Codable, Equatable, Sendable {
    public var sequence: Int
    public var title: String?
    public var state: CmdySurfaceState?
    public var summary: String?
    public var fallback: String?
    public var columns: [CmdySurfaceColumn]?
    public var rows: [CmdySurfaceRow]?
    public var upsertRows: [CmdySurfaceRow]
    public var removeRows: [String]
    public var tasks: [CmdySurfaceTask]?
    public var upsertTasks: [CmdySurfaceTask]
    public var removeTasks: [String]
    public var diff: String?
    public var fields: [CmdySurfaceField]?
    public var actions: [CmdySurfaceAction]?

    public init(sequence: Int, title: String? = nil,
                state: CmdySurfaceState? = nil, summary: String? = nil,
                fallback: String? = nil, columns: [CmdySurfaceColumn]? = nil,
                rows: [CmdySurfaceRow]? = nil,
                upsertRows: [CmdySurfaceRow] = [], removeRows: [String] = [],
                tasks: [CmdySurfaceTask]? = nil,
                upsertTasks: [CmdySurfaceTask] = [], removeTasks: [String] = [],
                diff: String? = nil, fields: [CmdySurfaceField]? = nil,
                actions: [CmdySurfaceAction]? = nil) {
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
}
