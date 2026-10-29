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

    private func point(_ destination: FileDropDestination, model: AppModel) -> CGPoint {
        let frame = FileDropLayout(size: model.geometry!.expandedFrame.size, headerHeight: model.geometry!.expandedBandHeight)
            .frame(for: destination)
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
        model.updateFileDrop(at: point(.newSession, model: model), fileCount: 2)
        XCTAssertEqual(model.sessions.count, 1, "Hovering must not create a session.")
        XCTAssertTrue(model.acceptFileDrop([file, file]))
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.sessions.first { $0.id == original.id }, original)
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
        model.updateFileDrop(at: point(.currentSession, model: model), fileCount: 1)
        model.sessions.append(CompanionSession(id: "other", title: "Other window selection"))
        model.selectSession("other")
        model.updateFileDrop(at: point(.currentSession, model: model), fileCount: 1)
        XCTAssertTrue(model.acceptFileDrop([file]))
        XCTAssertEqual(model.currentID, originalID)
        XCTAssertEqual(model.current?.draft, "Next instructions")
        XCTAssertEqual(model.current?.state, .working)
        XCTAssertEqual(model.current?.attachments.map(\.url), [file])
        XCTAssertTrue(model.sessions.last!.attachments.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCancelDoesNotChangeSessionPageDraftOrUnreadCompletion() throws {
        let (model, _, folder, _) = try fixture()
        defer { cleanUp(model, folder) }
        model.sessions = [CompanionSession(id: "unread", state: .finished, draft: "Preserve this")]
        model.currentID = "unread"
        let original = model.sessions
        model.updateFileDrop(at: point(.newSession, model: model), fileCount: 1)
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
        model.updateFileDrop(at: point(.currentSession, model: model), fileCount: 1)
        XCTAssertNil(model.fileDropCurrentSession)
        XCTAssertNil(model.fileDropChoice?.destination)
        XCTAssertFalse(model.acceptFileDrop([file]))
        model.updateFileDrop(at: CGPoint(x: -1, y: 64), fileCount: 1)
        XCTAssertNil(model.fileDropChoice?.destination)
        XCTAssertFalse(model.acceptFileDrop([file]))
        model.updateFileDrop(at: point(.newSession, model: model), fileCount: 1)
        XCTAssertTrue(model.acceptFileDrop([file]))
        XCTAssertEqual(model.sessions.count, 2)
    }

    func testDeletedDestinationNeverRedirectsIntoAnotherSession() throws {
        let (model, _, folder, file) = try fixture()
        defer { cleanUp(model, folder) }
        model.updateFileDrop(at: point(.currentSession, model: model), fileCount: 1)
        model.deleteSession(model.currentID!)
        XCTAssertFalse(model.acceptFileDrop([file]))
        XCTAssertTrue(model.current!.attachments.isEmpty)
        XCTAssertEqual(model.sessions.count, 1)
    }

    func testInvalidNewSessionDropCreatesNothingAndDuplicatesAttachOnce() throws {
        let (model, _, folder, file) = try fixture()
        defer { cleanUp(model, folder) }
        let originalID = model.currentID
        model.updateFileDrop(at: point(.newSession, model: model), fileCount: 1)
        XCTAssertFalse(model.acceptFileDrop([folder, folder.appendingPathComponent("missing"), URL(string: "https://example.com/file")!]))
        XCTAssertEqual(model.currentID, originalID)
        XCTAssertEqual(model.sessions.count, 1)
        model.updateFileDrop(at: point(.currentSession, model: model), fileCount: 2)
        XCTAssertTrue(model.acceptFileDrop([file, file]))
        model.updateFileDrop(at: point(.currentSession, model: model), fileCount: 1)
        XCTAssertTrue(model.acceptFileDrop([file]))
        XCTAssertEqual(model.current?.attachments.count, 1)
    }

    func testInsetTargetsWaitForExpansionAndLeaveBackgroundInactive() throws {
        let (model, _, folder, _) = try fixture()
        defer { cleanUp(model, folder) }
        let target = point(.currentSession, model: model)
        model.notchPresentation = .resting(model.geometry!)
        model.updateFileDrop(at: target, fileCount: 1)
        XCTAssertNil(model.fileDropChoice?.destination)
        model.notchPresentation = .expanded(model.geometry!)
        model.updateFileDrop(at: target, fileCount: 1)
        XCTAssertEqual(model.fileDropChoice?.destination, .currentSession)
        for screen in [CGSize(width: 1920, height: 1080), CGSize(width: 360, height: 360)] {
            model.geometry = NotchGeometry(screen: CGRect(origin: .zero, size: screen), topInset: 0,
                                           leftArea: nil, rightArea: nil)
            model.notchPresentation = .expanded(model.geometry!)
            let size = model.notchPresentation.size
            let layout = FileDropLayout(size: size, headerHeight: model.notchPresentation.bandHeight)
            for destination in FileDropDestination.allCases {
                let frame = layout.frame(for: destination)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame))
                XCTAssertEqual(layout.destination(at: CGPoint(x: frame.midX, y: frame.midY), hasCurrentSession: true), destination)
            }
            let tray = layout.trayFrame
            XCTAssertGreaterThan(tray.width * tray.height / (size.width * size.height), 0.6)
            XCTAssertLessThan(tray.width * tray.height / (size.width * size.height), 0.8)
            // Only the visible tray accepts files; the divider still belongs
            // to the right destination without an inactive strip.
            for y in [tray.minY + 20, tray.midY, tray.maxY - 20] {
                for x in [tray.minX + 20, tray.midX - 1, tray.midX, tray.maxX - 20] {
                    let destination: FileDropDestination = x < size.width / 2 ? .currentSession : .newSession
                    XCTAssertEqual(model.fileDropDestination(at: CGPoint(x: x, y: y)), destination)
                }
            }
            for point in [CGPoint(x: tray.midX, y: 32), CGPoint(x: 1, y: tray.midY),
                          CGPoint(x: tray.midX, y: size.height - 1),
                          CGPoint(x: tray.minX + 1, y: tray.minY + 1),
                          CGPoint(x: tray.maxX - 1, y: tray.maxY - 1)] {
                XCTAssertNil(model.fileDropDestination(at: point), "Dimmed background and rounded tray corners reject drops.")
            }
            XCTAssertNil(model.fileDropDestination(at: CGPoint(x: 1, y: size.height - 1)),
                         "The expanded notch's clipped corner still rejects a drop.")
        }
    }

    func testFeedingSignalsAcceptedDropsInBothDestinationsButNotSessionSelection() throws {
        let (model, _, folder, file) = try fixture()
        defer { cleanUp(model, folder) }
        let originalID = model.currentID!
        model.updateFileDrop(at: point(.newSession, model: model), fileCount: 1)
        XCTAssertEqual(model.attachmentFeedEvent, 0)
        XCTAssertFalse(model.acceptFileDrop([folder]))
        XCTAssertEqual(model.attachmentFeedEvent, 0)
        XCTAssertTrue(model.acceptFileDrop([file]))
        XCTAssertEqual(model.attachmentFeedEvent, 1, "New-session drops must trigger the same chomps.")
        let newID = model.currentID!
        model.selectSession(originalID)
        model.selectSession(newID)
        XCTAssertEqual(model.attachmentFeedEvent, 1, "Reopening attached files is not a feeding event.")
        model.removeAttachment(model.current!.attachments[0].id)
        XCTAssertEqual(model.attachmentFeedEvent, 1)
        model.updateFileDrop(at: point(.currentSession, model: model), fileCount: 1)
        XCTAssertTrue(model.acceptFileDrop([file]))
        XCTAssertEqual(model.attachmentFeedEvent, 2)
        model.updateFileDrop(at: point(.newSession, model: model), fileCount: 1)
        model.endFileDrop()
        XCTAssertEqual(model.attachmentFeedEvent, 2, "A cancelled hover must not chomp.")
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
