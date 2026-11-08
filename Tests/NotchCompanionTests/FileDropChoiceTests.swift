import XCTest
@testable import NotchCompanion

@MainActor
final class FileDropChoiceTests: XCTestCase {
    private func fixture() throws -> (AppModel, FileChoiceTransport, URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-choice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Project brief.txt")
        try Data("Keep the original file.".utf8).write(to: file)
        let transport = FileChoiceTransport()
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: transport)
        model.geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), topInset: 0,
                                       leftArea: nil, rightArea: nil)
        model.notchPresentation = .expanded(model.geometry!)
        model.expanded = true
        return (model, transport, folder, file)
    }

    private func cleanUp(_ model: AppModel, _ folder: URL) {
        model.shutdown()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Opens the chooser if needed, then hovers the row for `target`.
    private func hover(_ target: FileDropDestination, model: AppModel, fileCount: Int = 1) throws {
        if model.fileDropChoice == nil { model.updateFileDrop(at: CGPoint(x: -1, y: 64), fileCount: fileCount) }
        let point = try XCTUnwrap(self.point(target, model: model))
        model.updateFileDrop(at: point, fileCount: fileCount)
    }

    private func point(_ target: FileDropDestination, model: AppModel) -> CGPoint? {
        guard let targets = model.fileDropChoice?.targets, let row = targets.firstIndex(of: target) else { return nil }
        let frame = FileDropLayout(size: model.geometry!.expandedFrame.size, headerHeight: model.geometry!.expandedBandHeight,
                                   rows: targets.count).frame(row: row)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    func testNewSessionDropPreservesExistingWorkAndOnlyStagesFiles() throws {
        let (model, transport, folder, file) = try fixture()
        defer { cleanUp(model, folder) }
        model.sessions[0].draft = "Keep my pending instructions"
        model.sessions[0].messages = [ChatMessage(role: "user", text: "Existing work")]
        model.sessions[0].state = .working
        model.sessions[0].agents = [ChildAgent(id: "child", title: "Still working")]
        model.sessions[0].attachments = [Attachment(url: file)]
        let original = model.current!
        model.page = .settings
        try hover(.newSession, model: model, fileCount: 2)
        XCTAssertEqual(model.sessions.count, 1, "Hovering must not create a session.")
        XCTAssertTrue(model.acceptFileDrop([file, file]))
        XCTAssertEqual(model.sessions.count, 2)
        // Only its auto-archive clock restarts as it stops being the selection.
        var left = original
        left.lastSeenAt = model.sessions.first { $0.id == original.id }?.lastSeenAt
        XCTAssertNotNil(left.lastSeenAt)
        XCTAssertEqual(model.sessions.first { $0.id == original.id }, left)
        XCTAssertNotEqual(model.currentID, original.id)
        XCTAssertEqual(model.current?.attachments.map(\.url), [file])
        XCTAssertEqual(model.current?.draft, "")
        XCTAssertTrue(model.current?.messages.isEmpty == true)
        XCTAssertNil(model.current?.runtimeID)
        XCTAssertNil(model.fileDropChoice)
        XCTAssertEqual(model.page, .session)
        XCTAssertTrue(transport.requests.isEmpty, "Attaching must not start a runtime or submit a prompt.")
        XCTAssertEqual(try String(contentsOf: file), "Keep the original file.")
        let saved = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: folder.appendingPathComponent("sessions.json")))
        XCTAssertEqual(saved.first?.attachments.map(\.url), [file])
    }

    func testCurrentDestinationStaysBoundToSessionShownAtDragEntry() throws {
        let (model, transport, folder, file) = try fixture()
        defer { cleanUp(model, folder) }
        let originalID = model.currentID!
        model.sessions[0].draft = "Next instructions"
        model.sessions[0].state = .working
        try hover(.session(originalID), model: model)
        let entryPoint = try XCTUnwrap(point(.session(originalID), model: model))
        model.sessions.append(CompanionSession(id: "other", title: "Other window selection"))
        model.selectSession("other")
        model.updateFileDrop(at: entryPoint, fileCount: 1)
        XCTAssertEqual(model.fileDropChoice?.targets, [.session(originalID), .newSession], "Targets are fixed at drag entry.")
        XCTAssertTrue(model.acceptFileDrop([file]))
        XCTAssertEqual(model.currentID, originalID)
        XCTAssertEqual(model.current?.draft, "Next instructions")
        XCTAssertEqual(model.current?.state, .working)
        XCTAssertEqual(model.current?.attachments.map(\.url), [file])
        XCTAssertTrue(model.sessions.last!.attachments.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// The session shown first, then the most recently active others from Your
    /// sessions (never archived, auto-archived, snoozed or delegated), then New session.
    func testRecentSessionsFollowTheCurrentOneAndAnOlderOneCanTakeTheDrop() throws {
        let (model, transport, folder, file) = try fixture()
        defer { cleanUp(model, folder) }
        let now = Date()
        func session(_ id: String, minutesAgo: Double, _ change: (inout CompanionSession) -> Void = { _ in }) -> CompanionSession {
            var session = CompanionSession(id: id, title: id)
            session.updatedAt = now.addingTimeInterval(-60 * minutesAgo)
            session.lastSeenAt = session.updatedAt
            session.messages = [ChatMessage(role: "user", text: "Work in \(id)")]
            change(&session)
            return session
        }
        model.sessions = [
            session("shown", minutesAgo: 30),
            session("newest", minutesAgo: 1),
            session("second", minutesAgo: 5) { $0.draft = "Half-written reply" },
            session("archived", minutesAgo: 2) { $0.isArchived = true },
            session("snoozed", minutesAgo: 3) { $0.snoozedUntil = now.addingTimeInterval(3600) },
            session("child", minutesAgo: 1) { $0.parentSessionID = "newest" },
            session("third", minutesAgo: 8),
            session("fourth", minutesAgo: 9),
        ]
        model.currentID = "shown"
        model.updateFileDrop(at: CGPoint(x: -1, y: 64), fileCount: 1)
        XCTAssertEqual(model.fileDropChoice?.targets,
                       [.session("shown"), .session("newest"), .session("second"), .session("third"), .newSession])
        try hover(.session("second"), model: model)
        XCTAssertEqual(model.fileDropChoice?.destination, .session("second"))
        XCTAssertTrue(model.acceptFileDrop([file]))
        XCTAssertEqual(model.currentID, "second")
        XCTAssertEqual(model.page, .session)
        XCTAssertEqual(model.current?.attachments.map(\.url), [file])
        XCTAssertEqual(model.current?.draft, "Half-written reply", "The older session's draft stays.")
        XCTAssertTrue(model.sessions.first { $0.id == "shown" }!.attachments.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)

        // A delegated child on screen is the current target; its parent's siblings follow.
        model.currentID = "child"
        model.updateFileDrop(at: CGPoint(x: -1, y: 64), fileCount: 1)
        XCTAssertEqual(model.fileDropChoice?.targets.first, .session("child"))
        XCTAssertEqual(model.fileDropChoice?.targets.count, FileDropChoice.sessionLimit + 1)
        model.endFileDrop()
    }

    func testCancelDoesNotChangeSessionPageDraftOrUnreadCompletion() throws {
        let (model, _, folder, _) = try fixture()
        defer { cleanUp(model, folder) }
        model.sessions = [CompanionSession(id: "unread", state: .finished, draft: "Preserve this")]
        model.currentID = "unread"
        let original = model.sessions
        try hover(.newSession, model: model)
        model.setSessionVisibility(notchVisible: true)
        XCTAssertTrue(model.current!.hasUnreadCompletion, "A drop chooser covers the conversation.")
        model.setSessionVisibility(notchVisible: false)
        model.endFileDrop()
        XCTAssertNil(model.fileDropChoice)
        XCTAssertEqual(model.sessions, original)
        XCTAssertEqual(model.page, .session)
        model.setSessionVisibility(notchVisible: true)
        XCTAssertFalse(model.current!.hasUnreadCompletion, "Reading resumes after the chooser leaves.")
    }

    func testUnavailableCurrentSessionAndOutsidePointsRejectDrops() throws {
        let (model, _, folder, file) = try fixture()
        defer { cleanUp(model, folder) }
        model.sessions[0].isArchived = true
        model.updateFileDrop(at: CGPoint(x: -1, y: 64), fileCount: 1)
        XCTAssertNil(model.fileDropChoice?.currentSessionID)
        XCTAssertEqual(model.fileDropChoice?.targets, [.newSession], "An archived session is not offered.")
        XCTAssertNil(model.fileDropChoice?.destination)
        XCTAssertFalse(model.acceptFileDrop([file]))
        try hover(.newSession, model: model)
        XCTAssertTrue(model.acceptFileDrop([file]))
        XCTAssertEqual(model.sessions.count, 2)
    }

    func testDeletedDestinationNeverRedirectsIntoAnotherSession() throws {
        let (model, _, folder, file) = try fixture()
        defer { cleanUp(model, folder) }
        try hover(.session(model.currentID!), model: model)
        model.deleteSession(model.currentID!)
        XCTAssertFalse(model.acceptFileDrop([file]))
        XCTAssertTrue(model.current!.attachments.isEmpty)
        XCTAssertEqual(model.sessions.count, 1)
    }

    func testInvalidNewSessionDropCreatesNothingAndDuplicatesAttachOnce() throws {
        let (model, _, folder, file) = try fixture()
        defer { cleanUp(model, folder) }
        let originalID = model.currentID!
        try hover(.newSession, model: model)
        XCTAssertFalse(model.acceptFileDrop([folder, folder.appendingPathComponent("missing"), URL(string: "https://example.com/file")!]))
        XCTAssertEqual(model.currentID, originalID)
        XCTAssertEqual(model.sessions.count, 1)
        try hover(.session(originalID), model: model, fileCount: 2)
        XCTAssertTrue(model.acceptFileDrop([file, file]))
        try hover(.session(originalID), model: model)
        XCTAssertTrue(model.acceptFileDrop([file]))
        XCTAssertEqual(model.current?.attachments.count, 1)
    }

    func testRowsWaitForExpansionMeetEdgeToEdgeAndLeaveTheRestInactive() throws {
        let (model, _, folder, _) = try fixture()
        defer { cleanUp(model, folder) }
        model.notchPresentation = .resting(model.geometry!)
        model.updateFileDrop(at: CGPoint(x: 100, y: 120), fileCount: 1)
        XCTAssertNil(model.fileDropChoice?.destination, "Targets accept files only once the panel has opened.")
        model.endFileDrop()
        for screen in [CGSize(width: 1920, height: 1080), CGSize(width: 360, height: 360)] {
            model.geometry = NotchGeometry(screen: CGRect(origin: .zero, size: screen), topInset: 0,
                                           leftArea: nil, rightArea: nil)
            model.notchPresentation = .expanded(model.geometry!)
            let size = model.notchPresentation.size
            for rows in 1...(FileDropChoice.sessionLimit + 1) {
                let layout = FileDropLayout(size: size, headerHeight: model.notchPresentation.bandHeight, rows: rows)
                let tray = layout.trayFrame
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(tray))
                XCTAssertGreaterThanOrEqual(tray.minY, model.notchPresentation.bandHeight, "The tray stays under the header.")
                XCTAssertGreaterThanOrEqual(layout.rowHeight, 36, "Every row stays a comfortable target (\(screen), \(rows) rows).")
                for row in 0..<rows {
                    let frame = layout.frame(row: row)
                    XCTAssertTrue(tray.contains(frame))
                    XCTAssertEqual(layout.row(at: CGPoint(x: frame.midX, y: frame.midY)), row)
                    if row > 0 {
                        // No dead gap: the boundary belongs to the lower row.
                        XCTAssertEqual(frame.minY, layout.frame(row: row - 1).maxY, accuracy: 0.001)
                        XCTAssertEqual(layout.row(at: CGPoint(x: frame.midX, y: frame.minY)), row)
                    }
                }
                for point in [CGPoint(x: tray.midX, y: tray.minY + 4), // the title line
                              CGPoint(x: tray.minX + 2, y: layout.frame(row: 0).midY), // the tray's padding
                              CGPoint(x: tray.minX + 1, y: tray.minY + 1), CGPoint(x: tray.maxX - 1, y: tray.maxY - 1),
                              CGPoint(x: tray.midX, y: tray.maxY + 4), CGPoint(x: tray.midX, y: 10)] {
                    XCTAssertNil(layout.row(at: point), "\(point) is not a drop target (\(screen), \(rows) rows).")
                }
            }
            model.updateFileDrop(at: CGPoint(x: -1, y: 64), fileCount: 1)
            let target = try XCTUnwrap(point(.newSession, model: model))
            model.updateFileDrop(at: target, fileCount: 1)
            XCTAssertEqual(model.fileDropChoice?.destination, .newSession)
            XCTAssertNil(model.fileDropDestination(at: CGPoint(x: 1, y: size.height - 1)),
                         "The expanded notch's clipped corner still rejects a drop.")
            model.endFileDrop()
        }
    }

    /// The panel's spring clamps progress at 1 while its outline still overshoots;
    /// the rows are drawn at the settled size, so none accepts a file until then.
    func testRowsAcceptNothingWhileTheOpeningSpringOvershoots() throws {
        let (model, _, folder, _) = try fixture()
        defer { cleanUp(model, folder) }
        let geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 360, height: 360), topInset: 0, leftArea: nil, rightArea: nil)
        model.geometry = geometry
        model.sessions = (0..<5).map { CompanionSession(id: "s\($0)", title: "Session \($0)") }
        model.currentID = "s0"
        model.notchPresentation = .expanded(geometry)
        model.updateFileDrop(at: CGPoint(x: -1, y: 64), fileCount: 1)
        let target = try XCTUnwrap(model.fileDropChoice?.targets[3])
        let point = try XCTUnwrap(self.point(target, model: model))
        let opening = UnifiedNotchMotion(from: .resting(geometry), to: .expanded(geometry), startedAt: 0)
        let overshooting = try XCTUnwrap(stride(from: 0.05, to: opening.duration, by: 0.01).lazy
            .map { opening.presentation(at: $0) }
            .first { $0.progress == 1 && $0.size != geometry.expandedFrame.size && $0.contains(point) },
            "The opening spring is expected to overshoot after progress reaches 1.")
        model.notchPresentation = overshooting
        XCTAssertNil(model.fileDropDestination(at: point))
        model.notchPresentation = opening.presentation(at: opening.duration)
        XCTAssertEqual(model.fileDropDestination(at: point), target)
        model.endFileDrop()
    }

    /// The drag image lands on the session page's attach button, measured on this
    /// screen, and only when the destination shows a composer.
    func testLandingFrameIsTheSessionPagesAttachButtonWhenTheDestinationShowsAComposer() throws {
        let (model, _, folder, _) = try fixture()
        defer { cleanUp(model, folder) }
        let button = CGRect(x: 27, y: 480, width: 28, height: 28)
        XCTAssertNil(model.attachLandingFrame, "Nothing measured yet: the file vanishes where it was dropped.")
        model.attachButtonFrame = (button, model.geometry!)
        model.page = .session
        XCTAssertEqual(model.attachLandingFrame, button)
        model.projectTrustSessionID = model.currentID
        XCTAssertNil(model.attachLandingFrame, "Project trust replaces the composer.")
        model.projectTrustSessionID = nil
        model.page = .settings
        XCTAssertNil(model.attachLandingFrame)
        model.page = .session
        model.geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1440, height: 900), topInset: 0, leftArea: nil, rightArea: nil)
        XCTAssertNil(model.attachLandingFrame, "A frame measured on another screen is stale.")
    }

    func testAcceptedDropsSignalAnAttachmentInBothKindsOfDestinationButSessionSelectionDoesNot() throws {
        let (model, _, folder, file) = try fixture()
        defer { cleanUp(model, folder) }
        let originalID = model.currentID!
        try hover(.newSession, model: model)
        XCTAssertEqual(model.attachmentEvent, 0)
        XCTAssertFalse(model.acceptFileDrop([folder]))
        XCTAssertEqual(model.attachmentEvent, 0)
        XCTAssertTrue(model.acceptFileDrop([file]))
        XCTAssertEqual(model.attachmentEvent, 1, "New-session drops land like any other.")
        let newID = model.currentID!
        model.selectSession(originalID)
        model.selectSession(newID)
        XCTAssertEqual(model.attachmentEvent, 1, "Reopening attached files is not an attachment.")
        model.removeAttachment(model.current!.attachments[0].id)
        XCTAssertEqual(model.attachmentEvent, 1)
        try hover(.session(newID), model: model)
        XCTAssertTrue(model.acceptFileDrop([file]))
        XCTAssertEqual(model.attachmentEvent, 2)
        try hover(.newSession, model: model)
        model.endFileDrop()
        XCTAssertEqual(model.attachmentEvent, 2, "A cancelled hover does not land.")
    }
}

@MainActor
private final class FileChoiceTransport: HermesTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var requests: [String] = []
    func connect() async throws {}
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append(method)
        return [:]
    }
}
