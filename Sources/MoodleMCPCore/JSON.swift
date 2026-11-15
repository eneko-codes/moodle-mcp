import Foundation

/// A parsed Moodle answer. Moodle is loose about types — a flag can arrive as `1`, `true`
/// or `"1"`, an id as a number or a string — so readers go through these lenient
/// accessors rather than strict `Decodable` models.
public enum JSON: Sendable, Equatable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(_ value: Any) {
        switch value {
        case let object as [String: Any]: self = .object(object.mapValues(JSON.init))
        case let array as [Any]: self = .array(array.map(JSON.init))
        case let string as String: self = .string(string)
        case let number as NSNumber:
            // JSONSerialization gives booleans as NSNumber too; tell them apart by type.
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        default: self = .null
        }
    }

    static func parse(_ data: Data) throws(MoodleError) -> JSON {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw .unexpectedResponse("the body is not JSON.")
        }
        return JSON(value)
    }

    public subscript(key: String) -> JSON {
        if case .object(let object) = self { return object[key] ?? .null }
        return .null
    }

    public var array: [JSON] {
        if case .array(let array) = self { return array }
        return []
    }

    public var int: Int? {
        switch self {
        case .number(let number): return number.isFinite ? Int(exactly: number.rounded()) : nil
        case .string(let string): return Int(string)
        case .bool(let bool): return bool ? 1 : 0
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .number(let number): return number
        case .string(let string): return Double(string)
        default: return nil
        }
    }

    public var string: String? {
        switch self {
        case .string(let string): return string
        case .number(let number): return number.rounded() == number ? String(Int(number)) : String(number)
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let bool): return bool
        case .number(let number): return number != 0
        case .string(let string): return ["1", "true"].contains(string.lowercased()) ? true : (["0", "false", ""].contains(string.lowercased()) ? false : nil)
        default: return nil
        }
    }

    public var isNull: Bool { self == .null }
}

/// The shape of every answer, built field by field: nothing Moodle sends reaches an
/// answer unless a tool names it. Keys are sorted on output.
public indirect enum Out: Encodable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case object([String: Out])
    case array([Out])

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        }
    }

    // MARK: Builders from JSON

    static func str(_ json: JSON) -> Out { json.string.map { .string($0) } ?? .null }
    static func int(_ json: JSON) -> Out { json.int.map { .int($0) } ?? .null }
    static func bool(_ json: JSON) -> Out { json.bool.map { .bool($0) } ?? .null }
    static func number(_ json: JSON) -> Out {
        guard let value = json.double else { return .null }
        return value.rounded() == value && abs(value) < 1e15 ? .int(Int(value)) : .double(value)
    }

    /// `{"iso": …, "fecha_local": …}` or `null` for 0 / missing.
    static func date(_ json: JSON) -> Out { date(json.int) }

    static func date(_ unixSeconds: Int?) -> Out {
        guard let date = MoodleDate(unixSeconds: unixSeconds) else { return .null }
        return .object(["iso": .string(date.iso), "fecha_local": .string(date.fechaLocal)])
    }

    /// A file or page URL, with any token parameter removed.
    static func url(_ json: JSON) -> Out {
        guard let url = json.string, !url.isEmpty else { return .null }
        return .string(Redaction.stripToken(from: url))
    }

    /// Writes `<key>` as plain text and `<key>_html` as the original markup.
    static func html(_ json: JSON, into object: inout [String: Out], key: String) {
        guard let html = json.string, !html.isEmpty else {
            object[key] = .null
            object["\(key)_html"] = .null
            return
        }
        object[key] = .string(HTMLText.plain(html))
        object["\(key)_html"] = .string(Redaction.scrub(html))
    }
}
