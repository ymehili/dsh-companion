import SwiftUI
import UIKit

/// Native Markdown for transcript text: headings, paragraphs, lists, quotes,
/// rules, simple tables and fenced code with a Copy button. Inline emphasis,
/// code spans and safe http(s) links come from `MarkdownInline`. No web view, no
/// remote image loading. This is a small subset, not full CommonMark/GFM.
///
/// `streaming` marks text that changes every frame: parse results are not cached
/// and an unterminated trailing fence still renders as code.
///
/// Body text inherits the caller's foreground style, so `.foregroundStyle(.secondary)`
/// on reasoning/context works. Links, code, quotes, markers and rules use DSHTheme.
struct NativeMarkdown: View, Equatable {
    let text: String
    var streaming: Bool = false

    init(text: String, streaming: Bool = false) {
        self.text = text
        self.streaming = streaming
    }

    var body: some View {
        NativeMarkdownBlocks(blocks: NativeMarkdownCache.blocks(for: text, cache: !streaming), cacheable: !streaming, listDepth: 0, spacing: 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tint(DSHTheme.accent)
            .environment(\.openURL, OpenURLAction { url in
                MarkdownInline.safeLink(url) == nil ? .discarded : .systemAction
            })
    }
}

/// Internal (not private) only so `NativeAssistantMarkdown` can render the
/// Markdown runs around assistant OpenUI cards with identical styling.
struct NativeMarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    let cacheable: Bool
    let listDepth: Int
    let spacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { item in
                NativeMarkdownBlock(block: item.element, cacheable: cacheable, listDepth: listDepth).equatable()
            }
        }
    }
}

private struct NativeMarkdownBlock: View, Equatable {
    let block: MarkdownBlock
    let cacheable: Bool
    let listDepth: Int

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(NativeMarkdownCache.inline(text, cache: cacheable))
                .font(.callout)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            Text(NativeMarkdownCache.inline(text, cache: cacheable))
                .font(Self.headingFont(level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)
        case .code(let language, let code, _):
            NativeCodeBlock(language: language, code: code)
        case .list(let list):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(list: list, index: index, item: item)
                        NativeMarkdownBlocks(blocks: item.blocks, cacheable: cacheable, listDepth: listDepth + 1, spacing: 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .quote(let blocks):
            NativeMarkdownBlocks(blocks: blocks, cacheable: cacheable, listDepth: listDepth, spacing: 10)
                .foregroundStyle(DSHTheme.secondary)
                .padding(.leading, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(DSHTheme.separator).frame(width: 3)
                }
        case .table(let table):
            NativeMarkdownTable(table: table, cacheable: cacheable)
        case .rule:
            Rectangle().fill(DSHTheme.separator).frame(height: 1).padding(.vertical, 6)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func marker(list: MarkdownList, index: Int, item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.callout)
                .foregroundStyle(checked ? DSHTheme.accent : DSHTheme.secondary)
                .accessibilityLabel(checked ? "Completed" : "Not completed")
        } else if list.ordered {
            Text("\(list.start + index).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(DSHTheme.secondary)
                .frame(minWidth: 18, alignment: .trailing)
        } else {
            Text(["•", "◦", "▪︎"][listDepth % 3])
                .font(.callout)
                .foregroundStyle(DSHTheme.secondary)
                .accessibilityHidden(true)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        case 3: return .headline
        default: return .callout.weight(.semibold)
        }
    }
}

/// Fenced code: horizontally scrollable, selectable, with a native Copy button.
struct NativeCodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(DSHTheme.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(DSHTheme.secondary)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 34)
            Rectangle().fill(DSHTheme.separator).frame(height: 0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(DSHTheme.label)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
        }
        .background(DSHTheme.hover, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DSHTheme.separator, lineWidth: 0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeMarkdownTable: View, Equatable {
    let table: MarkdownTable
    let cacheable: Bool
    @ScaledMetric(relativeTo: .subheadline) private var characterWidth: CGFloat = 7.5

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.table == rhs.table && lhs.cacheable == rhs.cacheable }

    var body: some View {
        let widths = columnWidths()
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        cell(table.header[column], column: column, width: widths[column], header: true)
                    }
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.header.indices, id: \.self) { column in
                            cell(table.rows[row][column], column: column, width: widths[column], header: false)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DSHTheme.separator, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func cell(_ text: String, column: Int, width: CGFloat, header: Bool) -> some View {
        let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
        return Text(NativeMarkdownCache.inline(text, cache: cacheable))
            .font(header ? .subheadline.weight(.semibold) : .subheadline)
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(header ? DSHTheme.hover : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(DSHTheme.separator).frame(height: 0.5) }
            .overlay(alignment: .trailing) {
                if column < table.header.count - 1 { Rectangle().fill(DSHTheme.separator).frame(width: 0.5) }
            }
    }

    /// Estimated from visible characters (not Markdown source), clamped so wide
    /// tables scroll horizontally while long cells wrap.
    private func columnWidths() -> [CGFloat] {
        table.header.indices.map { column in
            let lengths = ([table.header[column]] + table.rows.map { $0[column] }).map {
                NativeMarkdownCache.inline($0, cache: cacheable).characters.count
            }
            return min(max(CGFloat(lengths.max() ?? 0) * characterWidth * 1.05, 44), 260)
        }
    }
}

/// Bounded parse caches for committed text; NSCache is thread-safe and evicts under memory pressure.
enum NativeMarkdownCache {
    private final class BlocksBox { let value: [MarkdownBlock]; init(_ value: [MarkdownBlock]) { self.value = value } }
    private final class InlineBox { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }

    private static let blockCache: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = 300
        cache.totalCostLimit = 8_000_000
        return cache
    }()
    private static let inlineCache: NSCache<NSString, InlineBox> = {
        let cache = NSCache<NSString, InlineBox>()
        cache.countLimit = 3000
        cache.totalCostLimit = 8_000_000
        return cache
    }()

    static func blocks(for text: String, cache: Bool) -> [MarkdownBlock] {
        guard cache else { return MarkdownParser.parse(text) }
        let key = text as NSString
        if let hit = blockCache.object(forKey: key) { return hit.value }
        let value = MarkdownParser.parse(text)
        blockCache.setObject(BlocksBox(value), forKey: key, cost: key.length)
        return value
    }

    static func inline(_ text: String, cache: Bool) -> AttributedString {
        // Foundation's inline parser costs ~0.6 ms/KB; while streaming, a huge growing
        // paragraph stays plain text and is formatted once it commits.
        guard cache else { return text.utf16.count > 6_000 ? AttributedString(text) : styled(text) }
        let key = text as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.value }
        let value = styled(text)
        inlineCache.setObject(InlineBox(value), forKey: key, cost: key.length)
        return value
    }

    /// Adds DSH colors to code spans and links produced by `MarkdownInline`.
    private static func styled(_ text: String) -> AttributedString {
        var result = MarkdownInline.attributed(text)
        var code: [Range<AttributedString.Index>] = []
        var links: [Range<AttributedString.Index>] = []
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true { code.append(run.range) }
            if run.link != nil { links.append(run.range) }
        }
        for range in code { result[range].backgroundColor = DSHTheme.hover }
        for range in links { result[range].foregroundColor = DSHTheme.accent }
        return result
    }
}
