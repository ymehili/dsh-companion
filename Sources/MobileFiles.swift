import SwiftUI
import UIKit
import QuickLook

/// Read-only, session-scoped Files entry. The caller owns the NavigationStack.
struct MobileFiles: View {
    let sessionId: String
    @Environment(NativeStore.self) private var store
    @State private var service: MobileFilesService?
    @State private var issue: String?
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 17
    private var cwd: String { store.sessions.first(where: { $0.id == sessionId })?.cwd ?? "" }
    private var project: String { store.workspaceState.title(for: sessionId, cwd: cwd) }
    var body: some View {
        Group {
            if let service { MobileFilesBrowser(service: service) }
            else if let issue { MobileFilesNotice(message: issue) { prepare() } }
            else { ProgressView("Loading files…") }
        }
        .background(MobileSurface.sheet)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text("Files").font(.system(size: titleSize, weight: .semibold))
                    Text(project).font(.caption).foregroundStyle(DSHTheme.secondary).lineLimit(1)
                }.accessibilityElement(children: .combine)
            }
        }
        .task(id: sessionId) { prepare() }
        .accessibilityIdentifier("mobile-files")
    }
    private func prepare() {
        // Popping a document remounts the route task. Keep the same authorized
        // listing chain while its browser state/destination entries survive.
        if service?.sessionId == sessionId { return }
        issue = nil; service = nil
        do {
            if store.usesFixture {
                service = try MobileFilesService(sessionId: sessionId, workspaceRoot: MobileFilesFixtureTransport.root, transport: MobileFilesFixtureTransport(), byteCodec: MobileFilesFixtureTransport.codec)
            } else {
                guard store.sessions.contains(where: { $0.id == sessionId }) else { throw MobileFileFailure.boundary }
                service = try MobileFilesService(sessionId: sessionId, workspaceRoot: cwd, transport: store.gateway, byteCodec: .nativeMultipart)
            }
        } catch { issue = error.localizedDescription }
    }
}

private struct MobileFilesBrowser: View {
    let service: MobileFilesService
    @State private var path = ""
    @State private var query = ""
    @State private var listing: MobileFileListing?
    @State private var busy = false
    @State private var issue: String?
    @State private var generation = UUID()
    private var entries: [MobileFileEntry] {
        (listing?.entries ?? []).filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }
    }
    private var crumbs: [String] {
        let parts = path.split(separator: "/")
        return (1...max(1, parts.count)).compactMap { count in parts.isEmpty ? nil : parts.prefix(count).joined(separator: "/") }
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button("Workspace") { navigate("") }.frame(minHeight: 44)
                    ForEach(crumbs, id: \.self) { crumb in
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(DSHTheme.tertiary)
                        Button(crumb.split(separator: "/").last.map(String.init) ?? crumb) { navigate(crumb) }.frame(minHeight: 44)
                    }
                }.padding(.horizontal, 17.5)
            }.accessibilityIdentifier("files-breadcrumbs")
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(DSHTheme.secondary)
                TextField("Filter filename or path", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("files-search")
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }.accessibilityLabel("Clear file search") }
            }.padding(.horizontal, 14).frame(minHeight: 49).background(MobileSurface.card, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 17.5)
            Text("Filename/path filter · current folder only").font(.caption).foregroundStyle(DSHTheme.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 7)
            if busy { ProgressView("Loading folder…").padding() }
            if let issue { MobileFilesNotice(message: issue) { Task { await load() } } }
            else if let listing {
                List {
                    if listing.truncated { Text("This folder is truncated by the listing limit. Some entries are not shown.").font(.footnote).foregroundStyle(DSHTheme.statusAttention) }
                    if entries.isEmpty { Text(query.isEmpty ? "This folder is empty." : "No matching entries in this folder.").foregroundStyle(DSHTheme.secondary) }
                    ForEach(entries) { entry in
                        if entry.kind == .directory {
                            Button { navigate(entry.path) } label: { fileRow(entry) }.buttonStyle(.plain)
                        } else if entry.kind == .file {
                            NavigationLink { MobileFilesDocument(service: service, entry: entry) } label: { fileRow(entry) }
                        } else {
                            fileRow(entry).opacity(0.55).accessibilityLabel("\(entry.name), unsupported file kind, unavailable")
                        }
                    }
                    Text("Read-only. Editing, renaming and deleting require a host file-write API. Symlinks may be refused. Search does not inspect file contents.")
                        .font(.footnote).foregroundStyle(DSHTheme.secondary).listRowBackground(Color.clear)
                }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
            }
            Spacer(minLength: 0)
        }
        .background(MobileSurface.sheet)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44) }
                    .disabled(busy).accessibilityLabel("Refresh files").accessibilityIdentifier("files-refresh")
            }
        }
        .task(id: path) { await load() }
    }
    private func fileRow(_ entry: MobileFileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind == .directory ? "folder" : (entry.kind == .other ? "exclamationmark.link" : (entry.previewable ? "doc.richtext" : "doc.text"))).foregroundStyle(DSHTheme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.body).foregroundStyle(DSHTheme.label)
                if let size = entry.size { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(DSHTheme.secondary) }
            }
            Spacer()
            if entry.kind == .directory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(DSHTheme.tertiary) }
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
    private func navigate(_ value: String) {
        guard value != path else { return }
        generation = UUID(); path = value; query = ""; listing = nil; issue = nil
    }
    private func load() async {
        let token = UUID(); generation = token; busy = true; issue = nil
        defer { if token == generation { busy = false } }
        do {
            let result = try await service.list(path)
            try Task.checkCancellation()
            guard token == generation else { return }
            listing = result
        } catch is CancellationError { }
        catch { guard token == generation else { return }; listing = nil; issue = error.localizedDescription }
    }
}

