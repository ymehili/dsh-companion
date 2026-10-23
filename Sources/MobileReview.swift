import SwiftUI

/// Session-scoped review entry; the caller owns the NavigationStack.
struct MobileReview: View {
    let sessionId: String
    @Environment(NativeStore.self) private var store
    @State private var fixture = MobileReviewFixtureTransport()
    @State private var selectedSeq: Int?
    @State private var fixtureMode: MobileReviewFixtureTransport.Mode = .recorded
    @State private var summary: MobileReviewSummary?
    @State private var busy = false
    @State private var issue: String?
    @State private var retry = 0
    @State private var addedCount = 0
    @State private var confirmation: String?
    @State private var rangeAction: MobileReviewRangeAction?
    private var records: [MobileReviewRecord] {
        store.usesFixture ? MobileReviewFixtureTransport.records(sessionId) : MobileReviewRecord.loaded(sessionId: sessionId, selectedId: store.selected?.id, events: store.conversation.events)
    }
    private var record: MobileReviewRecord? { records.first { $0.seq == selectedSeq } ?? records.first }
    private var service: MobileReviewService { MobileReviewService(sessionId: sessionId, transport: store.usesFixture ? fixture : store.gateway) }
    private var loadKey: String { "\(sessionId):\(record?.seq ?? -1):\(fixtureMode.rawValue):\(retry)" }
    var body: some View {
        VStack(spacing: 0) {
            controls
            if let confirmation { Text(confirmation).font(.footnote).foregroundStyle(.green).padding(8).accessibilityIdentifier("review-added-confirmation") }
            if busy { ProgressView("Loading recorded changes…").padding() }
            if let issue {
                ContentUnavailableView { Label("Changes unavailable", systemImage: "exclamationmark.triangle") } description: { Text(issue) } actions: { Button("Retry") { retry += 1 } }
            } else if let summary, let record {
                review(summary, record: record)
            } else if !busy {
                ContentUnavailableView { Label("No loaded change recordings", systemImage: "doc.text.magnifyingglass") } description: {
                    Text(store.selected?.id == sessionId ? "No workspace/changes events in loaded history. Load earlier history explicitly to look for recorded turns." : "Select this conversation in chat to load its recorded history. Other conversations’ history is never used.")
                } actions: {
                    Button("Load earlier") { Task { guard !store.usesFixture, store.selected?.id == sessionId else { return }; await store.older() } }
                        .disabled(store.usesFixture || store.selected?.id != sessionId || !store.conversation.hasMore)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let action = rangeAction {
                HStack {
                    Button("Comment on \(action.target.label)", action: action.show).buttonStyle(.borderedProminent)
                    Button("Cancel") { action.cancel(); rangeAction = nil }
                }.padding(8).frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
        .background(MobileSurface.sheet)
        .navigationTitle("Review changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Text("\(addedCount) added").font(.caption).accessibilityLabel("\(addedCount) review comments added to draft") } }
        .task(id: loadKey) { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mobile-review")
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !records.isEmpty {
                Picker("Recorded turn", selection: $selectedSeq) {
                    Text("Latest recorded turn").tag(Int?.none)
                    ForEach(records) { record in Text("Turn \(record.turn) · event \(record.seq)").tag(Optional(record.seq)) }
                }.pickerStyle(.menu).accessibilityIdentifier("review-turn-picker")
            }
            Text("File changes recorded after an agent turn").font(.caption).foregroundStyle(.secondary)
            if store.usesFixture {
                Picker("Synthetic fixture", selection: $fixtureMode) { ForEach(MobileReviewFixtureTransport.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            }
        }.padding(.horizontal).padding(.vertical, 8)
    }
    private func review(_ summary: MobileReviewSummary, record: MobileReviewRecord) -> some View {
        ScrollView {
            LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
                HStack {
                    Text("Turn \(record.turn) · \(summary.total) files")
                    Spacer()
                    Text("+\(summary.added)").foregroundStyle(.green)
                    Text("−\(summary.deleted)").foregroundStyle(.red)
                }.font(.subheadline).padding(.horizontal)
                if summary.partial { Text("Partial recording: \(summary.files.count) of \(summary.total) files available.").font(.footnote).foregroundStyle(.orange).padding(.horizontal) }
                if summary.files.isEmpty { ContentUnavailableView("No changed files", systemImage: "checkmark.circle", description: Text("This recorded turn contains no file changes.")) }
                ForEach(summary.files) { file in
                    MobileReviewFileSection(service: service, summary: summary, file: file, rangeChanged: { rangeAction = $0 }) { target, text in
                        do {
                            let xml = try target.xml(comment: text)
                            guard target.record.sessionId == sessionId, store.appendReviewDraft(xml, for: target.record.sessionId) else { return false }
                            addedCount += 1; confirmation = "Added to this conversation’s draft. Not sent."
                            return true
                        } catch { return false }
                    }.id("\(record.seq):\(file.index):\(retry):\(fixtureMode.rawValue)")
                }
                Text("Tap a line to comment. Long-press a line, then tap an end line on the same side to select a range. Comments stay in your local draft until you choose to send them.").font(.footnote).foregroundStyle(.secondary).padding()
            }.padding(.vertical)
        }.accessibilityIdentifier("review-file-list")
    }
    private func load() async {
        summary = nil; issue = nil; rangeAction = nil
        guard let record else { busy = false; return }
        guard store.usesFixture || store.sessions.contains(where: { $0.id == sessionId }) else { issue = MobileReviewFailure.boundary.localizedDescription; return }
        let key = loadKey; busy = true; fixture.mode = fixtureMode
        defer { if key == loadKey { busy = false } }
        do {
            let result = try await service.summary(record)
            try Task.checkCancellation()
            guard key == loadKey else { return }; summary = result
        } catch is CancellationError {} catch { guard key == loadKey else { return }; issue = error.localizedDescription }
    }
}

private struct MobileReviewRangeAction {
    let target: MobileReviewTarget
    let show: () -> Void
    let cancel: () -> Void
}

private struct MobileReviewFileSection: View {
    let service: MobileReviewService
    let summary: MobileReviewSummary
    let file: MobileReviewFile
    let rangeChanged: (MobileReviewRangeAction?) -> Void
    let append: (MobileReviewTarget, String) -> Bool
    @State private var expanded = false
    @State private var diff: MobileReviewDiff?
    @State private var busy = false
    @State private var issue: String?
    @State private var rangeStart: MobileReviewTarget?
    @State private var rangeEnd: MobileReviewTarget?
    @State private var target: MobileReviewTarget?
    var body: some View {
        Section {
            if expanded {
                if busy { ProgressView("Loading comparison…").padding() }
                if let issue { VStack { Text(issue).font(.footnote); Button("Retry comparison") { Task { await load() } } }.padding() }
                if let diff {
                    if diff.kind != "text" {
                        Label(diff.kind == "binary" ? "Binary file — no text comparison available" : "Oversized file — host refused the comparison", systemImage: "doc.badge.ellipsis").font(.footnote).padding()
                    } else {
                        if diff.coarse { Text("Coarse whole-file comparison (host fallback).").font(.footnote).foregroundStyle(.orange) }
                        if diff.hunks.isEmpty { Text("No text hunks in this recording.").font(.footnote).padding() }
                        ScrollView(.horizontal) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(diff.hunks) { hunk in
                                    Text(hunk.title).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).padding(.vertical, 8)
                                    ForEach(hunk.lines) { line in lineRow(line) }
                                }
                            }.fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
        } header: {
            Button {
                expanded.toggle()
                if expanded && diff == nil { Task { await load() } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    Text(file.display).font(.system(.subheadline, design: .monospaced)).lineLimit(2)
                    Spacer(minLength: 4)
                    Text("+\(file.added)").foregroundStyle(.green)
                    Text("−\(file.deleted)").foregroundStyle(.red)
                }.font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(MobileSurface.card)
            }.buttonStyle(.plain).accessibilityIdentifier("review-file-\(file.index)")
        }
        .sheet(item: $target) { captured in
            MobileReviewCommentSheet(target: captured) { text in
                let success = append(captured, text)
                if success { rangeStart = nil; rangeEnd = nil; rangeChanged(nil) }
                return success
            }
        }
    }
    private func lineRow(_ line: MobileReviewLine) -> some View {
        let tone: Color = line.prefix == "+" ? .green : line.prefix == "-" ? .red : .primary
        return HStack(spacing: 10) {
            Text(line.old.map(String.init) ?? "").frame(width: 42, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.new.map(String.init) ?? "").frame(width: 42, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.text).foregroundStyle(tone).lineLimit(1).fixedSize(horizontal: true, vertical: true)
        }
        .fixedSize(horizontal: true, vertical: true)
        .font(.system(.caption, design: .monospaced)).padding(.vertical, 4).padding(.horizontal, 8).frame(minHeight: 24)
        .background(tone.opacity(line.prefix == "+" || line.prefix == "-" ? 0.09 : 0))
        .contentShape(Rectangle())
        .onTapGesture { select(line, range: false) }
        .onLongPressGesture { select(line, range: true) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Old line \(line.old.map(String.init) ?? "none"), new line \(line.new.map(String.init) ?? "none"): \(line.text)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Start range") { select(line, range: true) }
    }
    private func select(_ line: MobileReviewLine, range: Bool) {
        let side = !range ? (rangeStart?.side ?? line.side) : line.side
        guard let number = side == "old" ? line.old : line.new,
              let value = try? MobileReviewTarget(record: summary.record, path: file.path, side: side, start: number, end: number) else { return }
        if range { rangeStart = value; rangeEnd = nil }
        else if let start = rangeStart {
            guard start.side == value.side else { return }
            rangeEnd = try? MobileReviewTarget(record: start.record, path: start.path, side: start.side, start: start.start, end: number)
        } else { target = value }
        if let captured = rangeEnd ?? rangeStart {
            rangeChanged(MobileReviewRangeAction(target: captured, show: { target = captured }, cancel: {
                rangeStart = nil; rangeEnd = nil
            }))
        }
    }
    private func load() async {
        guard !busy else { return }; busy = true; issue = nil
        defer { busy = false }
        do { let result = try await service.diff(file, summary: summary); try Task.checkCancellation(); diff = result }
        catch is CancellationError {} catch { issue = error.localizedDescription }
    }
}

private struct MobileReviewCommentSheet: View {
    let target: MobileReviewTarget
    let append: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var failed = false
    var body: some View {
        NavigationStack {
            Form {
                Section("\(target.side == "old" ? "Before" : "After") · \(target.label)") {
                    Text(target.path).font(.system(.footnote, design: .monospaced))
                    Text("Turn \(target.record.turn) · event \(target.record.seq)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $text).frame(minHeight: 150).accessibilityIdentifier("review-comment-text")
                }
                Section {
                    Text("Adds escaped review context to this conversation’s local draft. You decide when to send it from chat.")
                    Text("Photo attachments are not available in review comments yet.")
                }.font(.footnote).foregroundStyle(.secondary)
                if failed { Text("Could not append. This conversation must still exist and be writable; your comment has not been sent.").foregroundStyle(.red) }
            }
            .navigationTitle("Add review comment").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to draft") { if append(text) { dismiss() } else { failed = true } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 16_384)
                        .accessibilityIdentifier("review-add-to-draft")
                }
            }
        }
    }
}
