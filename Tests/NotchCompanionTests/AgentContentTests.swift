import XCTest
@testable import NotchCompanion

/// Native question tools and delivered files, as the conversation shows them.
final class AgentContentTests: XCTestCase {
    // MARK: Delivered files

    func testHermesMediaTagsBecomeFilesAndLeaveCleanText() {
        let content = MessageContent.parse("""
        The report is ready.

        MEDIA:/Users/me/Documents/report.pdf
        Here is the chart: **MEDIA:/tmp/chart.png**.
        """, fileExists: { _ in false })
        XCTAssertEqual(content.media.map(\.url.path), ["/Users/me/Documents/report.pdf", "/tmp/chart.png"])
        XCTAssertEqual(content.media.map(\.isImage), [false, true])
        XCTAssertEqual(content.text, "The report is ready.\n\nHere is the chart:")
    }

    func testMediaPathsWithSpacesResolveAgainstFilesOnDisk() {
        let existing = "/Users/me/Library/Application Support/Notch/plot one.png"
        let content = MessageContent.parse("MEDIA:\(existing) was saved", fileExists: { $0 == existing })
        XCTAssertEqual(content.media.first?.url.path, existing)
        XCTAssertEqual(content.text, "was saved")
        let quoted = MessageContent.parse("MEDIA:`/tmp/a b.pdf`", fileExists: { _ in false })
        XCTAssertEqual(quoted.media.first?.url.path, "/tmp/a b.pdf")
        XCTAssertEqual(quoted.text, "")
    }

    func testExamplesInCodeAndRelativeTagsStayText() {
        let source = "```\nMEDIA:/tmp/example.png\n```\nMEDIA:relative.png"
        let content = MessageContent.parse(source, fileExists: { _ in true })
        XCTAssertTrue(content.media.isEmpty)
        XCTAssertEqual(content.text, source)
    }

    func testLocalMarkdownImagesPreviewAndRemoteImagesBecomeLinks() {
        let content = MessageContent.parse("""
        ![Generated image](</Users/me/Generated Images/cat.png>)
        See ![diagram](https://example.test/d.png) for detail.
        """, fileExists: { _ in false })
        XCTAssertEqual(content.media.first?.url.path, "/Users/me/Generated Images/cat.png")
        XCTAssertEqual(content.media.first?.caption, "Generated image")
        XCTAssertEqual(content.text, "See [diagram](https://example.test/d.png) for detail.")
        XCTAssertEqual(MessageContent.preview("MEDIA:/tmp/report.pdf"), "Sent report.pdf")
    }

    func testLinksToLocalFilesOpenTheFileAndKeepWebLinks() throws {
        let web = try XCTUnwrap(URL(string: "https://example.test/page"))
        XCTAssertEqual(MessageContent.linkDestination(web, workspace: nil), web)
        let codex = try XCTUnwrap(URL(string: "/Users/me/project/App.swift:42"))
        XCTAssertEqual(MessageContent.linkDestination(codex, workspace: nil, fileExists: { _ in false }).path, "/Users/me/project/App.swift")
        let relative = try XCTUnwrap(URL(string: "Sources/App.swift"))
        XCTAssertEqual(MessageContent.linkDestination(relative, workspace: "/Users/me/project", fileExists: { _ in true }).path,
                       "/Users/me/project/Sources/App.swift")
    }

    // MARK: Codex

    private func ownedCodex() throws -> CodexProtocolState {
        var state = CodexProtocolState()
        _ = try state.register(["id": "parent", "turns": []])
        _ = state.notifications("turn/started", ["threadId": "parent", "turn": ["id": "t"]])
        return state
    }

