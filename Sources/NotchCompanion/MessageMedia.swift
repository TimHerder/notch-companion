import AppKit
import ImageIO
import SwiftUI

/// A file an agent delivered in its answer: Hermes's `MEDIA:/path` tags and
/// Markdown images of local files. Only local files are shown; remote images
/// stay links so nothing is fetched without a click.
struct MessageMedia: Identifiable, Equatable {
    let url: URL
    var caption: String?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var isImage: Bool { Self.imageExtensions.contains(url.pathExtension.lowercased()) }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp"]
}

/// Display text with delivered files lifted out of it.
struct MessageContent: Equatable {
    var text: String
    var media: [MessageMedia]

    static func parse(_ source: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> MessageContent {
        guard source.contains("MEDIA:") || source.contains("![") else { return MessageContent(text: source, media: []) }
        var media: [MessageMedia] = []
        func add(_ path: String, caption: String? = nil) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if !media.contains(where: { $0.url == url }) { media.append(MessageMedia(url: url, caption: caption)) }
        }
        var lines: [String] = []
        var fence: String?
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Examples inside code blocks are not deliveries.
            if let marker = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                lines.append(line); continue
            }
            guard fence == nil else { lines.append(line); continue }
            let delivered = media.count
            var text = line
            text = liftMediaTags(text, fileExists: fileExists, add: { add($0) })
            text = liftImages(text, add: add)
            // A line that only carried a delivery leaves no gap or stray period behind.
            if media.count > delivered {
                if text.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)).isEmpty { continue }
                while text.last?.isWhitespace == true { text.removeLast() }
            }
            lines.append(text)
        }
        var text = lines.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return MessageContent(text: text.trimmingCharacters(in: .whitespacesAndNewlines), media: media)
    }

    /// One plain line for previews: the text, or the delivered file's name.
    static func preview(_ source: String) -> String {
        let content = parse(source)
        if !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return content.text }
        return content.media.first.map { "Sent \($0.name)" } ?? ""
    }

    private static let emphasis: Set<Character> = ["`", "\"", "'", "*", "_"]

    /// `MEDIA:` followed by an absolute or home path, optionally quoted or
    /// wrapped in Markdown emphasis. A path with spaces is resolved by
    /// preferring the longest candidate that exists on disk.
    private static func liftMediaTags(_ line: String, fileExists: (String) -> Bool, add: (String) -> Void) -> String {
        var output = ""
        var rest = Substring(line)
        while let tag = rest.range(of: "MEDIA:") {
            var prefix = rest[..<tag.lowerBound]
            var opening = 0
            while opening < 3, let last = prefix.last, emphasis.contains(last) { prefix.removeLast(); opening += 1 }
            var after = rest[tag.upperBound...].drop { $0 == " " || $0 == "\t" }
            var path: String?
            if let quote = after.first, ["`", "\"", "'"].contains(quote), let close = after.dropFirst().firstIndex(of: quote) {
                path = String(after[after.index(after: after.startIndex)..<close])
                after = after[after.index(after: close)...]
            } else if after.hasPrefix("/") || after.hasPrefix("~/") {
                let end = after.range(of: "MEDIA:")?.lowerBound ?? after.endIndex
                let (resolved, consumed) = resolvePath(after[..<end], fileExists: fileExists)
                path = resolved
                after = after[after.index(after.startIndex, offsetBy: consumed)...]
            }
            guard let found = path.map(expandHome), found.hasPrefix("/") else {
                output += rest[..<tag.upperBound]
                rest = rest[tag.upperBound...]
                continue
            }
            add(found)
            var closing = 0
            while closing < 3, let first = after.first, emphasis.contains(first) { after.removeFirst(); closing += 1 }
            // A sentence-final period belongs to the tag, as in Hermes.
            if after.first == ".", after.dropFirst().first?.isWhitespace ?? true { after.removeFirst() }
            output += prefix
            rest = after
        }
        return output + rest
    }

    private static func resolvePath(_ text: Substring, fileExists: (String) -> Bool) -> (String, Int) {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        var candidates: [(path: String, length: Int)] = []
        var length = 0
        for (index, word) in words.prefix(8).enumerated() {
            length += (index == 0 ? 0 : 1) + word.count
            let trimmed = trimTrailing(String(text.prefix(length)))
            if !trimmed.isEmpty { candidates.append((trimmed, trimmed.count)) }
        }
        if let existing = candidates.last(where: { fileExists(expandHome($0.path)) }) { return (existing.path, existing.length) }
        let first = candidates.first ?? (trimTrailing(String(text)), text.count)
        return (first.path, first.length)
    }

    private static func trimTrailing(_ path: String) -> String {
        var path = path
        while let last = path.last, ".,;:!?)]}".contains(last) || emphasis.contains(last) || last.isWhitespace { path.removeLast() }
        return path
    }

    private static func expandHome(_ path: String) -> String {
        path.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst()) : path
    }

    /// `![alt](/local/path)` becomes a preview. A remote image becomes a link
    /// so the transcript never loads remote content by itself.
    private static func liftImages(_ line: String, add: (String, String?) -> Void) -> String {
        guard line.contains("![") else { return line }
        let pattern = #"!\[([^\]\n]*)\]\((?:<([^>\n]+)>|([^)\s]+))(?:\s+"[^"\n]*")?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let source = line as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: line, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let alt = source.substring(with: match.range(at: 1))
            let destinationRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            let destination = source.substring(with: destinationRange)
            if let path = localPath(destination) {
                add(path, alt.isEmpty ? nil : alt)
            } else {
                output += "[\(alt.isEmpty ? "Image" : alt)](\(destination))"
            }
        }
        output += source.substring(from: cursor)
        return output
    }

    static func localPath(_ destination: String) -> String? {
        if destination.hasPrefix("file://") { return URL(string: destination)?.path }
        if destination.hasPrefix("~/") { return expandHome(destination) }
        if destination.hasPrefix("/") { return destination.removingPercentEncoding ?? destination }
        return nil
    }

    /// Where a link in an answer points. Local paths (also Codex's
    /// `/path/file.swift:42` references) open as files; relative paths resolve
    /// against the session's folder.
    static func linkDestination(_ url: URL, workspace: String?, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        if let scheme = url.scheme?.lowercased(), scheme != "file" { return url }
        var path = url.scheme == nil ? (url.relativeString.removingPercentEncoding ?? url.relativeString) : url.path
        if !path.hasPrefix("/"), !path.hasPrefix("~/"), let workspace {
            path = URL(fileURLWithPath: workspace).appendingPathComponent(path).path
        }
        path = expandHome(path)
        if !fileExists(path), let range = path.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) {
            path.removeSubrange(range)
        }
        return URL(fileURLWithPath: path)
    }
}

