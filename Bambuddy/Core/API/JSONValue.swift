import Foundation

/// A type-erased JSON value used for loosely typed API payloads
/// (settings blobs, WebSocket deltas, `dict[str, Any]` responses).
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            // Decoding as a Dictionary (not a keyed container) keeps the raw keys
            // even when the decoder uses `.convertFromSnakeCase`.
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let v):
            var c = encoder.singleValueContainer(); try c.encode(v)
        case .number(let v):
            var c = encoder.singleValueContainer()
            if v.rounded() == v, abs(v) < 9_007_199_254_740_992 { try c.encode(Int64(v)) } else { try c.encode(v) }
        case .string(let v):
            var c = encoder.singleValueContainer(); try c.encode(v)
        case .array(let v):
            var c = encoder.singleValueContainer(); try c.encode(v)
        case .object(let v):
            var c = encoder.singleValueContainer(); try c.encode(v)
        }
    }

    struct RawKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { stringValue = String(intValue) }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    var intValue: Int? { doubleValue.map { Int($0) } }
    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return ["true", "1", "yes", "on"].contains(s.lowercased())
        default: return nil
        }
    }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    /// Shallow merge (mirrors how the web UI applies WebSocket status deltas).
    func merging(_ other: JSONValue) -> JSONValue {
        guard case .object(var base) = self, case .object(let delta) = other else { return other }
        for (k, v) in delta { base[k] = v }
        return .object(base)
    }

    /// Re-decodes this value into a concrete model using the API's decoder.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try APICoders.decoder.decode(T.self, from: data)
    }

    /// Builds a JSONValue from any Encodable using the API's encoder (snake_case keys).
    static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try APICoders.encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Human readable representation for generic displays.
    var displayString: String {
        switch self {
        case .null: return "—"
        case .bool(let b): return b ? "Yes" : "No"
        case .number, .string: return stringValue ?? ""
        case .array(let a): return a.map(\.displayString).joined(separator: ", ")
        case .object(let o): return o.keys.sorted().map { "\($0): \(o[$0]!.displayString)" }.joined(separator: ", ")
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(nilLiteral: ()) { self = .null }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
}
