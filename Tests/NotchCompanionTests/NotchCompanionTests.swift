import XCTest
@testable import NotchCompanion

final class NotchCompanionTests: XCTestCase {
    func testNotchExtensionMatchesHardwareOnOffsetDisplay() {
        let screen = CGRect(x: -1728, y: 180, width: 1728, height: 1117)
        let left = CGRect(x: -1728, y: 1265, width: 764, height: 32)
        let right = CGRect(x: -764, y: 1265, width: 764, height: 32)
        let geometry = NotchGeometry(screen: screen, topInset: 32, leftArea: left, rightArea: right)
        XCTAssertTrue(geometry.hasHardware)
        XCTAssertEqual(geometry.hardware.width, 200)
        XCTAssertEqual(geometry.collapsedFrame.height, geometry.hardware.height)
        XCTAssertEqual(geometry.collapsedFrame.minY, geometry.hardware.minY)
        XCTAssertEqual(geometry.collapsedFrame.maxY, screen.maxY)
        XCTAssertEqual(geometry.collapsedFrame.minX + geometry.mascotWidth, geometry.hardware.minX)
        XCTAssertEqual(geometry.expandedFrame.maxY, screen.maxY)
        XCTAssertGreaterThan(geometry.expandedFrame.width, geometry.collapsedFrame.width)
        XCTAssertEqual(geometry.expandedBandFrame.width, geometry.bodyFrame.width)
    }