    func testCodexAsyncQuestionsBecomeACardInsteadOfText() throws {
        var state = try ownedCodex()
        let asked: [String: Any] = ["type": "agentMessage", "id": "q", "text": "What is 2 + 2?\n- 4\n- Something else",
                                    "delivery": "async", "questions": [["title": "What is 2 + 2?", "options": ["4", "Something else"]]]]
        _ = state.notifications("item/completed", ["threadId": "parent", "turnId": "t", "item": ["type": "agentMessage", "id": "a", "text": "Let me ask."]])
        XCTAssertTrue(state.notifications("item/started", ["threadId": "parent", "turnId": "t", "item": asked]).isEmpty)
        XCTAssertTrue(state.notifications("item/agentMessage/delta", ["threadId": "parent", "turnId": "t", "itemId": "q", "delta": "What"]).isEmpty)
        let events = state.notifications("item/completed", ["threadId": "parent", "turnId": "t", "item": asked])
        XCTAssertEqual(events.map(\.name), ["message.questions"])
        XCTAssertEqual(AsyncQuestion.decode(events.first?.payload["questions"]), [AsyncQuestion(title: "What is 2 + 2?", options: ["4", "Something else"])])
        let done = state.notifications("turn/completed", ["threadId": "parent", "turn": ["id": "t", "status": "completed"]])
        XCTAssertEqual(done.last?.payload["text"] as? String, "Let me ask.")

        let rows = CodexProtocolState.history(["turns": [["id": "t", "items": [
            ["type": "userMessage", "id": "u", "content": [["type": "text", "text": "Ask me"]]],
            ["type": "agentMessage", "id": "a", "text": "Let me ask."], asked]]]])
        XCTAssertEqual(rows.last?["text"] as? String, "Let me ask.")
        XCTAssertEqual(AsyncQuestion.decode(rows.last?["questions"])?.first?.options, ["4", "Something else"])
        let restored = SessionHistory.messages(rows)
        XCTAssertEqual(restored.last?.questions?.first?.title, "What is 2 + 2?")
    }

    func testCodexGeneratedImagesAppearInTheAnswer() throws {
        var state = try ownedCodex()
        let item: [String: Any] = ["type": "imageGeneration", "id": "img", "status": "completed", "revisedPrompt": "A cat",
                                   "result": "", "savedPath": "/Users/me/Generated/cat 1.png"]
        XCTAssertEqual(state.notifications("item/started", ["threadId": "parent", "turnId": "t", "item": item]).map(\.name), ["tool.start"])
        let events = state.notifications("item/completed", ["threadId": "parent", "turnId": "t", "item": item])
        XCTAssertEqual(events.map(\.name), ["message.delta", "tool.complete"])
        let text = try XCTUnwrap(events.first?.payload["text"] as? String)
        XCTAssertEqual(MessageContent.parse(text, fileExists: { _ in false }).media.first?.url.path, "/Users/me/Generated/cat 1.png")
        let done = state.notifications("turn/completed", ["threadId": "parent", "turn": ["id": "t", "status": "completed"]])
        XCTAssertEqual(done.last?.payload["text"] as? String, text)
    }

    func testCodexBlockingQuestionKeepsOptionDescriptionsBesideTheirChoice() throws {
        var state = try ownedCodex()
        let request = state.serverRequest(id: 1, method: "item/tool/requestUserInput", params: ["threadId": "parent", "questions": [
            ["id": "a", "header": "Plan", "question": "Which plan?", "isOther": false,
             "options": [["label": "Fast", "description": "Skip the tests"], ["label": "Safe", "description": ""]]]]])
        let question = try XCTUnwrap((request.events.first?.payload["questions"] as? [[String: Any]])?.first)
        XCTAssertEqual(question["question"] as? String, "Which plan?")
        XCTAssertEqual(question["header"] as? String, "Plan")
        XCTAssertEqual(question["choice_details"] as? [String: String], ["Fast": "Skip the tests"])
    }

    // MARK: Claude

    func testClaudeQuestionDetailsAndReadableApprovals() throws {
        var state = ClaudeProtocolState(sessionID: "7a25b06b-7560-4a06-a28c-07ef651fd840")
        try state.begin("turn")
        let asked = state.interaction(["request_id": "q", "request": ["subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": [
            "questions": [["question": "Which color?", "header": "Color", "multiSelect": false,
                           "options": [["label": "Blue", "description": "Quiet"], ["label": "Red", "description": "Loud"]]]]]]])
        let question = try XCTUnwrap((asked.events.first?.payload["questions"] as? [[String: Any]])?.first)
        XCTAssertEqual(question["question"] as? String, "Which color?")
        XCTAssertEqual(question["header"] as? String, "Color")
        XCTAssertEqual(question["choice_details"] as? [String: String], ["Blue": "Quiet", "Red": "Loud"])

        XCTAssertEqual(ClaudeProtocolState.describeTool("Bash", ["command": "git status", "description": "Inspect"]), "Bash\n\n$ git status\n\nInspect")
        XCTAssertEqual(ClaudeProtocolState.describeTool("ExitPlanMode", ["plan": "1. Build"]), "ExitPlanMode\n\nStart with this plan?\n\n1. Build")
        XCTAssertEqual(ClaudeProtocolState.describeTool("mcp__x__y", ["path": "/a/b"]), "mcp__x__y\n\n{\n  \"path\" : \"/a/b\"\n}")
    }

