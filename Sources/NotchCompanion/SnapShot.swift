import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The window the user was working in when the notch opened.
struct SnapShotSource: Equatable {
    var processID: pid_t
    var appName: String
    var windowID: CGWindowID
    var title: String
    var name: String { title.isEmpty || title == appName ? appName : appName + " — " + title }
}

enum SnapShot {
    /// The recorded app's frontmost normal window from a front-to-back window
    /// list. The companion's own panel, aura and mascot windows never qualify.
    static func source(appPID: pid_t, appName: String, windows: [[String: Any]], ownPID: pid_t = getpid()) -> SnapShotSource? {
        guard appPID != ownPID else { return nil }
        let row = windows.first { row in
            let bounds = (row[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            return (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == appPID
                && (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                && ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
                && bounds.width >= 40 && bounds.height >= 40
        }
        guard let row, let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
        // Titles need Screen Recording permission; the app name stands in until then.
        return SnapShotSource(processID: appPID, appName: appName, windowID: id, title: row[kCGWindowName as String] as? String ?? "")
    }

    static func frontmost() -> SnapShotSource? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return source(appPID: app.processIdentifier, appName: app.localizedName ?? "Window", windows: windows)
    }

    /// One window through ScreenCaptureKit, written as a PNG in `directory`.
    static func capture(_ source: SnapShotSource, into directory: URL) async throws -> URL {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == source.windowID }),
              window.owningApplication?.processID == source.processID else {
            throw AppError("\(source.appName)'s window is no longer on screen. Open the notch from the window you want to attach.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        var named = source
        if let title = window.title, !title.isEmpty { named.title = title }
        return try write(image, name: named.name, into: directory)
    }

    static func write(_ image: CGImage, name: String, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safe = String(name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }.prefix(80)).trimmingCharacters(in: .whitespaces)
        var url = directory.appendingPathComponent((safe.isEmpty ? "Window" : safe) + ".png")
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(safe) \(copy).png"); copy += 1
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AppError("The window picture could not be saved.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppError("The window picture could not be saved.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// Removes this app's own Screen Recording entry, so the next request prompts for the running build.
    static func resetPermission(bundleID: String? = Bundle.main.bundleIdentifier) async -> Bool {
        guard let bundleID else { return false }
        let tccutil = Process()
        tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", "ScreenCapture", bundleID]
        tccutil.standardOutput = FileHandle.nullDevice
        tccutil.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { done in
            tccutil.terminationHandler = { done.resume(returning: $0.terminationStatus == 0) }
            // The handler never runs for a process that did not start.
            if (try? tccutil.run()) == nil { done.resume(returning: false) }
        }
    }

    static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}
