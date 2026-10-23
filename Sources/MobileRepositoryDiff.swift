import SwiftUI

struct MobileRepositoryPatchLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let old: Int?
    let new: Int?
    var side: String { new == nil ? "old" : "new" }
    var number: Int? { new ?? old }
}
struct MobileRepositoryPatch {
    let lines: [MobileRepositoryPatchLine]
    init(_ patch: String) throws {
        try MobileRepositoryValidation.text(patch, max: 2_000_000, empty: true, multiline: true)
        let raw = patch.split(separator: "\n", omittingEmptySubsequences: false)
        guard raw.count <= 20_000 else { throw MobileRepositoryError.invalid }
        let regex = try NSRegularExpression(pattern: "^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@")
        var old = 0, new = 0, oldRemaining = 0, newRemaining = 0, active = false
        var parsed: [MobileRepositoryPatchLine] = []
        for (index, substring) in raw.enumerated() {
            let text = String(substring)
            guard text.utf8.count <= 32_768 else { throw MobileRepositoryError.invalid }
            if text.hasPrefix("@@") {
                guard oldRemaining == 0, newRemaining == 0,
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { throw MobileRepositoryError.invalid }
                func number(_ i: Int, fallback: Int) -> Int {
                    guard let range = Range(match.range(at: i), in: text) else { return fallback }; return Int(text[range]) ?? -1
                }
                old = number(1, fallback: -1); oldRemaining = number(2, fallback: 1)
                new = number(3, fallback: -1); newRemaining = number(4, fallback: 1)
                guard old >= 0, new >= 0, oldRemaining >= 0, newRemaining >= 0, max(old, new) <= 10_000_000, max(oldRemaining, newRemaining) <= 20_000 else { throw MobileRepositoryError.invalid }
                active = true
                parsed.append(.init(id: index, text: text, old: nil, new: nil)); continue
            }
            var o: Int?, n: Int?
            if active && (oldRemaining > 0 || newRemaining > 0) {
                switch text.first {
                case " ": o = old; n = new; old += 1; new += 1; oldRemaining -= 1; newRemaining -= 1
                case "-": o = old; old += 1; oldRemaining -= 1
                case "+": n = new; new += 1; newRemaining -= 1
                case "\\": guard text == "\\ No newline at end of file" else { throw MobileRepositoryError.invalid }
                default: throw MobileRepositoryError.invalid
                }
                guard oldRemaining >= 0, newRemaining >= 0, (o ?? 1) > 0, (n ?? 1) > 0 else { throw MobileRepositoryError.invalid }
            }
            parsed.append(.init(id: index, text: text, old: o, new: n))
        }
        guard oldRemaining == 0, newRemaining == 0 else { throw MobileRepositoryError.invalid }
        lines = parsed
    }
}

