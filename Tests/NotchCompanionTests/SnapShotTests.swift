import XCTest
@testable import NotchCompanion

@MainActor private final class SnapShotFixture: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var calls: [String] = []
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() { onConnectionChange?(false, nil) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { calls.append(method); return [:] }
}

@MainActor final class SnapShotTests: XCTestCase {
    private func window(_ pid: pid_t, id: Int, layer: Int = 0, size: CGFloat = 400, title: String? = nil) -> [String: Any] {
        var row: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowNumber as String: NSNumber(value: id),
                                  kCGWindowLayer as String: NSNumber(value: layer),
                                  kCGWindowBounds as String: CGRect(x: 0, y: 0, width: size, height: size).dictionaryRepresentation]
        if let title { row[kCGWindowName as String] = title }
        return row
    }

    func testSelectionUsesTheRecordedAppAndNeverOwnWindows() {
        let own: pid_t = 100, recorded: pid_t = 200, frontNow: pid_t = 300
        // Front to back: what is in front now, the companion's panel, then the recorded app's
        // tiny and menu-bar-level windows before its real one.
        let windows = [window(frontNow, id: 1), window(own, id: 2), window(recorded, id: 3, size: 20),
                       window(recorded, id: 4, layer: 25), window(recorded, id: 5, title: "Docs"), window(recorded, id: 6)]
        let source = SnapShot.source(appPID: recorded, appName: "Safari", windows: windows, ownPID: own)
        XCTAssertEqual(source, SnapShotSource(processID: recorded, appName: "Safari", windowID: 5, title: "Docs"))
        XCTAssertEqual(source?.name, "Safari — Docs")
        XCTAssertNil(SnapShot.source(appPID: own, appName: "Notch Companion", windows: windows, ownPID: own),
                     "The companion's own panel, aura and mascot windows are never captured")
        XCTAssertEqual(SnapShot.source(appPID: recorded, appName: "Safari", windows: [window(recorded, id: 9)], ownPID: own)?.name, "Safari",
                       "Without a title the app names the picture")
        XCTAssertNil(SnapShot.source(appPID: recorded, appName: "Safari", windows: [window(own, id: 2)], ownPID: own))
    }

    func testPermissionResetNeedsAKnownBundle() {
        // Unbundled test runs and unknown identifiers report failure, so no second prompt is attempted.
        XCTAssertFalse(SnapShot.resetPermission(bundleID: nil))
        XCTAssertFalse(SnapShot.resetPermission(bundleID: "invalid.notch-companion.\(UUID().uuidString)"))
    }

    func testStagingAttachesThePictureWithoutSendingAndRemovalDeletesIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "notch-snapshot-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let transport = SnapShotFixture()
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: transport, preferences: preferences)
        defer { model.shutdown(); preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(model.showSnapShot, "Off by default")
        await model.newSession(showPanel: false, runtime: .codex)
        model.draft = "What is wrong here?"
        let recorded = SnapShotSource(processID: 200, appName: "Safari", windowID: 5, title: "Docs")
        model.snapShotSource = recorded
        var captured: [SnapShotSource] = []
        model.snapShotCapture = { source, directory in
            captured.append(source)
            let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return try SnapShot.write(context.makeImage()!, name: source.name, into: directory)
        }
        await model.attachSnapShot()
        XCTAssertTrue(captured.isEmpty, "The setting gates the action")
        model.showSnapShot = true
        await model.attachSnapShot()
        XCTAssertEqual(captured, [recorded], "The window recorded when the notch opened is captured")
        let attachment = try XCTUnwrap(model.current?.attachments.first)
        XCTAssertEqual(attachment.name, "Safari — Docs.png")
        XCTAssertTrue(attachment.isImage)
        XCTAssertEqual(attachment.url.deletingLastPathComponent().standardizedFileURL, model.snapShotDirectory.standardizedFileURL,
                       "Stored with the app's data, not a temporary folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.url.path))
        XCTAssertEqual(model.current?.draft, "What is wrong here?")
        XCTAssertTrue(transport.calls.isEmpty, "Staging never starts a runtime or sends")
        model.removeAttachment(attachment.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachment.url.path), "Removing an unsent SnapShot deletes its file")
        await model.newSession(showPanel: false, runtime: .antigravity)
        await model.attachSnapShot()
        XCTAssertEqual(captured.count, 1, "Only offered where the harness accepts images")
    }
}