private struct MobileFilesNotice: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.document").font(.title2).foregroundStyle(DSHTheme.statusAttention)
            Text(message).font(.body).foregroundStyle(DSHTheme.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            Button("Retry", action: retry).frame(minWidth: 88, minHeight: 44).buttonStyle(.bordered)
        }.padding(24).frame(maxWidth: .infinity).accessibilityIdentifier("files-error")
    }
}

private struct MobileFilesDocument: View {
    let service: MobileFilesService
    let entry: MobileFileEntry
    @State private var identity: MobileFileIdentity?
    @State private var page: MobileFileTextPage?
    @State private var history: [Int] = []
    @State private var media: MobileFilesTemporaryPreview?
    @State private var busy = false
    @State private var issue: String?
    @State private var generation = UUID()
    var body: some View {
        VStack(spacing: 10) {
            Text(entry.path).font(.caption).foregroundStyle(DSHTheme.secondary).textSelection(.enabled).padding(.horizontal)
            if busy { ProgressView("Loading authorized file…").padding() }
            if let issue { MobileFilesNotice(message: issue) { Task { await reload() } } }
            if let media, issue == nil {
                MobileFilesQuickLook(url: media.url).accessibilityIdentifier("files-native-preview")
            } else if let page, issue == nil {
                HStack {
                    Button("Previous") {
                        guard let previous = history.popLast() else { return }
                        Task { await loadText(offset: previous) }
                    }.disabled(history.isEmpty || busy).frame(minHeight: 44)
                    Spacer()
                    Text(page.lines == 0 ? "Empty file" : "Lines \(page.offset)–\(page.offset + page.lines - 1)").font(.caption).foregroundStyle(DSHTheme.secondary)
                    Spacer()
                    Button("Next") {
                        history.append(page.offset)
                        Task { await loadText(offset: page.nextOffset) }
                    }.disabled(page.eof || busy).frame(minHeight: 44)
                }.padding(.horizontal)
                MobileFilesSourceView(text: page.text, offset: page.offset, lines: page.lines).accessibilityIdentifier("files-source")
                if !page.eof { Text("Partial preview · load the next page for more.").font(.footnote).foregroundStyle(DSHTheme.statusAttention) }
            }
            Spacer(minLength: 0)
        }
        .background(DSHTheme.canvas)
        .navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.disabled(busy).accessibilityLabel("Reload file")
            }
        }
        .task { await reload() }
        .onDisappear { generation = UUID(); media = nil }
    }
    private func reload() async {
        let token = UUID(); generation = token; busy = true; issue = nil; media = nil; page = nil; history = []
        defer { if generation == token { busy = false } }
        do {
            let source = try await service.stat(entry)
            guard generation == token else { return }; identity = source
            if entry.previewable {
                let bytes = try await service.media(entry, identity: source)
                try Task.checkCancellation()
                guard generation == token else { return }
                media = try MobileFilesTemporaryPreview(data: bytes, name: entry.name)
            } else {
                let result = try await service.text(entry, offset: 1, identity: source)
                try Task.checkCancellation(); guard generation == token else { return }; page = result
            }
        } catch is CancellationError { }
        catch { if generation == token { issue = error.localizedDescription } }
    }
    private func loadText(offset: Int) async {
        guard let identity else { return }
        let token = UUID(); generation = token; busy = true; issue = nil
        defer { if generation == token { busy = false } }
        do {
            let result = try await service.text(entry, offset: offset, identity: identity)
            try Task.checkCancellation(); guard generation == token else { return }; page = result
        } catch is CancellationError { }
        catch { if generation == token { issue = error.localizedDescription } }
    }
}

