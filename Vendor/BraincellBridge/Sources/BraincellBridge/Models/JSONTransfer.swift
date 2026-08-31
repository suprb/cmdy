/// JSONSerialization values are immutable Foundation scalars, arrays, and
/// dictionaries by convention, but `[String: Any]` cannot express that to
/// Swift's type system. These wrappers are used only for completed JSON values
/// crossing a task boundary; callers unwrap them back on their owning actor.
struct JSONDictionaryTransfer: @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) { self.value = value }
}

struct JSONRowsTransfer: @unchecked Sendable {
    let value: [[String: Any]]

    init(_ value: [[String: Any]]) { self.value = value }
}
