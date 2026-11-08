import Foundation

enum FileDropDestination: Hashable {
    case session(String)
    case newSession
}

struct FileDropChoice: Equatable {
    /// The session on screen, then the most recently active others, then New
    /// session; fixed at drag entry so a selection change elsewhere cannot
    /// redirect the drop.
    let targets: [FileDropDestination]
    let currentSessionID: String?
    var fileCount: Int
    var destination: FileDropDestination?

    /// The session on screen and up to three others.
    static let sessionLimit = 4
}

/// Shared by the native drag handler and SwiftUI, in whole-notch coordinates:
/// one inset tray under the header, a title line, then one row per destination.
/// Rows meet edge to edge, so the pointer never crosses a dead gap.
struct FileDropLayout {
    let size: CGSize
    let headerHeight: CGFloat
    let rows: Int

    private var compact: Bool { size.width < 420 }
    var inset: CGFloat { compact ? 12 : 16 }
    var titleHeight: CGFloat { compact ? 26 : 30 }

    var rowHeight: CGFloat {
        let room = available.height - 2 * inset - titleHeight
        return max(0, min(compact ? 44 : 54, room / CGFloat(max(1, rows))))
    }

    /// Below the header, where the pointer arrives from: as tall as its rows need.
    var trayFrame: CGRect {
        let room = available
        let height = min(room.height, 2 * inset + titleHeight + CGFloat(rows) * rowHeight)
        return CGRect(x: room.minX, y: room.minY, width: room.width, height: height)
    }

    var cornerRadius: CGFloat {
        min(PanelTheme.pick(CompanionStyle.Radius.field, 16, CompanionStyle.cardRadius), min(trayFrame.width, trayFrame.height) / 2)
    }

    private var available: CGRect {
        let margin: CGFloat = compact ? 16 : 20
        let top = min(size.height, headerHeight + (compact ? 10 : 8))
        return CGRect(x: margin, y: top, width: max(0, size.width - 2 * margin), height: max(0, size.height - top - margin))
    }

    func frame(row: Int) -> CGRect {
        let tray = trayFrame
        return CGRect(x: tray.minX + inset, y: tray.minY + inset + titleHeight + CGFloat(row) * rowHeight,
                      width: max(0, tray.width - 2 * inset), height: rowHeight)
    }

    /// The tray's title, padding and rounded corners keep the chooser open but accept nothing.
    func row(at point: CGPoint) -> Int? {
        guard rows > 0, contains(point) else { return nil }
        return (0..<rows).first { frame(row: $0).contains(point) }
    }

    private func contains(_ point: CGPoint) -> Bool {
        guard trayFrame.contains(point) else { return false }
        let inner = trayFrame.insetBy(dx: cornerRadius, dy: cornerRadius)
        let dx = point.x - min(inner.maxX, max(inner.minX, point.x))
        let dy = point.y - min(inner.maxY, max(inner.minY, point.y))
        return dx * dx + dy * dy <= cornerRadius * cornerRadius
    }
}

enum FileAttachmentValidation {
    static func readableFiles(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter {
            guard $0.isFileURL, FileManager.default.isReadableFile(atPath: $0.path),
                  let values = try? $0.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            return seen.insert($0.standardizedFileURL).inserted
        }
    }
}