/// A private cache created only from authorized bytes, never a host path or URL.
@MainActor
private final class MobileFilesTemporaryPreview {
    let url: URL
    private let directory: URL
    init(data: Data, name: String) throws {
        guard MobileFilePath.name(name), !data.isEmpty else { throw MobileFileFailure.malformed }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DSH-Files-" + UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            guard QLPreviewController.canPreview(url as NSURL) else {
                throw MobileFileFailure(message: "iOS cannot preview this file format. No external URL was opened.")
            }
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

private struct MobileFilesQuickLook: UIViewControllerRepresentable {
    let url: URL
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; controller.reloadData() }
    }
}

private struct MobileFilesSourceView: UIViewRepresentable {
    let text: String
    let offset: Int
    let lines: Int
    func makeUIView(context: Context) -> MobileFilesNumberedTextView {
        let view = MobileFilesNumberedTextView()
        view.isEditable = false; view.isSelectable = true; view.alwaysBounceVertical = true
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear; view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 12, left: 66, bottom: 12, right: 14)
        view.accessibilityLabel = "Read-only source. Select text to copy."
        return view
    }
    func updateUIView(_ view: MobileFilesNumberedTextView, context: Context) {
        let changed = view.text != text || view.firstLine != offset
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 14, weight: .regular))
        view.font = font
        let lastLabel = "\(offset + max(0, lines - 1))" as NSString
        let gutter = max(44, lastLabel.size(withAttributes: [.font: font]).width + 24)
        view.textContainerInset = UIEdgeInsets(top: 12, left: gutter, bottom: 12, right: 14)
        view.firstLine = offset; view.sourceLines = lines
        if changed { view.text = text; view.setContentOffset(.zero, animated: false) }
        view.setNeedsDisplay()
    }
}

private final class MobileFilesNumberedTextView: UITextView {
    var firstLine = 1
    var sourceLines = 0
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard sourceLines > 0, let font else { return }
        let nsText = (text ?? "") as NSString
        var number = firstLine
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { [self] _, used, _, glyphRange, _ in
            let character = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            guard character == 0 || nsText.substring(with: NSRange(location: character - 1, length: 1)) == "\n" else { return }
            let label = "\(number)" as NSString
            let width = label.size(withAttributes: attributes).width
            label.draw(at: CGPoint(x: textContainerInset.left - width - 12, y: textContainerInset.top + used.minY), withAttributes: attributes)
            number += 1
        }
        if nsText.length == 0 { ("\(firstLine)" as NSString).draw(at: CGPoint(x: 12, y: textContainerInset.top), withAttributes: attributes) }
    }
}