struct MobileRepositoryDiffScreen: View {
    let service: any MobileRepositoryServing
    let snapshot: MobileRepositoryStatus
    let file: MobileRepositoryFile
    let staged: Bool
    @Environment(NativeStore.self) private var store
    @State private var diff: MobileRepositoryDiff?
    @State private var patch: MobileRepositoryPatch?
    @State private var issue: String?
    @State private var busy = false
    @State private var rangeStart: MobileRepositoryPatchLine?
    @State private var target: MobileRepositoryReviewTarget?
    @State private var added = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(file.path).font(.subheadline.monospaced()).textSelection(.enabled)
                Text("\(staged ? "Index" : "Working tree") · \(snapshot.branch ?? snapshot.head ?? "unborn HEAD")").font(.caption).foregroundStyle(.secondary)
                Text("Snapshot: \(snapshot.version)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }.padding()
            if busy { ProgressView("Loading diff…").padding() }
            if let issue { Text(issue).font(.footnote).padding(); Button("Retry read") { Task { await load() } }.padding() }
            if let diff {
                if diff.binary { ContentUnavailableView("Binary file", systemImage: "doc.richtext", description: Text("No text diff or line comments are available.")) }
                else if diff.truncated { ContentUnavailableView("Diff truncated", systemImage: "doc.badge.ellipsis", description: Text("The adapter capped this patch. Line review is disabled; no complete comparison is implied.")) }
                else if let patch {
                    if patch.lines.isEmpty { Text("No textual changes in this snapshot.").padding() }
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(patch.lines) { line in
                                HStack(spacing: 12) {
                                    Text(line.old.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
                                    Text(line.new.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
                                    Text(line.text).foregroundStyle(line.text.hasPrefix("+") ? .green : line.text.hasPrefix("-") ? .red : .primary).lineLimit(1).fixedSize(horizontal: true, vertical: true)
                                }.font(.system(.caption, design: .monospaced)).padding(.vertical, 4).padding(.horizontal, 8)
                                    .background(rangeStart?.id == line.id ? DSHTheme.accent.opacity(0.15) : .clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { select(line) }
                                    .onLongPressGesture { if line.number != nil { rangeStart = line } }
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Old \(line.old.map(String.init) ?? "none"), new \(line.new.map(String.init) ?? "none"): \(line.text)")
                                    .accessibilityAddTraits(line.number == nil ? [] : .isButton)
                                    .accessibilityIdentifier("repository-diff-line-\(line.id)")
                            }
                        }.fixedSize(horizontal: true, vertical: false)
                    }.defaultScrollAnchor(.topLeading, for: .alignment)
                }
            }
            if added { Text("Added to this session’s local draft. Not sent or posted.").font(.footnote).foregroundStyle(.green).padding().accessibilityIdentifier("repository-draft-added") }
            if rangeStart != nil { HStack { Text("Tap an end line on the same side.").font(.caption); Button("Cancel range") { rangeStart = nil } }.padding(8) }
            Text("Tap a line to comment. Long-press a start line, then tap an end line for a range. Comments are local Git snapshot references, not turn recordings.").font(.caption).foregroundStyle(.secondary).padding()
        }.background(MobileSurface.sheet).navigationTitle("Diff").navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .sheet(item: $target) { captured in MobileRepositoryLocalComment(target: captured) { text in
                guard captured.sessionId == service.sessionId, let xml = try? captured.xml(comment: text), store.appendReviewDraft(xml, for: captured.sessionId) else { return false }
                added = true; rangeStart = nil; return true
            } }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("repository-diff")
    }
    private func select(_ line: MobileRepositoryPatchLine) {
        guard let number = line.number else { return }
        let start: Int
        if let first = rangeStart {
            guard first.side == line.side, let firstNumber = first.number else { issue = "Range endpoints must use the same side."; return }
            start = firstNumber
        } else { start = number }
        target = .init(sessionId: snapshot.sessionId, version: snapshot.version, ref: snapshot.head ?? "unborn", path: file.path, staged: staged, side: line.side, start: min(start, number), end: max(start, number))
    }
    private func load() async {
        guard !busy else { return }; busy = true; issue = nil
        defer { busy = false }
        do {
            let next = try await service.diff(snapshot: snapshot, file: file, staged: staged); try Task.checkCancellation()
            try next.validate(snapshot: snapshot, file: file)
            patch = next.binary || next.truncated ? nil : try MobileRepositoryPatch(next.patch); diff = next
        } catch is CancellationError {} catch { issue = error.localizedDescription }
    }
}
struct MobileRepositoryLocalComment: View {
    let target: MobileRepositoryReviewTarget
    let append: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var failed = false
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(target.path).font(.caption.monospaced()); Text("\(target.side) · L\(target.start)–L\(target.end) · local draft") }
                Section("Comment") { TextEditor(text: $text).frame(minHeight: 150).accessibilityIdentifier("repository-review-comment") }
                if failed { Text("The local draft could not be updated. Your text is retained.").foregroundStyle(.orange) }
                Button("Add to local draft") { if append(text) { dismiss() } else { failed = true } }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 16_384).accessibilityIdentifier("repository-add-local-comment")
            }.navigationTitle("Review comment").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
