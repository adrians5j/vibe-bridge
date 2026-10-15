import Foundation
import Network

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse: Sendable {
    var status: Int
    var body: Data
    var contentType = "application/json"

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }
}

/// A minimal HTTP/1.1 server on 127.0.0.1. One request per connection, then close.
/// Enough for the bridge's handful of JSON endpoints and long-polls; nothing more.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    var onFailure: (@Sendable (String) -> Void)?

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "vibe-bridge.http")
    private static let maxBody = 64 * 1024 * 1024

    init(port: UInt16, handler: @escaping Handler) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        self.handler = handler
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onFailure?("Can't listen on 127.0.0.1:\(port): \(error.localizedDescription). Is another VibeBridge running?")
            }
        }
        listener.start(queue: queue)
    }

    deinit { listener.cancel() }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] chunk, _, done, error in
            guard let self else { return conn.cancel() }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            switch Self.parse(buffer) {
            case .complete(let req):
                Task {
                    let resp = await self.handler(req)
                    self.send(resp, on: conn)
                }
            case .invalid(let message):
                self.send(.error(400, message), on: conn)
            case .incomplete:
                if done || error != nil { conn.cancel() } else { self.receive(conn, buffer: buffer) }
            }
        }
    }

    private func send(_ resp: HTTPResponse, on conn: NWConnection) {
        var head = "HTTP/1.1 \(resp.status) \(Self.reason(resp.status))\r\n"
        head += "Content-Type: \(resp.contentType)\r\n"
        head += "Content-Length: \(resp.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(resp.body)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    private enum Parsed {
        case complete(HTTPRequest)
        case incomplete
        case invalid(String)
    }

    private static func parse(_ buffer: Data) -> Parsed {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .invalid("headers too large") : .incomplete
        }
        let head = String(decoding: buffer[..<split.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid("bad request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        guard length <= maxBody else { return .invalid("body too large") }
        let body = buffer[split.upperBound...]
        guard body.count >= length else { return .incomplete }

        let comps = URLComponents(string: String(requestLine[1]))
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: comps?.path ?? "/",
                                     query: query, headers: headers, body: Data(body.prefix(length))))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return status < 400 ? "OK" : "Error"
        }
    }
}