    // MARK: App model

    @MainActor func testAsyncQuestionsAttachToTheAnswerAndReplyAsTheNextMessage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = ContentFixture()
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        await model.connect()
        model.draft = "First"
        await model.send()
        let questions = [AsyncQuestion(title: "What is 2 + 2?", options: ["4", "5"])]
        model.receive("message.start", payload: ["session_id": "live"])
        model.receive("message.delta", payload: ["session_id": "live", "text": "Let me ask."])
        model.receive("message.questions", payload: ["session_id": "live", "questions": questions.map(\.payload)])
        model.receive("message.complete", payload: ["session_id": "live", "text": "Let me ask.", "status": "complete"])
        XCTAssertEqual(model.current?.messages.last?.questions, questions)
        XCTAssertEqual(model.current?.messages.last?.text, "Let me ask.")
        XCTAssertEqual(SessionDigest.preview(try XCTUnwrap(model.current)), "Asks: What is 2 + 2?")

        model.draft = "unrelated draft"
        let replied = await model.replyToQuestions(questions, answers: ["4"])
        XCTAssertTrue(replied)
        XCTAssertEqual(fixture.submitted.last, "4")
        XCTAssertEqual(model.current?.messages.last?.text, "4")
        XCTAssertEqual(model.current?.draft, "unrelated draft", "Answering keeps the composer's draft")
        XCTAssertEqual(AsyncQuestion.reply([AsyncQuestion(title: "A?"), AsyncQuestion(title: "B?")], answers: ["x", " "]), "A?\nx")
    }

    @MainActor func testQuestionOnlyAnswerSurvivesCompletionAndReload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "notch-question-reload-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let storage = folder.appendingPathComponent("sessions.json")
        let model = AppModel(storageURL: storage, playsSounds: false, client: ContentFixture(), preferences: preferences)
        defer { model.shutdown(); preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        model.sessions[0].runtimeID = "live"
        model.sessions[0].messages = [ChatMessage(role: "user", text: "Ask")]
        model.receive("message.start", payload: ["session_id": "live"])
        model.receive("message.questions", payload: ["session_id": "live", "questions": [["title": "Name?"]]])
        model.receive("message.complete", payload: ["session_id": "live", "text": "", "status": "complete"])
        XCTAssertEqual(model.sessions[0].messages.last?.questions?.first?.title, "Name?")
        XCTAssertTrue(SessionHistory.isVisibleConversation(model.sessions[0].messages.last!))
        let questionID = try XCTUnwrap(model.current?.messages.last?.id)
        model.sessions[0].messages.append(ChatMessage(role: "assistant", text: " \n"))
        model.shutdown()
        let fixture = ContentFixture()
        let restored = AppModel(storageURL: storage, playsSounds: false, client: fixture, preferences: preferences)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.current?.messages.count, 2, "Drop only the empty streaming placeholder")
        XCTAssertEqual(restored.current?.messages.last?.id, questionID)
        let questions = try XCTUnwrap(restored.current?.messages.last?.questions)
        XCTAssertEqual(questions.first?.title, "Name?")
        await restored.connect()
        let replied = await restored.replyToQuestions(questions, answers: ["Ada"])
        XCTAssertTrue(replied)
        XCTAssertEqual(fixture.submitted, ["Ada"], "The restored card remains answerable")
    }
}

@MainActor private final class ContentFixture: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var submitted: [String] = []
    func connect() async throws {}
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "session.create" || method == "session.resume" { return ["session_id": "live", "stored_session_id": "native"] }
        if method == "prompt.submit" { submitted.append(params["text"] as? String ?? "") }
        return [:]
    }
}
