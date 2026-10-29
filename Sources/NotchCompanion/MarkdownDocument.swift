import Foundation

/// A small, deterministic block parser for chat responses. Inline styling is
/// handled by AttributedString in the view; no HTML or remote content is loaded.
/// Source-line identities keep completed blocks stable while a response streams.
struct MarkdownBlock: Identifiable, Equatable {
    let id: String
    let content: Content

    indirect enum Content: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case code(language: String?, text: String)
        case list(ordered: Bool, items: [MarkdownListItem])
        case quote([MarkdownBlock])
        case rule
    }
}

struct MarkdownListItem: Identifiable, Equatable {
    let id: String
    let number: Int?
    let blocks: [MarkdownBlock]
}

enum MarkdownDocument {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").enumerated().map { Line(text: $0.element, source: $0.offset) }
        return parse(lines, depth: 0)
    }

    private struct Line {
        var text: String
        let source: Int
        var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
        var isBlank: Bool { trimmed.isEmpty }
        var indent: Int { text.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } }

        func droppingIndent(_ width: Int) -> Line {
            var remaining = text[...]
            var removed = 0
            while removed < width, let first = remaining.first, first == " " || first == "\t" {
                removed += first == "\t" ? 4 : 1
                remaining.removeFirst()
            }
            return Line(text: String(repeating: " ", count: max(0, removed - width)) + remaining, source: source)
        }
    }

    private struct Fence {
        let marker: Character
        let count: Int
        let info: String
    }

    private struct ListMarker {
        let number: Int?
        let indent: Int
        let contentIndent: Int
        let text: String
        var ordered: Bool { number != nil }
    }

    private static func parse(_ lines: [Line], depth: Int) -> [MarkdownBlock] {
        guard depth < 16 else {
            return lines.first.map { [MarkdownBlock(id: "line:\($0.source):paragraph", content: .paragraph(lines.map(\.text).joined(separator: "\n")))] } ?? []
        }
        var blocks: [MarkdownBlock] = []
        var index = 0
        func append(_ content: MarkdownBlock.Content, kind: String, source: Int) {
            blocks.append(MarkdownBlock(id: "line:\(source):\(kind)", content: content))
        }

        while index < lines.count {
            let line = lines[index]
            if line.isBlank { index += 1; continue }
            if let opener = fence(line) {
                index += 1
                var body: [String] = []
                while index < lines.count, !closesFence(lines[index], opener: opener) {
                    body.append(lines[index].droppingIndent(line.indent).text)
                    index += 1
                }
                if index < lines.count { index += 1 }
                let language = opener.info.split(whereSeparator: \.isWhitespace).first.map(String.init)
                append(.code(language: language, text: body.joined(separator: "\n")), kind: "code", source: line.source)
                continue
            }
            if let heading = heading(line) {
                append(.heading(level: heading.level, text: heading.text), kind: "heading", source: line.source)
                index += 1
                continue
            }
            if isRule(line) {
                append(.rule, kind: "rule", source: line.source)
                index += 1
                continue
            }
            if quoteText(line) != nil {
                var quoted: [Line] = []
                while index < lines.count {
                    if let text = quoteText(lines[index]) {
                        quoted.append(Line(text: text, source: lines[index].source))
                        index += 1
                    } else if lines[index].isBlank, index + 1 < lines.count, quoteText(lines[index + 1]) != nil {
                        quoted.append(lines[index]); index += 1
                    } else { break }
                }
                append(.quote(parse(quoted, depth: depth + 1)), kind: "quote", source: line.source)
                continue
            }
            if let first = listMarker(line), first.indent <= 3 {
                var items: [MarkdownListItem] = []
                while index < lines.count, let marker = listMarker(lines[index]), marker.indent == first.indent, marker.ordered == first.ordered {
                    let itemSource = lines[index].source
                    var itemLines = [Line(text: marker.text, source: itemSource)]
                    index += 1
                    while index < lines.count {
                        let next = lines[index]
                        if next.isBlank { itemLines.append(next); index += 1; continue }
                        if next.indent >= marker.contentIndent {
                            itemLines.append(next.droppingIndent(marker.contentIndent)); index += 1
                        } else if let sibling = listMarker(next), sibling.indent <= first.indent { break }
                        else if itemLines.last?.isBlank == true || startsBlock(next) { break }
                        else {
                            // Markdown permits unindented continuation text inside a list item.
                            itemLines.append(Line(text: next.trimmed, source: next.source)); index += 1
                        }
                    }
                    items.append(MarkdownListItem(id: "line:\(itemSource):item", number: marker.number, blocks: parse(itemLines, depth: depth + 1)))
                }
                append(.list(ordered: first.ordered, items: items), kind: "list", source: line.source)
                continue
            }

            var paragraph = [line.text]
            index += 1
            var setextLevel: Int?
            while index < lines.count, !lines[index].isBlank {
                if let level = setextHeading(lines[index]) { setextLevel = level; index += 1; break }
                if startsBlock(lines[index]) { break }
                paragraph.append(lines[index].text)
                index += 1
            }
            let text = paragraph.joined(separator: "\n")
            if let setextLevel { append(.heading(level: setextLevel, text: text), kind: "heading", source: line.source) }
            else { append(.paragraph(text), kind: "paragraph", source: line.source) }
        }
        return blocks
    }

    private static func startsBlock(_ line: Line) -> Bool {
        fence(line) != nil || heading(line) != nil || isRule(line) || quoteText(line) != nil || (listMarker(line).map { $0.indent <= 3 } ?? false)
    }

    private static func fence(_ line: Line) -> Fence? {
        guard line.indent <= 3, let marker = line.trimmed.first, marker == "`" || marker == "~" else { return nil }
        let count = line.trimmed.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        let info = String(line.trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        guard marker != "`" || !info.contains("`") else { return nil }
        return Fence(marker: marker, count: count, info: info)
    }

    private static func closesFence(_ line: Line, opener: Fence) -> Bool {
        guard line.indent <= 3 else { return false }
        let count = line.trimmed.prefix { $0 == opener.marker }.count
        return count >= opener.count && line.trimmed.dropFirst(count).isEmpty
    }

    private static func heading(_ line: Line) -> (level: Int, text: String)? {
        guard line.indent <= 3 else { return nil }
        let trimmed = line.trimmed
        let count = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(count) else { return nil }
        let rest = trimmed.dropFirst(count)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        let withoutHashes = text.dropLast(text.reversed().prefix { $0 == "#" }.count)
        if withoutHashes.last?.isWhitespace == true { text = withoutHashes.trimmingCharacters(in: .whitespaces) }
        return (count, text)
    }

    private static func setextHeading(_ line: Line) -> Int? {
        guard line.indent <= 3, let first = line.trimmed.first, first == "=" || first == "-", line.trimmed.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    private static func isRule(_ line: Line) -> Bool {
        guard line.indent <= 3 else { return false }
        let symbols = line.trimmed.filter { !$0.isWhitespace }
        guard symbols.count >= 3, let first = symbols.first, ["-", "*", "_"].contains(first) else { return false }
        return symbols.allSatisfy { $0 == first }
    }

    private static func quoteText(_ line: Line) -> String? {
        guard line.indent <= 3 else { return nil }
        var text = line.text.drop { $0 == " " || $0 == "\t" }
        guard text.first == ">" else { return nil }
        text.removeFirst()
        if text.first == " " { text.removeFirst() }
        return String(text)
    }

    private static func listMarker(_ line: Line) -> ListMarker? {
        var remaining = line.text.drop { $0 == " " || $0 == "\t" }
        var number: Int?
        var markerWidth = 1
        if let first = remaining.first, ["-", "*", "+"].contains(first) {
            remaining.removeFirst()
        } else {
            let digits = remaining.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            remaining = remaining.dropFirst(digits.count)
            guard remaining.first == "." || remaining.first == ")" else { return nil }
            remaining.removeFirst()
            number = Int(digits)
            markerWidth = digits.count + 1
        }
        guard remaining.isEmpty || remaining.first?.isWhitespace == true else { return nil }
        let spaces = remaining.prefix { $0 == " " || $0 == "\t" }
        let padding = spaces.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        // One to four spaces are marker padding; a wider gap belongs to the text.
        let consumed = padding > 4 ? 1 : max(1, padding)
        let content = Line(text: String(remaining), source: line.source).droppingIndent(consumed).text
        return ListMarker(number: number, indent: line.indent, contentIndent: line.indent + markerWidth + consumed, text: content)
    }
}
