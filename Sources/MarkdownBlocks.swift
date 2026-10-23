import Foundation

/// Block structure used by the native transcript renderer.
///
/// This is a deliberately small, line-oriented subset of CommonMark/GFM aimed at
/// model replies: ATX and setext headings, paragraphs, fenced code (``` and ~~~,
/// including an unterminated fence while a reply is still streaming), bullet,
/// ordered and task lists nested by indentation, block quotes, thematic breaks and
/// simple pipe tables. It is not a complete CommonMark or GFM implementation.
/// Indented (4-space) code blocks, HTML blocks, link reference definitions,
/// footnotes and many precedence edge cases are rendered as ordinary paragraph
/// text instead.
indirect enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String, closed: Bool)
    case list(MarkdownList)
    case quote([MarkdownBlock])
    case table(MarkdownTable)
    case rule
}

struct MarkdownList: Equatable {
    var ordered: Bool
    /// First ordinal of an ordered list (CommonMark keeps the author's start number).
    var start: Int
    var items: [MarkdownListItem]
}

struct MarkdownListItem: Equatable {
    /// `nil` for an ordinary item; otherwise the GFM task checkbox state.
    var checked: Bool?
    var blocks: [MarkdownBlock]
}

enum MarkdownTableAlignment: Equatable { case leading, center, trailing }

struct MarkdownTable: Equatable {
    var header: [String]
    var alignments: [MarkdownTableAlignment]
    /// Every row is normalized to `header.count` cells.
    var rows: [[String]]
}

enum MarkdownParser {
    /// Quote/list nesting deeper than this is flattened to text, bounding recursion.
    static let maxNesting = 8

    static func parse(_ text: String) -> [MarkdownBlock] {
        // "\r\n" is one Character in Swift, so test the UTF-8 code unit.
        let normalized = text.utf8.contains(13) ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : text
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { expandLeadingTabs(String($0)) }
        return parse(lines: lines, depth: 0)
    }

    // MARK: Block loop

