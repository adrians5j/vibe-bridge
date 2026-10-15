import Foundation

/// Client side of the bridge: publish events, subscribe to them.
///
/// Publishing writes a folder into the bridge's inbox, so it works while the bridge
/// is down and the event is picked up when it starts. Subscribing long-polls the
/// bridge over loopback HTTP and acks each event after the handler returns.
public enum VibeBridge {
    /// `~/Library/Application Support/VibeBridge`, or `VB_DATA_DIR`.
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["VB_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VibeBridge", isDirectory: true)
    }

    public static var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }

    /// 47400, or `VB_PORT`.
    public static var port: UInt16 {
        ProcessInfo.processInfo.environment["VB_PORT"].flatMap(UInt16.init) ?? 47400
    }

    public static var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    // MARK: - publish

    public struct File: Sendable {
        public var name: String
        public var mime: String
        public var data: Data

        public init(name: String, mime: String, data: Data) {
            self.name = name
            self.mime = mime
            self.data = data
        }
    }

    /// Drops the event into the inbox. `id` doubles as a dedupe key: the bridge ignores an id it already has.
    public static func publish<T: Encodable>(type: String, source: String, id: String? = nil,
                                             data: T, files: [File] = []) throws {
        var event = BridgeEvent(id: id ?? UUID().uuidString, type: type, source: source, data: try .from(data))
        let fm = FileManager.default
        let folder = UUID().uuidString
        let tmp = inbox.appendingPathComponent(".tmp-\(folder)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            var used = Set<String>()
            for file in files {
                let name = uniqueName(safeName(file.name), in: &used)
                try file.data.write(to: tmp.appendingPathComponent(name))
                // Relative to the folder until the bridge moves it into place.
                event.attachments.append(BridgeAttachment(name: file.name, mime: file.mime, size: file.data.count, path: name))
            }
            try BridgeJSON.encoder.encode(event).write(to: tmp.appendingPathComponent("event.json"))
            // The rename is what makes it visible, so the bridge never sees half a folder.
            try fm.moveItem(at: tmp, to: inbox.appendingPathComponent(folder, isDirectory: true))
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.map { "/:\\\0".contains($0) ? "_" : $0 }
        let s = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || s.hasPrefix(".") || s == "event.json" ? "file-\(s)" : s
    }

    static func uniqueName(_ name: String, in used: inout Set<String>) -> String {
        var candidate = name
        var n = 2
        while used.contains(candidate.lowercased()) {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            n += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    // MARK: - subscribe

    /// Delivers matching events to `handler` one at a time, in order, until the task is cancelled.
    ///
    /// `consumer` names the cursor on the bridge. A new consumer starts at the current
    /// end of the log, so it doesn't replay history. Types match exactly, or by prefix with `.*`.
    /// Delivery is at-least-once: an event whose handler was running when the app quit
    /// arrives again on the next launch, so handlers should tolerate repeats.
    @discardableResult
    public static func subscribe(consumer: String, types: [String],
                                 handler: @escaping @Sendable (BridgeEvent) async -> Void) -> Task<Void, Never> {
        Task.detached {
            var backoff: UInt64 = 2
            while !Task.isCancelled {
                do {
                    let events = try await poll(consumer: consumer, types: types, wait: 25)
                    backoff = 2
                    for event in events {
                        if Task.isCancelled { return }
                        await handler(event)
                        if let seq = event.seq { try await ack(consumer: consumer, seq: seq) }
                    }
                } catch {
                    if Task.isCancelled { return }
                    // Bridge not running yet, or restarting. Keep trying, quietly.
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                    backoff = min(backoff * 2, 60)
                }
            }
        }
    }

    private struct PollResponse: Decodable { var events: [BridgeEvent] }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 40
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    static func poll(consumer: String, types: [String], wait: Int) async throws -> [BridgeEvent] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("poll"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "consumer", value: consumer),
            URLQueryItem(name: "types", value: types.joined(separator: ",")),
            URLQueryItem(name: "wait", value: String(wait)),
        ]
        let (data, resp) = try await session.data(from: comps.url!)
        try check(resp, data)
        return try BridgeJSON.decoder.decode(PollResponse.self, from: data).events
    }

    static func ack(consumer: String, seq: Int64) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("ack"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["consumer": consumer, "seq": seq])
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw BridgeError("bridge \(status): \(String(decoding: data, as: UTF8.self))")
        }
    }
}

public struct BridgeError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
