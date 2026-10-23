import SwiftUI

/// DSH diagnostics stay available without occupying the primary chat canvas.
struct ChatActivityView: View {
    let sessionId: String
    @Environment(NativeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if store.selected?.id != sessionId {
                    ContentUnavailableView("Conversation changed", systemImage: "bubble.left")
                } else {
                    Section("Session") {
                        Text(store.selected?.title ?? "Conversation").font(.headline)
                        Label(store.currentPermissionLabel, systemImage: "shield")
                        if store.conversation.running { Button("Stop agent", systemImage: "stop.fill", role: .destructive) { Task { await store.stop() } }.disabled(!store.connected) }
                    }
                    Section("Trajectory") {
                        ForEach(store.conversation.eventSeqs, id: \.self) { seq in
                            let event = store.conversation.events[seq] ?? .null
                            NavigationLink {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 16) {
                                        Text(event["type"].string ?? "Event").font(.headline)
                                        if let entry = store.conversation.entry(for: seq) {
                                            if !entry.text.isEmpty { Text(entry.text).textSelection(.enabled) }
                                            if let detail = entry.detail { Text(detail).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                                            if !entry.reasoning.isEmpty { Text(entry.reasoning).foregroundStyle(.secondary).textSelection(.enabled) }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                                }.navigationTitle("Event \(seq)").navigationBarTitleDisplayMode(.inline)
                            } label: {
                                HStack(alignment: .top) {
                                    Text("\(seq)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(event["type"].string ?? "Event").font(.subheadline)
                                        if let entry = store.conversation.entry(for: seq) { Text(entry.text).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    }
                                }
                            }
                        }
                    }
                }
            }.accessibilityIdentifier("nativeTrajectory")
            .navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
