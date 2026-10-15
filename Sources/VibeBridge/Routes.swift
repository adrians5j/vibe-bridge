import Foundation
import VibeBridgeKit

/// The HTTP API. See README for curl examples.
///
///   GET  /health
///   GET  /events?limit=50              recent events, newest first
///   POST /events                       publish (JSON, attachments as base64)
///   GET  /poll?consumer=&types=&wait=  long-poll for a consumer
///   POST /ack     {consumer, seq}      done with everything up to seq
///   POST /rewind  {consumer, seq}      redeliver everything after seq
///   GET  /consumers
enum Routes {
    @MainActor
    static func handle(_ req: HTTPRequest, hub: Hub) async -> HTTPResponse {
        // Browsers send Origin; local apps and curl don't. Refusing it keeps web pages
        // from posting to the bridge behind your back.
        if req.headers["origin"] != nil { return .error(403, "browser requests are not allowed") }

        switch (req.method, req.path) {
        case ("GET", "/health"):
            return .json(["ok": true])

        case ("GET", "/events"):
            let limit = req.query["limit"].flatMap(Int.init) ?? 50
            return encode(["events": hub.recentEvents(min(limit, 500))])

        case ("POST", "/events"):
            do {
                let incoming = try BridgeJSON.decoder.decode(Hub.Incoming.self, from: req.body)
                return .json(["id": try hub.publish(incoming)])
            } catch {
                return .error(400, error.localizedDescription)
            }

        case ("GET", "/poll"):
            guard let consumer = req.query["consumer"], !consumer.isEmpty else {
                return .error(400, "consumer is required")
            }
            let types = (req.query["types"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let wait = req.query["wait"].flatMap(Double.init) ?? 0
            let limit = req.query["limit"].flatMap(Int.init) ?? 20
            let events = await hub.poll(consumer: consumer, types: types, wait: wait, limit: max(1, min(limit, 200)))
            return encode(["events": events])

        case ("POST", "/ack"), ("POST", "/rewind"):
            guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let consumer = body["consumer"] as? String,
                  let seq = (body["seq"] as? NSNumber)?.int64Value else {
                return .error(400, "expected {consumer, seq}")
            }
            if req.path == "/ack" { hub.ack(consumer: consumer, seq: seq) } else { hub.rewind(consumer: consumer, to: seq) }
            return .json(["ok": true])

        case ("GET", "/consumers"):
            return .json(["consumers": hub.consumers.map { row in
                ["name": row.consumer.name, "cursor": row.consumer.cursor, "types": row.consumer.types,
                 "pending": row.pending, "lastSeen": ISO8601DateFormatter().string(from: row.consumer.lastSeen)] as [String: Any]
            }])

        case (_, "/health"), (_, "/events"), (_, "/poll"), (_, "/ack"), (_, "/rewind"), (_, "/consumers"):
            return .error(405, "method not allowed")

        default:
            return .error(404, "no such endpoint")
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> HTTPResponse {
        do {
            return HTTPResponse(status: 200, body: try BridgeJSON.encoder.encode(value))
        } catch {
            return .error(500, error.localizedDescription)
        }
    }
}