// MARK: - Views

/// Files delivered with an answer: image previews and file cards.
struct MessageMediaList: View {
    var media: [MessageMedia]
    var open: (URL, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(media) { item in
                if item.isImage { MediaImageView(item: item, open: open) }
                else { MediaFileCard(item: item, open: open) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MediaImageView: View {
    var item: MessageMedia
    var open: (URL, Bool) -> Void
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Button { open(item.url, false) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .frame(maxWidth: min(image.size.width, 420), maxHeight: 220, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: PanelTheme.pick(10, 10, CompanionStyle.cardRadius), style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: PanelTheme.pick(10, 10, CompanionStyle.cardRadius), style: .continuous)
                                .strokeBorder(PanelTheme.pick(Color.white.opacity(0.1), Color.white.opacity(0.1), CompanionStyle.rule), lineWidth: PanelTheme.pick(0.75, 0.75, 0.5)))
                        Text(item.caption ?? item.name).font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain).pressableCursor()
                .help("Open \(item.name)")
                .accessibilityLabel("Image \(item.caption ?? item.name). Open")
                .contextMenu { MediaMenu(item: item, open: open) }
            } else if failed {
                MediaFileCard(item: item, open: open)
            } else {
                RoundedRectangle(cornerRadius: PanelTheme.pick(10, 10, CompanionStyle.cardRadius), style: .continuous).fill(Color.white.opacity(0.05))
                    .frame(width: 160, height: 100)
                    .overlay(ProgressView().controlSize(.small))
                    .accessibilityLabel("Loading image \(item.name)")
            }
        }
        .task(id: item.url) {
            let url = item.url
            let loaded = await Task.detached(priority: .utility) { MediaThumbnail.load(url) }.value
            if let loaded { image = loaded } else { failed = true }
        }
    }
}

enum MediaThumbnail {
    /// A bounded thumbnail decoded off the main thread; never the full bitmap.
    static func load(_ url: URL, maxPixels: Int = 1_000) -> NSImage? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels
              ] as CFDictionary) else { return nil }
        // Points at 2× so a Retina preview stays sharp at its natural size.
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
}

private struct MediaFileCard: View {
    var item: MessageMedia
    var open: (URL, Bool) -> Void

    private var exists: Bool { FileManager.default.fileExists(atPath: item.url.path) }

    var body: some View {
        let available = exists
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 28, height: 28)
                .opacity(available ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if PanelTheme.current == .instrument {
                    Text(available ? detail : "File not found").font(.system(size: 11))
                        .foregroundStyle(available ? CompanionStyle.secondary : CompanionStyle.error).lineLimit(1)
                } else {
                    Text(available ? detail : "File not found").font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if available {
                Button("Open") { open(item.url, false) }.buttonStyle(NotchPillButtonStyle(small: true))
                QuietIconButton(symbol: "folder", label: "Show \(item.name) in Finder", size: 24) { open(item.url, true) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(PanelTheme.pick(CompanionStyle.surface.opacity(0.7), CompanionStyle.fill, Color.black.opacity(0.3)),
                    in: RoundedRectangle(cornerRadius: PanelTheme.pick(10, 12, CompanionStyle.cardRadius), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PanelTheme.pick(10, 12, CompanionStyle.cardRadius), style: .continuous)
            .strokeBorder(PanelTheme.pick(Color.white.opacity(0.07), Color.white.opacity(0.06), CompanionStyle.rule), lineWidth: PanelTheme.pick(0.75, 0.5, 0.5)))
        .frame(maxWidth: 420, alignment: .leading)
        .help(item.url.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(available ? "File \(item.name)" : "File \(item.name), not found")
        .contextMenu { if available { MediaMenu(item: item, open: open) } }
    }

    private var detail: String {
        let values = try? item.url.resourceValues(forKeys: [.fileSizeKey, .localizedTypeDescriptionKey])
        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [values?.localizedTypeDescription, size].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct MediaMenu: View {
    var item: MessageMedia
    var open: (URL, Bool) -> Void

    var body: some View {
        Button("Open") { open(item.url, false) }
        Button("Show in Finder") { open(item.url, true) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.path, forType: .string)
        }
    }
}