    func testExternalDisplayKeepsSmallRestingBandAndExpandsIntoConversation() {
        let geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), topInset: 0, leftArea: nil, rightArea: nil)
        XCTAssertFalse(geometry.hasHardware)
        XCTAssertEqual(geometry.collapsedFrame.width, 258)
        XCTAssertEqual(geometry.collapsedFrame.height, 32)
        XCTAssertEqual(geometry.hardware.width, 200)
        XCTAssertEqual(geometry.collapsedFrame.midX, 960)
        XCTAssertEqual(geometry.expandedFrame.midX, 960)
        XCTAssertEqual(geometry.expandedBandFrame.width, 560)
        XCTAssertEqual(geometry.expandedBandFrame.height, 64)
        XCTAssertEqual(geometry.bodyFrame.size, CGSize(width: 560, height: 480))
    }

    func testBlinkClosesAndOpensContinuously() {
        XCTAssertEqual(MascotMotion.blinkAmount(at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(MascotMotion.blinkAmount(at: 0.12), 1, accuracy: 0.0001)
        XCTAssertEqual(MascotMotion.blinkAmount(at: 0.24), 0, accuracy: 0.0001)
        XCTAssertEqual(MascotMotion.blinkAmount(at: 0.06), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MascotMotion.blinkAmount(at: 0.18), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MascotMotion.blinkAmount(at: 2), 0)
    }

    func testOlderSessionFormatPreservesHistory() throws {
        let data = Data(#"{"id":"prior","title":"Keep this conversation","storedID":"hermes-owned","draft":"unfinished"}"#.utf8)
        let session = try JSONDecoder().decode(CompanionSession.self, from: data)
        XCTAssertEqual(session.storedID, "hermes-owned")
        XCTAssertEqual(session.draft, "unfinished")
        XCTAssertTrue(session.parentTurnComplete)
        XCTAssertEqual(session.attachments.count, 0)
    }

    func testRestoredBackendHistoryExcludesToolsAndHiddenScaffolding() {
        let messages = SessionHistory.messages([
            ["role": "user", "text": "My question", "row_id": 12, "timestamp": 1_790_000_000.0],
            ["role": "tool", "name": "terminal", "context": "echo"],
            ["role": "assistant", "text": "", "row_id": 13],
            ["role": "assistant", "text": "Hidden context", "display_kind": "hidden"],
            ["role": "assistant", "text": "The restored answer", "row_id": 14]
        ])
        XCTAssertEqual(messages.map(\.text), ["My question", "The restored answer"])
        XCTAssertEqual(messages.first?.id, "hermes-12")
        XCTAssertEqual(messages.first?.createdAt.timeIntervalSince1970, 1_790_000_000.0)
    }

    @MainActor private func makeModel() -> AppModel {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notch-tests-\(UUID().uuidString)").appendingPathComponent("sessions.json")
        let model = AppModel(storageURL: file, playsSounds: false)
        model.sessions[0].runtimeID = "parent"
        return model
    }

    @MainActor func testToolEventsRetainHistoryButCapRecentRows() async {
        let model = makeModel()
        defer { model.shutdown() }
        for number in 0..<12 {
            model.receive("tool.start", payload: ["session_id": "parent", "tool_id": "t\(number)", "name": "terminal", "context": "echo test"])
            model.receive("tool.complete", payload: ["session_id": "parent", "tool_id": "t\(number)", "result": "test"])
        }
        XCTAssertEqual(model.current?.tools.count, 12)
        XCTAssertEqual(model.current?.recentTools.map(\.id), ["t9", "t10", "t11"])
        XCTAssertTrue(model.current!.tools.allSatisfy { $0.state == .finished })
    }

    @MainActor func testEventsCannotBleedBetweenSessions() async {
        let model = makeModel()
        defer { model.shutdown() }
        var second = CompanionSession(); second.runtimeID = "other"
        model.sessions.append(second)
        model.receive("message.delta", payload: ["session_id": "other", "text": "Other session only"])
        model.receive("message.delta", payload: ["session_id": "unrelated", "text": "Must be ignored"])
        XCTAssertTrue(model.current!.messages.isEmpty)
        XCTAssertEqual(model.sessions[1].latestResponse, "Other session only")
    }

    @MainActor func testRepeatedStartsAndEmptyCompletionLeaveNoWorkingPlaceholder() async {
        let model = makeModel()
        defer { model.shutdown() }
        model.receive("message.start", payload: ["session_id": "parent"])
        model.receive("message.start", payload: ["session_id": "parent"])
        XCTAssertEqual(model.current?.messages.count, 1)
        model.receive("message.complete", payload: ["session_id": "parent", "text": "", "status": "complete"])
        XCTAssertTrue(model.current!.messages.isEmpty)
        model.receive("message.start", payload: ["session_id": "parent"])
        model.receive("message.complete", payload: ["session_id": "parent", "text": "The final answer", "status": "complete"])
        XCTAssertEqual(model.current?.messages.map(\.text), ["The final answer"])
    }

    @MainActor func testParentCompletionWaitsForActualDelegatedWork() async {
        let model = makeModel()
        defer { model.shutdown() }
        model.receive("message.start", payload: ["session_id": "parent"])
        model.receive("subagent.start", payload: ["session_id": "parent", "subagent_id": "child", "goal": "Research options", "task_index": 0])
        model.receive("message.complete", payload: ["session_id": "parent", "text": "I delegated this work.", "status": "complete"])
        XCTAssertEqual(model.current?.state, .working)
        XCTAssertTrue(model.current!.isBusy)
        model.receive("subagent.tool", payload: ["session_id": "parent", "subagent_id": "child", "tool_name": "web_search", "tool_preview": "Train routes"])
        XCTAssertEqual(model.current?.agents.first?.tools.first?.detail, "Train routes")
        XCTAssertEqual(model.current?.agents.first?.tools.first?.state, .working)
        model.receive("subagent.complete", payload: ["session_id": "parent", "subagent_id": "child", "status": "complete", "summary": "Three routes"])
        XCTAssertEqual(model.current?.state, .finished)
        XCTAssertFalse(model.current!.isBusy)
        XCTAssertEqual(model.current?.agents.first?.text, "Three routes")
        XCTAssertEqual(model.current?.agents.first?.tools.first?.state, .finished)
    }

    @MainActor func testDelegationFallbackIdentityUsesTaskIndexWithinDelegation() async {
        let model = makeModel()
        defer { model.shutdown() }
        for index in 0...1 { model.receive("subagent.start", payload: ["session_id": "parent", "delegation_id": "batch", "task_index": index, "goal": "Part \(index)"]) }
        XCTAssertEqual(model.current?.agents.map(\.id), ["batch:0", "batch:1"])
    }

    @MainActor func testClarificationQuestionsRemainDistinctAndExpireTogether() async {
        let model = makeModel()
        defer { model.shutdown() }
        model.receive("clarify.request", payload: ["session_id": "parent", "request_id": "r1", "questions": [["qid": "color", "question": "Color?", "choices": ["Sage", "Cream"]], ["qid": "size", "question": "Size?", "choices": ["Small", "Large"]]]])
        XCTAssertEqual(model.requests.count, 2)
        XCTAssertEqual(model.requests.map(\.questionID), ["color", "size"])
        XCTAssertEqual(model.current?.state, .waiting)
        model.receive("clarify.expire", payload: ["session_id": "parent", "request_id": "r1"])
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertEqual(model.current?.state, .working)
    }

    @MainActor func testDropStagesOnlyAndDoesNotDeleteOrSubmitFile() async throws {
        let model = makeModel()
        defer { model.shutdown() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notch-fixture-\(UUID().uuidString).txt")
        try Data("safe fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var opens = 0
        model.requestOpenPanel = { opens += 1 }
        model.addAttachments([file], showPanel: false)
        model.addAttachments([file], showPanel: false)
        XCTAssertEqual(model.current?.attachments.count, 1)
        XCTAssertTrue(model.current!.messages.isEmpty)
        XCTAssertEqual(model.current?.state, .idle)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(try String(contentsOf: file), "safe fixture")
        model.removeAttachment(model.current!.attachments[0].id)
        XCTAssertEqual(try String(contentsOf: file), "safe fixture")
    }

    @MainActor func testTypingAndAttachingDuringSendDoesNotLoseNewInput() async throws {
        let transport = DeferredTransport()
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("notch-race-\(UUID().uuidString)/sessions.json")
        let model = AppModel(storageURL: storage, playsSounds: false, client: transport)
        defer { model.shutdown() }
        await model.connect()
        model.draft = "First message"
        let send = Task { await model.send() }
        let deadline = Date().addingTimeInterval(5)
        while transport.pending == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(transport.pending)
        let file = storage.deletingLastPathComponent().appendingPathComponent("next-file.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("For the next message".utf8).write(to: file)
        model.draft = "Second message, still drafting"
        model.addAttachments([file], showPanel: false)
        transport.pending?.resume(returning: ["status": "streaming"])
        transport.pending = nil
        await send.value
        XCTAssertEqual(model.draft, "Second message, still drafting")
        XCTAssertEqual(model.current?.attachments.map(\.name), ["next-file.txt"])
        XCTAssertEqual(model.current?.messages.first?.text, "First message")
    }

    @MainActor func testMultiQuestionReplyUsesBackendRequestAndQuestionIDs() async {
        let transport = DeferredTransport()
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("notch-questions-\(UUID().uuidString)/sessions.json")
        let model = AppModel(storageURL: storage, playsSounds: false, client: transport)
        defer { model.shutdown() }
        model.sessions[0].runtimeID = "parent"
        model.receive("clarify.request", payload: ["session_id": "parent", "request_id": "r1", "questions": [["qid": "color", "question": "Color?"], ["qid": "size", "question": "Size?"]]])
        await model.answer(model.requests[0], choice: "Sage")
        XCTAssertEqual(transport.lastParams["request_id"] as? String, "r1")
        XCTAssertEqual(transport.lastParams["question_id"] as? String, "color")
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(model.current?.state, .waiting)
        await model.answer(model.requests[0], choice: "Small")
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertEqual(model.current?.state, .working)
    }
}

@MainActor
private final class DeferredTransport: HermesTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var pending: CheckedContinuation<[String: Any], Error>?
    var lastParams: [String: Any] = [:]
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() { pending?.resume(throwing: AppError("Disconnected")); pending = nil }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        lastParams = params
        if method == "session.create" { return ["session_id": "live", "stored_session_id": "durable"] }
        if method == "prompt.submit" { return try await withCheckedThrowingContinuation { pending = $0 } }
        return ["resolved": true]
    }
}