    private static func parse(lines: [String], depth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraphText(paragraph))); paragraph = [] }
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { flush(); i += 1; continue }
            if let fence = openingFence(line) {
                flush()
                var code: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    if closes(lines[i], fence) { closed = true; i += 1; break }
                    code.append(dropIndent(lines[i], fence.indent))
                    i += 1
                }
                blocks.append(.code(language: fence.language, code: code.joined(separator: "\n"), closed: closed))
                continue
            }
            if let heading = atxHeading(line) {
                flush()
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }
            if !paragraph.isEmpty, let level = setextLevel(line) {
                blocks.append(.heading(level: level, text: paragraphText(paragraph)))
                paragraph = []
                i += 1
                continue
            }
            if isRule(line) { flush(); blocks.append(.rule); i += 1; continue }
            if quoteContent(line) != nil {
                flush()
                var inner: [String] = []
                while i < lines.count {
                    if let content = quoteContent(lines[i]) {
                        inner.append(content)
                    } else if !isBlank(lines[i]), let last = inner.last, !isBlank(last), !startsBlock(lines[i]) {
                        inner.append(lines[i]) // lazy paragraph continuation
                    } else { break }
                    i += 1
                }
                blocks.append(.quote(nested(inner, depth)))
                continue
            }
            if let marker = listMarker(line), paragraph.isEmpty || interrupts(marker) {
                flush()
                blocks.append(.list(parseList(lines, &i, first: marker, depth: depth)))
                continue
            }
            if let alignments = tableStart(lines, i) {
                flush()
                blocks.append(.table(parseTable(lines, &i, alignments: alignments)))
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    private static func nested(_ lines: [String], _ depth: Int) -> [MarkdownBlock] {
        if depth + 1 >= maxNesting {
            let text = paragraphText(lines.filter { !isBlank($0) })
            return text.isEmpty ? [] : [.paragraph(text)]
        }
        return parse(lines: lines, depth: depth + 1)
    }

    // MARK: Lists

    private struct ListMarker {
        let ordered: Bool
        let number: Int
        let indent: Int
        let contentIndent: Int
        let content: String
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = indentOf(line)
        let rest = line.dropFirst(indent)
        guard let first = rest.first else { return nil }
        var ordered = false
        var number = 1
        let width: Int
        if first == "-" || first == "*" || first == "+" {
            width = 1
        } else if first.isASCII && first.isNumber {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard digits.count <= 9, let delimiter = rest.dropFirst(digits.count).first, delimiter == "." || delimiter == ")" else { return nil }
            ordered = true
            number = Int(digits) ?? 1
            width = digits.count + 1
        } else { return nil }
        let after = rest.dropFirst(width)
        if after.isEmpty { return ListMarker(ordered: ordered, number: number, indent: indent, contentIndent: indent + width + 1, content: "") }
        guard after.first == " " || after.first == "\t" else { return nil }
        let spaces = after.prefix { $0 == " " || $0 == "\t" }.count
        let pad = (1...4).contains(spaces) ? spaces : 1
        let content = String(after.dropFirst(spaces))
        return ListMarker(ordered: ordered, number: number, indent: indent, contentIndent: indent + width + pad, content: content)
    }

    /// CommonMark: only a non-empty bullet item, or an ordered item starting at 1, interrupts a paragraph.
    private static func interrupts(_ marker: ListMarker) -> Bool {
        !marker.content.trimmingCharacters(in: .whitespaces).isEmpty && (!marker.ordered || marker.number == 1)
    }

    private static func parseList(_ lines: [String], _ i: inout Int, first: ListMarker, depth: Int) -> MarkdownList {
        var items: [MarkdownListItem] = []
        var marker = first
        while true {
            var itemLines = [marker.content]
            // Lenient for model output: a fence opened inside an item runs to its
            // closing fence even when the code or the fence is under-indented.
            var openFence = openingFence(marker.content)
            var previousBlank = false
            i += 1
            while i < lines.count {
                let line = lines[i]
                let indent = indentOf(line)
                if let fence = openFence {
                    let content = dropIndent(line, min(indent, marker.contentIndent))
                    itemLines.append(content)
                    if closes(content, fence) { openFence = nil }
                    i += 1
                    continue
                }
                if isBlank(line) {
                    var j = i
                    while j < lines.count, isBlank(lines[j]) { j += 1 }
                    guard j < lines.count, indentOf(lines[j]) >= marker.contentIndent else { break }
                    itemLines.append(contentsOf: Array(repeating: "", count: j - i))
                    i = j
                    previousBlank = true
                    continue
                }
                var content: String?
                if indent >= marker.contentIndent {
                    content = dropIndent(line, marker.contentIndent)
                } else if listMarker(line) != nil {
                    if indent > marker.indent { content = dropIndent(line, indent) } // under-indented child list
                } else if !previousBlank && !startsBlock(line) {
                    content = dropIndent(line, indent) // lazy paragraph continuation
                }
                guard let content else { break }
                itemLines.append(content)
                if openingFence(content) != nil { openFence = openingFence(content) }
                previousBlank = false
                i += 1
            }
            let task = taskState(itemLines[0])
            itemLines[0] = task.text
            items.append(MarkdownListItem(checked: task.checked, blocks: nested(itemLines, depth)))
            var j = i
            while j < lines.count, isBlank(lines[j]) { j += 1 }
            guard j < lines.count, let next = listMarker(lines[j]), next.ordered == first.ordered, next.indent < marker.contentIndent else { break }
            i = j
            marker = next
        }
        return MarkdownList(ordered: first.ordered, start: first.number, items: items)
    }

    private static func taskState(_ text: String) -> (checked: Bool?, text: String) {
        for (prefix, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] where text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count)
            if rest.isEmpty { return (checked, "") }
            if rest.first == " " || rest.first == "\t" { return (checked, String(rest.dropFirst())) }
        }
        return (nil, text)
    }

    // MARK: Tables

    private static func tableStart(_ lines: [String], _ i: Int) -> [MarkdownTableAlignment]? {
        guard i + 1 < lines.count, indentOf(lines[i]) <= 3, lines[i].contains("|"),
              let alignments = delimiterRow(lines[i + 1]), tableCells(lines[i]).count == alignments.count else { return nil }
        return alignments
    }

    private static func parseTable(_ lines: [String], _ i: inout Int, alignments: [MarkdownTableAlignment]) -> MarkdownTable {
        let header = tableCells(lines[i])
        var rows: [[String]] = []
        i += 2
        while i < lines.count, !isBlank(lines[i]), lines[i].contains("|"), !startsBlock(lines[i]) {
            var cells = tableCells(lines[i])
            if cells.count > header.count { cells.removeLast(cells.count - header.count) }
            while cells.count < header.count { cells.append("") }
            rows.append(cells)
            i += 1
        }
        return MarkdownTable(header: header, alignments: alignments, rows: rows)
    }

    private static func delimiterRow(_ line: String) -> [MarkdownTableAlignment]? {
        guard line.contains("|"), indentOf(line) <= 3 else { return nil }
        var result: [MarkdownTableAlignment] = []
        for cell in tableCells(line) {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(left && right ? .center : right ? .trailing : .leading)
        }
        return result.isEmpty ? nil : result
    }

    /// Splits a GFM pipe row. `\|` is a literal pipe; pipes inside code spans must be escaped, as in GFM.
    private static func tableCells(_ line: String) -> [String] {
        var row = Substring(line.trimmingCharacters(in: .whitespaces))
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row = row.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in row {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Line classification

    private struct Fence {
        let marker: Character
        let length: Int
        let indent: Int
        let language: String?
    }

    private static func openingFence(_ line: String) -> Fence? {
        let indent = indentOf(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if marker == "`" && info.contains("`") { return nil }
        let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
        return Fence(marker: marker, length: length, indent: indent, language: language)
    }

    private static func closes(_ line: String, _ fence: Fence) -> Bool {
        let indent = indentOf(line)
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        let run = rest.prefix { $0 == fence.marker }.count
        return run >= fence.length && rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        let indent = indentOf(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        if let last = text.lastIndex(where: { $0 != "#" }) {
            if text.index(after: last) < text.endIndex, text[last] == " " || text[last] == "\t" {
                text = String(text[...last]).trimmingCharacters(in: .whitespaces)
            }
        } else {
            text = ""
        }
        return (level, text)
    }

    /// Setext underline. Requires at least two characters so a lone `-` typed while
    /// streaming a list does not flash the previous paragraph as a heading.
    private static func setextLevel(_ line: String) -> Int? {
        guard indentOf(line) <= 3 else { return nil }
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, let first = text.first, first == "=" || first == "-", text.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    private static func isRule(_ line: String) -> Bool {
        guard indentOf(line) <= 3 else { return false }
        var marker: Character?
        var count = 0
        for character in line where character != " " && character != "\t" {
            guard character == "-" || character == "*" || character == "_" else { return false }
            if let marker, marker != character { return false }
            marker = character
            count += 1
        }
        return count >= 3
    }

    private static func quoteContent(_ line: String) -> String? {
        let indent = indentOf(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard rest.first == ">" else { return nil }
        var body = rest.dropFirst()
        if body.first == " " { body = body.dropFirst() }
        return String(body)
    }

    private static func startsBlock(_ line: String) -> Bool {
        if openingFence(line) != nil || atxHeading(line) != nil || isRule(line) || quoteContent(line) != nil { return true }
        if let marker = listMarker(line), interrupts(marker) { return true }
        return false
    }

    // MARK: Text helpers

    private static func paragraphText(_ lines: [String]) -> String {
        lines.enumerated().map { index, line in
            var text = line.trimmingCharacters(in: .whitespaces)
            if index < lines.count - 1, text.hasSuffix("\\"), !text.hasSuffix("\\\\") { text.removeLast() } // hard break
            return text
        }.joined(separator: "\n")
    }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func indentOf(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    private static func dropIndent(_ line: String, _ count: Int) -> String {
        String(line.dropFirst(min(count, indentOf(line))))
    }

    private static func expandLeadingTabs(_ line: String) -> String {
        var columns = 0
        var index = line.startIndex
        var sawTab = false
        while index < line.endIndex {
            let character = line[index]
            if character == " " { columns += 1 }
            else if character == "\t" { columns += 4 - columns % 4; sawTab = true }
            else { break }
            index = line.index(after: index)
        }
        return sawTab ? String(repeating: " ", count: columns) + line[index...] : line
    }
}

/// Inline Markdown (emphasis, strong, code spans, strikethrough, links) through
/// Foundation's parser, with link safety applied afterwards.
enum MarkdownInline {
    /// Only absolute http(s) URLs with a host and no embedded credentials are tappable.
    static func safeLink(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { return nil }
        return url
    }

    /// Parses inline syntax only; newlines are preserved as line breaks.
    /// Unsafe or relative links become plain text. Images are never fetched: they
    /// become their alt text (or "Image"), linked only when the image URL is safe.
    /// Bare `http://`/`https://` URLs outside code spans are linked.
    static func attributed(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var text = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        sanitize(&text)
        if source.range(of: "http", options: .caseInsensitive) != nil { autolink(&text) }
        return text
    }

    private static func sanitize(_ text: inout AttributedString) {
        var unsafeLinks: [Range<AttributedString.Index>] = []
        var images: [(range: Range<AttributedString.Index>, url: URL?)] = []
        for run in text.runs {
            if let image = run.imageURL { images.append((run.range, image)) }
            else if let link = run.link, safeLink(link) == nil { unsafeLinks.append(run.range) }
        }
        for range in unsafeLinks { text[range].link = nil }
        // Replace back to front so earlier ranges stay valid.
        for image in images.reversed() {
            var replacement = AttributedString(text[image.range])
            replacement.imageURL = nil
            replacement.link = safeLink(image.url)
            if replacement.characters.allSatisfy({ $0.isWhitespace }) {
                var label = AttributedString("Image")
                label.link = replacement.link
                replacement = label
            }
            text.replaceSubrange(image.range, with: replacement)
        }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func autolink(_ text: inout AttributedString) {
        guard let detector else { return }
        let plain = String(text.characters)
        let nsPlain = plain as NSString
        for match in detector.matches(in: plain, range: NSRange(location: 0, length: nsPlain.length)) {
            let literal = nsPlain.substring(with: match.range).lowercased()
            guard literal.hasPrefix("http://") || literal.hasPrefix("https://"), let url = safeLink(match.url),
                  let range = Range(match.range, in: text) else { continue }
            let occupied = text[range].runs.contains { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }
            if !occupied { text[range].link = url }
        }
    }
}
