import AppKit
import SwiftUI
import VibeBridgeKit

struct ContentView: View {
    @ObservedObject var hub: Hub
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let problem = hub.problem {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { hub.dismissProblem() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(10)
                .background(.orange.opacity(0.12))
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    consumers
                    events
                }
                .padding(12)
            }
            .frame(height: 420)
            Divider()
            footer
        }
        .frame(width: 420)
    }

    private var header: some View {
        HStack {
            Image(systemName: "point.3.connected.trianglepath.dotted")
            Text("Vibe Bridge").font(.headline)
            Spacer()
            Text("127.0.0.1:\(String(VibeBridge.port))").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var consumers: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Consumers")
            if hub.consumers.isEmpty {
                Text("No app has subscribed yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(hub.consumers) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.consumer.name).font(.body.weight(.medium))
                        Text(row.consumer.types.isEmpty ? "all events" : row.consumer.types.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.pending > 0 {
                        Text("\(row.pending) waiting")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.orange.opacity(0.2)))
                    }
                    Text(row.consumer.lastSeen, style: .relative)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
                .contextMenu {
                    Button("Redeliver last delivered event") {
                        hub.rewind(consumer: row.consumer.name, to: lastDelivered(row) - 1)
                    }
                    .disabled(lastDelivered(row) == 0)
                    Button("Forget consumer") { hub.forget(consumer: row.consumer.name) }
                }
            }
        }
    }

    /// The newest event at or before the cursor that this consumer would have received.
    private func lastDelivered(_ row: Hub.ConsumerRow) -> Int64 {
        hub.recent.first { ($0.seq ?? 0) <= row.consumer.cursor && Hub.matches($0.type, row.consumer.types) }?.seq ?? 0
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Recent events")
            if hub.recent.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(hub.recent) { event in
                EventRow(event: event, expanded: expanded == event.id) {
                    expanded = expanded == event.id ? nil : event.id
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: Binding(get: { hub.launchAtLogin }, set: { hub.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
            Spacer()
            Button("Data Folder") { NSWorkspace.shared.open(hub.root) }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

private struct EventRow: View {
    let event: BridgeEvent
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    Text(event.type).font(.body.monospaced())
                    if !event.attachments.isEmpty {
                        Label("\(event.attachments.count)", systemImage: "paperclip")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(event.source).font(.caption).foregroundStyle(.secondary)
                    Text(event.time, style: .relative)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(pretty)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                ForEach(event.attachments, id: \.path) { a in
                    Button {
                        NSWorkspace.shared.open(a.url)
                    } label: {
                        Label("\(a.name)  ·  \(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))",
                              systemImage: "doc")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
                Text("seq \(event.seq ?? 0) · \(event.id)")
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            }
        }
    }

    private var pretty: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(event.data)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
