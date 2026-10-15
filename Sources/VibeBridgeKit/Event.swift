import Foundation

/// One event on the bridge. `seq` is assigned when the bridge stores it; publishers leave it nil.
public struct BridgeEvent: Codable, Sendable, Identifiable, Equatable {
    public var seq: Int64?
    /// Publisher-chosen and unique. Publishing the same id twice stores it once,
    /// so a publisher can use a natural key (e.g. a Gmail message id) and not worry about repeats.
    public var id: String
    /// Dotted name, e.g. `email.received`. Consumers subscribe by exact type or `email.*`.
    public var type: String
    /// Which app published it, e.g. `gmail-bar`.
    public var source: String
    public var time: Date
    public var data: JSONValue
    public var attachments: [BridgeAttachment]

    public init(id: String = UUID().uuidString, type: String, source: String, time: Date = Date(),
                data: JSONValue = .object([:]), attachments: [BridgeAttachment] = []) {
        self.id = id
        self.type = type
        self.source = source
        self.time = time
        self.data = data
        self.attachments = attachments
    }

    /// Decodes `data` into one of the shared payload types, e.g. `EmailReceived`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try BridgeJSON.decoder.decode(T.self, from: BridgeJSON.encoder.encode(data))
    }
}

/// A file that came with an event. `path` is absolute and readable by any local app
/// once the bridge has stored the event.
public struct BridgeAttachment: Codable, Sendable, Equatable {
    public var name: String
    public var mime: String
    public var size: Int
    public var path: String

    public init(name: String, mime: String, size: Int, path: String) {
        self.name = name
        self.mime = mime
        self.size = size
        self.path = path
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

/// Free-form JSON, so `data` can carry any payload without the bridge knowing its shape.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Any Encodable value, as JSON.
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try BridgeJSON.decoder.decode(JSONValue.self, from: BridgeJSON.encoder.encode(value))
    }
}

/// ISO 8601 dates everywhere, so curl users and Rust/JS publishers see the same format.
public enum BridgeJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
