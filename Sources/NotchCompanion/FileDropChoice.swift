import Foundation

enum FileDropDestination: CaseIterable {
    case currentSession, newSession
}

struct FileDropChoice: Equatable {
    /// Keep the destination stable if the selection changes in the full window.
    let currentSessionID: String?
    var fileCount: Int
    var destination: FileDropDestination?
}

/// Shared by the native drag handler and SwiftUI, in whole-notch coordinates.
/// A large inset tray leaves the dimmed conversation visible around the choices.
struct FileDropLayout {
    let size: CGSize
    let headerHeight: CGFloat

    var trayFrame: CGRect {
        let compact = size.width < 420
        let inset: CGFloat, bottom: CGFloat, top: CGFloat
        if PanelTheme.current == .refined {
            // On the panel's own margins, so the tray covers the content and composer exactly.
            inset = compact ? 16 : 20
            bottom = compact ? 16 : 12
            top = min(size.height, headerHeight + (compact ? 12 : 8))
        } else {
            inset = compact ? 16 : 24
            bottom = inset
            top = min(size.height, headerHeight + (compact ? 12 : 16))
        }
        return CGRect(x: inset, y: top, width: max(0, size.width - 2 * inset),
                      height: max(0, size.height - top - bottom))
    }

    var cornerRadius: CGFloat {
        min(PanelTheme.pick(CompanionStyle.Radius.field, 16, 16), min(trayFrame.width, trayFrame.height) / 2)
    }

    func frame(for destination: FileDropDestination) -> CGRect {
        let tray = trayFrame
        return CGRect(x: destination == .currentSession ? tray.minX : tray.midX, y: tray.minY,
                      width: tray.width / 2, height: tray.height)
    }

    func destination(at point: CGPoint, hasCurrentSession: Bool) -> FileDropDestination? {
        guard contains(point) else { return nil }
        return FileDropDestination.allCases.first {
            ($0 != .currentSession || hasCurrentSession) && frame(for: $0).contains(point)
        }
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
