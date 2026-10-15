import AppKit
import Foundation
import ServiceManagement
import VibeBridgeKit

/// Ties the log, the inbox and the HTTP server together, and feeds the menu bar UI.
@MainActor
final class Hub: ObservableObject {
    struct ConsumerRow: Identifiable, Equatable {
        var consumer: EventLog.Consumer
        /// Matching events it hasn't acked yet.
        var pending: Int
        var id: String { consumer.name }
    }

    @Published private(set) var recent: [BridgeEvent] = []
    @Published private(set) var consumers: [ConsumerRow] = []
    @Published private(set) var problem: String?

    let root = VibeBridge.root
    var filesDir: URL { root.appendingPathComponent("files", isDirectory: true) }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    private var log: EventLog!
    private var server: HTTPServer?
    private var inboxWatch: DispatchSourceFileSystemObject?
    private var sweepTimer: Timer?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private static let retentionDays = ProcessInfo.processInfo.environment["VB_RETENTION_DAYS"].flatMap(Double.init) ?? 30

    init() {
        let fm = FileManager.default
        for dir in [root, VibeBridge.inbox, filesDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        do {
            log = try EventLog(path: root.appendingPathComponent("events.sqlite"))
        } catch {
            problem = "Event log: \(error.localizedDescription)"
            return
        }
        prune()
        ingestInbox()
        watchInbox()
        // The directory watch covers normal use; the sweep catches anything it missed and prunes daily-ish.
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in self.ingestInbox() }
        }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in self.prune() }
        }
        startServer()
        refresh()
    }

    // MARK: - inbox

    private func watchInbox() {
        let fd = open(VibeBridge.inbox.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.ingestInbox() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        inboxWatch = source
    }

    /// Moves every finished inbox folder into the log. Folders still being written start with a dot.
    func ingestInbox() {
        guard log != nil else { return }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: VibeBridge.inbox, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var added = false
        for folder in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where !folder.lastPathComponent.hasPrefix(".") {
            if ingest(folder) { added = true }
        }
        if added {
            wake()
            refresh()
        }
    }

    private func ingest(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("event.json")),
              var event = try? BridgeJSON.decoder.decode(BridgeEvent.self, from: data) else {
            // Unreadable: park it so it doesn't get retried forever, but keep it for a look.
            try? fm.moveItem(at: folder, to: VibeBridge.inbox.appendingPathComponent(".bad-\(folder.lastPathComponent)"))
            return false
        }
        if log.contains(id: event.id) {
            try? fm.removeItem(at: folder)
            return false
        }

        let dest = filesDir.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        if event.attachments.isEmpty {
            try? fm.removeItem(at: folder)
        } else {
            do {
                try fm.moveItem(at: folder, to: dest)
                try? fm.removeItem(at: dest.appendingPathComponent("event.json"))
            } catch {
                problem = "Inbox: \(error.localizedDescription)"
                return false
            }
            event.attachments = event.attachments.compactMap { a in
                // Paths are relative to the folder and must stay inside it.
                guard !a.path.contains("/"), !a.path.hasPrefix(".") else { return nil }
                var a = a
                a.path = dest.appendingPathComponent(a.path).path
                return fm.fileExists(atPath: a.path) ? a : nil
            }
        }

        event.seq = nil
        do {
            return try log.append(event) != nil
        } catch {
            problem = "Log: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - delivery

    /// Long-poll for one consumer: returns as soon as there's something, or empty after `wait` seconds.
    func poll(consumer name: String, types: [String], wait: TimeInterval, limit: Int = 20) async -> [BridgeEvent] {
        guard log != nil else { return [] }
        // A new consumer starts at the end of the log, so it doesn't get a month of history on its first run.
        var c = log.consumer(name) ?? EventLog.Consumer(name: name, cursor: log.head, types: types, lastSeen: Date())
        c.types = types
        c.lastSeen = Date()
        log.saveConsumer(c)
        refresh()

        let deadline = Date().addingTimeInterval(min(wait, 55))
        while true {
            let (matches, scanned) = scan(after: c.cursor, types: types, limit: limit)
            if !matches.isEmpty { return matches }
            // Nothing in there is for this consumer, so move it past what was looked at.
            if scanned > c.cursor {
                c.cursor = scanned
                log.saveConsumer(c)
                refresh()
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return [] }
            await waitForAppend(timeout: remaining)
            if let fresh = log.consumer(name) { c.cursor = fresh.cursor }
        }
    }

    /// Advances the cursor past `seq`. Never moves it back; that's `rewind`.
    func ack(consumer name: String, seq: Int64) {
        guard log != nil, var c = log.consumer(name) else { return }
        c.cursor = max(c.cursor, seq)
        c.lastSeen = Date()
        log.saveConsumer(c)
        refresh()
    }

    /// Sets the cursor so everything after `seq` is delivered again.
    func rewind(consumer name: String, to seq: Int64) {
        guard log != nil, var c = log.consumer(name) else { return }
        c.cursor = max(0, seq)
        log.saveConsumer(c)
        wake()
        refresh()
    }

    func forget(consumer name: String) {
        log?.deleteConsumer(name)
        refresh()
    }

    private func scan(after cursor: Int64, types: [String], limit: Int) -> ([BridgeEvent], Int64) {
        var from = cursor
        var matches: [BridgeEvent] = []
        while matches.isEmpty {
            let batch = log.events(after: from, limit: 500)
            guard let last = batch.last?.seq else { break }
            matches = batch.filter { Self.matches($0.type, types) }.prefix(limit).map { $0 }
            if matches.isEmpty { from = last }
        }
        return (matches, from)
    }

    static func matches(_ type: String, _ patterns: [String]) -> Bool {
        patterns.isEmpty || patterns.contains { p in
            p == "*" || p == type || (p.hasSuffix(".*") && type.hasPrefix(String(p.dropLast())))
        }
    }

    private func waitForAppend(timeout: TimeInterval) async {
        let id = UUID()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters[id] = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.waiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func wake() {
        let all = waiters
        waiters = [:]
        for cont in all.values { cont.resume() }
    }

    // MARK: - publishing over HTTP

    struct Incoming: Decodable {
        struct File: Decodable {
            var name: String
            var mime: String?
            /// Base64.
            var content: String
        }
        var id: String?
        var type: String
        var source: String
        var data: JSONValue?
        var attachments: [File]?
    }

    /// Same path as the client library: write to the inbox, then ingest straight away.
    func publish(_ e: Incoming) throws -> String {
        let id = e.id ?? UUID().uuidString
        let files = try (e.attachments ?? []).map { f -> VibeBridge.File in
            guard let data = Data(base64Encoded: f.content, options: .ignoreUnknownCharacters) else {
                throw BridgeError("attachment \(f.name) is not valid base64")
            }
            return VibeBridge.File(name: f.name, mime: f.mime ?? "application/octet-stream", data: data)
        }
        try VibeBridge.publish(type: e.type, source: e.source, id: id, data: e.data ?? .object([:]), files: files)
        ingestInbox()
        return id
    }

    func recentEvents(_ limit: Int) -> [BridgeEvent] { log?.recent(limit) ?? [] }

    // MARK: - housekeeping

    private func prune() {
        guard log != nil else { return }
        let cutoff = Date().addingTimeInterval(-Self.retentionDays * 86400)
        for event in log.prune(before: cutoff) {
            for folder in Set(event.attachments.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() })
            where folder.deletingLastPathComponent().standardizedFileURL == filesDir.standardizedFileURL {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        refresh()
    }

    private func startServer() {
        do {
            server = try HTTPServer(port: VibeBridge.port) { [weak self] req in
                guard let self else { return .error(503, "shutting down") }
                return await Routes.handle(req, hub: self)
            }
            server?.onFailure = { [weak self] message in
                Task { @MainActor in self?.problem = message }
            }
        } catch {
            problem = "Server: \(error.localizedDescription)"
        }
    }

    func refresh() {
        guard log != nil else { return }
        recent = log.recent(40)
        consumers = log.consumers().map { c in
            var pending = 0
            var from = c.cursor
            while true {
                let batch = log.events(after: from, limit: 500)
                guard let last = batch.last?.seq else { break }
                pending += batch.filter { Self.matches($0.type, c.types) }.count
                from = last
            }
            return ConsumerRow(consumer: c, pending: pending)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            problem = "Launch at login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    func dismissProblem() { problem = nil }
}
