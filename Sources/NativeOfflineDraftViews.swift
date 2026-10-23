import SwiftUI
import UIKit

/// Presentation only: a local draft is never a synthetic Mac Inbox item.
enum NativeOfflineDraftSummary {
    static func title(_ record: NativeDraftRecord) -> String {
        let title = record.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled draft" : title
    }

    static func project(_ record: NativeDraftRecord) -> String {
        guard let workspace = record.workspace, !workspace.isEmpty else { return "Local draft · No project saved" }
        return SidebarAppearance.workspaceTitle(workspace)
    }

    static func detail(_ record: NativeDraftRecord) -> String {
        var parts: [String] = []
        let text = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append(String(text.prefix(160))) }
        if !record.photos.isEmpty { parts.append("\(record.photos.count) \(record.photos.count == 1 ? "photo" : "photos")") }
        if let pending = record.pending {
            parts.append("Saved pending request · \(pending.mode) · \(pending.images.count) photos")
        }
        return parts.isEmpty ? "Unsent draft · saved on this iPhone" : parts.joined(separator: " · ")
    }
}

/// Caller owns navigation. This editor cannot send, retry, create or rebind a session.
struct NativeOfflineDraftEditor: View {
    let sessionId: String
    @Environment(NativeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var finishing = false
    @State private var confirmingDiscard = false
    @State private var discardIssue: String?

    private var record: NativeDraftRecord? { store.localDraftRecords[sessionId] }
    private var text: Binding<String> {
        Binding(get: { store.savedDraftText(sessionId) }, set: { store.updateDraftText($0, for: sessionId) })
    }

    var body: some View {
        MobilePage {
            MobileSection {
                Label("Draft saved on this iPhone. Reconnect to open its Mac conversation.", systemImage: "iphone")
                    .font(.subheadline).foregroundStyle(DSHTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .accessibilityIdentifier("offline-draft-notice")
            }
            if !store.draftsLoaded {
                ProgressView("Loading local draft…")
            } else if let record {
                MobileSection(title: NativeOfflineDraftSummary.project(record), footer: "Edits stay on this iPhone. Nothing is sent from this screen.") {
                    TextEditor(text: text)
                        .font(.body).foregroundStyle(DSHTheme.label)
                        .scrollContentBackground(.hidden).frame(minHeight: 180)
                        .padding(10.5).accessibilityLabel("Local draft text")
                        .accessibilityIdentifier("offline-draft-text")
                    let photos = store.attachments.photos(in: sessionId)
                    if !photos.isEmpty {
                        PhotoAttachmentsView(photos: photos, loading: false,
                                             remove: { store.removeDraftPhoto(sessionId, photoID: $0) }, cancel: {})
                            .padding(14)
                    }
                }
                if let pending = record.pending { pendingSummary(pending) }
                if let issue = store.draftSaveErrors[sessionId] {
                    MobileSection(title: "Draft not saved") {
                        Text("Your draft is retained in this app. \(issue)")
                            .font(.footnote).foregroundStyle(DSHTheme.statusFailed).padding(14)
                            .accessibilityIdentifier("offline-draft-save-error")
                    }
                }
                MobileSection {
                    Button(role: .destructive) { confirmingDiscard = true } label: {
                        MobileRow(title: "Discard local draft…", symbol: "trash", disclosure: false)
                    }.accessibilityIdentifier("offline-draft-discard")
                }
            } else {
                Text("This local draft is no longer available. No Mac conversation was changed.")
                    .foregroundStyle(DSHTheme.secondary).accessibilityIdentifier("offline-draft-missing")
            }
            ForEach(store.draftLoadIssues, id: \.self) { issue in
                Text("Some draft data could not be loaded and has been retained. \(issue)")
                    .font(.footnote).foregroundStyle(DSHTheme.secondary)
            }
        }
        .navigationTitle(record.map(NativeOfflineDraftSummary.title) ?? "Local draft")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    finishing = true
                    Task {
                        await store.flushDrafts()
                        finishing = false
                        if store.draftSaveErrors[sessionId] == nil { dismiss() }
                    }
                }.disabled(finishing).accessibilityIdentifier("offline-draft-done")
            }
        }
        .alert("Discard local draft?", isPresented: $confirmingDiscard) {
            Button("Discard local draft", role: .destructive) {
                Task {
                    if await store.removeLocalDraft(sessionId) { dismiss() }
                    else { discardIssue = store.draftSaveErrors[sessionId] ?? "The draft is retained on this iPhone. An in-flight request must finish before it can be discarded." }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only this iPhone’s draft, photos, and saved pending request will be removed. The Mac conversation and any delivered message stay unchanged.")
        }
        .alert("Draft retained", isPresented: Binding(get: { discardIssue != nil }, set: { if !$0 { discardIssue = nil } })) {
            Button("OK", role: .cancel) { discardIssue = nil }
        } message: { Text(discardIssue ?? "") }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offline-draft-editor")
    }

    private func pendingSummary(_ pending: NativePendingDraft) -> some View {
        MobileSection(title: "Saved pending request", footer: "Read-only original request. It may already have been delivered to your Mac. Copying it into another message could send it twice.") {
            VStack(alignment: .leading, spacing: 10.5) {
                Text("Mode: \(pending.mode) · \(pending.images.count) photos").font(.footnote).foregroundStyle(DSHTheme.secondary)
                Text("Request ID: \(pending.requestID)").font(.caption).foregroundStyle(DSHTheme.tertiary).textSelection(.enabled)
                Text(pending.text.isEmpty ? "Photo-only request" : pending.text).textSelection(.enabled)
                Button("Copy original request text", systemImage: "doc.on.doc") { UIPasteboard.general.string = pending.text }
                    .disabled(pending.text.isEmpty).accessibilityIdentifier("offline-draft-copy-pending")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.accessibilityIdentifier("offline-draft-pending")
    }
}
