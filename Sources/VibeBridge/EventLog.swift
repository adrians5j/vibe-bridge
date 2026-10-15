import Foundation
import SQLite3
import VibeBridgeKit

/// The durable part: events in order, and where each consumer is in them.
/// Plain SQLite through the system library; one connection, used from the main actor.
@MainActor
final class EventLog {
    struct Consumer: Identifiable, Equatable {
        var name: String
        var cursor: Int64
        var types: [String]
        var lastSeen: Date
        var id: String { name }
    }

    private var db: OpaquePointer?

    init(path: URL) throws {
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            throw BridgeError("can't open \(path.path)")
        }
        try exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS events(
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            type TEXT NOT NULL,
            source TEXT NOT NULL,
            time REAL NOT NULL,
            json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS events_time ON events(time);
        CREATE TABLE IF NOT EXISTS consumers(
            name TEXT PRIMARY KEY,
            cursor INTEGER NOT NULL,
            types TEXT NOT NULL DEFAULT '',
            last_seen REAL NOT NULL
        );
        """)
    }

    // MARK: - events

    /// Stores the event and returns its seq, or nil when the id is already in the log.
    func append(_ event: BridgeEvent) throws -> Int64? {
        let json = String(decoding: try BridgeJSON.encoder.encode(event), as: UTF8.self)
        let stmt = try prepare("INSERT OR IGNORE INTO events(id, type, source, time, json) VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, event.id)
        bind(stmt, 2, event.type)
        bind(stmt, 3, event.source)
        sqlite3_bind_double(stmt, 4, event.time.timeIntervalSince1970)
        bind(stmt, 5, json)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
        return sqlite3_changes(db) == 0 ? nil : sqlite3_last_insert_rowid(db)
    }

    func contains(id: String) -> Bool {
        guard let stmt = try? prepare("SELECT 1 FROM events WHERE id = ?") else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func events(after seq: Int64, limit: Int) -> [BridgeEvent] {
        query("SELECT seq, json FROM events WHERE seq > ? ORDER BY seq LIMIT ?") {
            sqlite3_bind_int64($0, 1, seq)
            sqlite3_bind_int64($0, 2, Int64(limit))
        }
    }

    func recent(_ limit: Int) -> [BridgeEvent] {
        query("SELECT seq, json FROM events ORDER BY seq DESC LIMIT ?") {
            sqlite3_bind_int64($0, 1, Int64(limit))
        }
    }

    var head: Int64 {
        guard let stmt = try? prepare("SELECT COALESCE(MAX(seq), 0) FROM events") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    /// Deletes events older than `date` and returns them, so their files can go too.
    func prune(before date: Date) -> [BridgeEvent] {
        let old: [BridgeEvent] = query("SELECT seq, json FROM events WHERE time < ?") {
            sqlite3_bind_double($0, 1, date.timeIntervalSince1970)
        }
        if let stmt = try? prepare("DELETE FROM events WHERE time < ?") {
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        return old
    }

    // MARK: - consumers

    func consumer(_ name: String) -> Consumer? {
        consumers().first { $0.name == name }
    }

    func consumers() -> [Consumer] {
        guard let stmt = try? prepare("SELECT name, cursor, types, last_seen FROM consumers ORDER BY name") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Consumer] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let types = text(stmt, 2).split(separator: ",").map(String.init)
            out.append(Consumer(name: text(stmt, 0), cursor: sqlite3_column_int64(stmt, 1), types: types,
                                lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))))
        }
        return out
    }

    func saveConsumer(_ c: Consumer) {
        guard let stmt = try? prepare("""
        INSERT INTO consumers(name, cursor, types, last_seen) VALUES(?,?,?,?)
        ON CONFLICT(name) DO UPDATE SET cursor = excluded.cursor, types = excluded.types, last_seen = excluded.last_seen
        """) else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, c.name)
        sqlite3_bind_int64(stmt, 2, c.cursor)
        bind(stmt, 3, c.types.joined(separator: ","))
        sqlite3_bind_double(stmt, 4, c.lastSeen.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func deleteConsumer(_ name: String) {
        guard let stmt = try? prepare("DELETE FROM consumers WHERE name = ?") else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, name)
        sqlite3_step(stmt)
    }

    // MARK: - sqlite plumbing

    private func query(_ sql: String, _ binder: (OpaquePointer?) -> Void) -> [BridgeEvent] {
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        binder(stmt)
        var out: [BridgeEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let seq = sqlite3_column_int64(stmt, 0)
            guard var event = try? BridgeJSON.decoder.decode(BridgeEvent.self, from: Data(text(stmt, 1).utf8)) else { continue }
            event.seq = seq
            out.append(event)
        }
        return out
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        return stmt
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }

    private func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    private func lastError() -> BridgeError {
        BridgeError(String(cString: sqlite3_errmsg(db)))
    }
}
