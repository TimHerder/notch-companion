import XCTest
@testable import NotchCompanion

@MainActor private final class RewindTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var calls: [(String, [String: Any])] = []
    var failing: [String: Error] = [:]
    var rewound: [String: Any] = ["rewound": true]
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        if let error = failing[method] { throw error }
        switch method {
        case "session.resume": return ["session_id": "live-resumed", "stored_session_id": params["session_id"] ?? "", "history_complete": false]
        case "session.rewind": return rewound
        default: return [:]
        }
    }
}

@MainActor final class RewindTests: XCTestCase {
    private var folder: URL!
    private var transport: RewindTransport!
    private var model: AppModel!
    private var preferences: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rewind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        transport = RewindTransport()
        suite = "rewind-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
        model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: transport, preferences: preferences)
        await model.connect()
    }
    override func tearDown() async throws {
        model.shutdown()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Three finished turns; each answer keeps its native message ID, and the second turn delegated a child.
    private func session(_ runtime: RuntimeKind = .claude) -> CompanionSession {
        var session = CompanionSession(id: "s", runtimeID: "live-s", storedID: "native-s", title: "Parser fix",
            messages: [ChatMessage(id: "u1", role: "user", text: "Fix the parser.", turnID: "u1"),
                       ChatMessage(id: "a1", role: "assistant", text: "Fixed it.", turnID: "u1", nativeID: "1b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e"),
                       ChatMessage(id: "u2", role: "user", text: "Add a test.\n\nAttached: spec.md", turnID: "u2"),
                       ChatMessage(id: "a2", role: "assistant", text: "Added one.", turnID: "u2", nativeID: "2b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e"),
                       ChatMessage(id: "u3", role: "user", text: "Run it.", turnID: "u3"),
                       ChatMessage(id: "a3", role: "assistant", text: "Passes.", turnID: "u3", nativeID: "3b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e")],
            workspacePath: folder.path)
        session.runtime = runtime
        session.state = .finished
        session.completionID = "done"
        session.tools = [ToolActivity(id: "t1", name: "Terminal", detail: "swift build", state: .finished, turnID: "u1"),
                         ToolActivity(id: "t2", name: "Terminal", detail: "swift test", state: .finished, turnID: "u2")]
        session.changes = [TurnChanges(id: "u1", workspace: folder.path, baseRevision: nil), TurnChanges(id: "u2", workspace: folder.path, baseRevision: nil)]
        session.turnEndedAt = ["u1": Date(), "u2": Date(), "u3": Date()]
        session.turnOutcome = ["u1": .finished, "u2": .finished, "u3": .failed]
        session.limitResets = ["u3": Date().addingTimeInterval(600)]
        session.planTurnID = "u3"
        session.agents = [ChildAgent(id: "c", title: "Review", state: .finished, turnID: "u2", sessionID: "child", runtime: .codex, role: "review"),
                          ChildAgent(id: "n", title: "Explore", state: .finished, turnID: "u2")]
        if runtime == .opencode {
            var info = RuntimeSessionInfo()
            var capabilities = runtime.capabilities
            capabilities.rewind = true
            info.capabilities = capabilities
            session.runtimeInfo = info
        }
        return session
    }

    private func child() -> CompanionSession {
        var child = CompanionSession(id: "child", title: "Review", workspacePath: folder.path)
        child.parentSessionID = "s"
        child.runtime = .codex
        return child
    }

    // MARK: Protocol fixtures

    func testClaudeRewindResumesTheSessionAtTheKeptAnswer() throws {
        let id = "8a7c9e3d-1f2b-4c5d-8e9f-0a1b2c3d4e5f", at = "1b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e"
        let args = try ClaudeClient.arguments(id: id, resume: true, resumeAt: at)
        XCTAssertTrue(args.contains("--resume=\(id)"))
        XCTAssertTrue(args.contains("--resume-session-at=\(at)"))
        XCTAssertFalse(args.contains("--fork-session"))
        XCTAssertFalse(try ClaudeClient.arguments(id: id, resume: false, resumeAt: at).contains { $0.hasPrefix("--resume-session-at") },
                       "a new session has nothing to truncate")
        XCTAssertThrowsError(try ClaudeClient.arguments(id: id, resume: true, resumeAt: "--continue"))
    }

    func testOpenCodeOffersRewindOnlyWithTheRevertEndpoints() {
        XCTAssertEqual(OpenCodeClient.revertPaths, ["/api/session/{sessionID}/revert/stage", "/api/session/{sessionID}/revert/commit", "/api/session/{sessionID}/revert"])
        var capabilities = RuntimeCapabilities()
        capabilities.merge(["rewind": true])
        XCTAssertEqual(capabilities.rewind, true)
        var opencode = session(.opencode)
        XCTAssertTrue(opencode.rewindsConversation)
        XCTAssertTrue(opencode.rewindsFiles)
        opencode.runtimeInfo = nil
        XCTAssertFalse(opencode.rewindsConversation, "OpenCode 1.x and servers without the endpoints do not report it")
    }

    // MARK: Availability

    func testRewindPointFollowsEachHarnesssNativeRewind() {
        let claude = session()
        XCTAssertEqual(model.rewindPoint("u2", in: claude)?.keepsNativeID, "1b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e")
        XCTAssertEqual(model.rewindPoint("u2", in: claude)?.turns, 2)
        XCTAssertNil(model.rewindPoint("u1", in: claude), "nothing before the first message to resume at")
        XCTAssertNil(model.rewindPoint("a2", in: claude), "only your messages")
        var unknown = claude
        unknown.messages[1].nativeID = nil
        XCTAssertNil(model.rewindPoint("u2", in: unknown), "the kept answer's native ID must be known")

        let opencode = session(.opencode)
        XCTAssertEqual(model.rewindPoint("u1", in: opencode)?.nativeMessageID, "msg_u1")
        XCTAssertEqual(model.rewindPoint("u1", in: opencode)?.turns, 3)
        var restored = opencode
        restored.messages[2].id = "hermes-msg_native2"
        restored.messages[2].turnID = "hermes-msg_native2"
        XCTAssertEqual(model.rewindPoint("hermes-msg_native2", in: restored)?.nativeMessageID, "msg_native2")

        let hermes = session(.hermes)
        XCTAssertNotNil(model.rewindPoint("u3", in: hermes))
        XCTAssertNil(model.rewindPoint("u2", in: hermes), "Hermes undoes only its latest turn")
        var legacy = hermes
        legacy.isLegacyPrivate = true
        XCTAssertNil(model.rewindPoint("u3", in: legacy))

        for runtime in [RuntimeKind.codex, .pi, .openclaw, .deepseek, .antigravity, .cursor, .copilot] {
            XCTAssertNil(model.rewindPoint("u2", in: session(runtime)), runtime.rawValue)
        }
        var delegated = claude
        delegated.parentSessionID = "parent"
        XCTAssertNil(model.rewindPoint("u2", in: delegated), "never for delegated children or side chats")
        var relayed = claude
        relayed.messages[2].kind = ChatMessage.agentMessage
        XCTAssertNil(model.rewindPoint("u2", in: relayed), "not for relayed messages")
        var fresh = claude
        fresh.messages.insert(ChatMessage(role: "system", text: "", kind: ChatMessage.newSession), at: 4)
        XCTAssertNil(model.rewindPoint("u2", in: fresh), "an earlier native session's messages stay")
        var fork = claude
        fork.forkedFrom = ForkRecord(sourceSessionID: "src", sourceTitle: "Src", sourceStoredID: "x", userMessageIDs: ["u1"], latest: false, answerID: "a2")
        XCTAssertNil(model.rewindPoint("u2", in: fork), "a fork's copied history is the source's")
        XCTAssertNil(model.rewindPoint("u3", in: fork), "Claude Code would keep a copied answer")
        var opencodeFork = session(.opencode)
        opencodeFork.forkedFrom = fork.forkedFrom
        XCTAssertNotNil(model.rewindPoint("u3", in: opencodeFork))
    }

    func testRewindWaitsForTheTreeQueueQuestionsGitAndTheFolder() {
        model.sessions = [session(.opencode), child()]
        XCTAssertNil(model.rewindBlocker(model.sessions[0], files: true))
        model.sessions[0].pendingSubmission = PendingSubmission(id: "p", draft: "x", userTurnCount: 3, attachmentIDs: [])
        XCTAssertEqual(model.rewindBlocker(model.sessions[0]), "Check the last send first.")
        model.sessions[0].pendingSubmission = nil
        model.sessions[0].queuedSends = [QueuedSend(id: "q", text: "Later")]
        XCTAssertEqual(model.rewindBlocker(model.sessions[0]), "Send or cancel the queued messages first.")
        model.sessions[0].queuedSends = []
        model.sessions[1].state = .working
        XCTAssertEqual(model.rewindBlocker(model.sessions[0]), "Wait for this session and its delegated work to finish.")
        model.sessions[1].state = .finished
        model.requests = [PendingRequest(id: "r", kind: .approval, title: "Run", detail: "", choices: [], sessionID: "live-s")]
        XCTAssertEqual(model.rewindBlocker(model.sessions[0]), "Answer the open question or approval first.")
        model.requests = []
        // Another session working in the same folder blocks restoring files, never the conversation alone.
        var neighbour = CompanionSession(id: "other", title: "Other", state: .working, workspacePath: folder.path)
        neighbour.runtime = .codex
        model.sessions.append(neighbour)
        XCTAssertNil(model.rewindBlocker(model.sessions[0]))
        XCTAssertNotNil(model.rewindBlocker(model.sessions[0], files: true))
    }

    // MARK: Edit from here

    func testRewindAndRestoreFilesCutsTheConversationAndReturnsTheMessage() async throws {
        let spec = folder.appendingPathComponent("spec.md")
        try Data("spec".utf8).write(to: spec)
        var rewinding = session(.opencode)
        rewinding.messages[2].attachments = [Attachment(url: spec)]
        rewinding.draft = "Newer draft"
        model.sessions = [rewinding, child()]
        var asked: String?
        model.rewindDecision = { message, files in asked = message; XCTAssertTrue(files); return .files }
        await model.editFromHere("u2", in: "s")
        XCTAssertTrue(asked?.contains("the 1 later turn after it") == true, asked ?? "")
        let call = try XCTUnwrap(transport.calls.first { $0.0 == "session.rewind" }?.1)
        XCTAssertEqual(call["message_id"] as? String, "msg_u2")
        XCTAssertEqual(call["turns"] as? Int, 2)
        XCTAssertEqual(call["files"] as? Bool, true)
        let after = model.sessions[0]
        XCTAssertEqual(after.messages.map(\.id), ["u1", "a1"])
        XCTAssertEqual(after.tools.map(\.id), ["t1"])
        XCTAssertEqual(after.changes.map(\.id), ["u1"])
        XCTAssertEqual(Set(after.turnEndedAt.keys), ["u1"])
        XCTAssertEqual(Set(after.turnOutcome.keys), ["u1"])
        XCTAssertTrue(after.limitResets.isEmpty)
        XCTAssertNil(after.planTurnID)
        XCTAssertEqual(after.state, .idle)
        XCTAssertFalse(after.hasUnreadResult)
        XCTAssertEqual(after.agents.map(\.id), ["c"], "native agents of removed turns leave; app-owned children stay")
        XCTAssertEqual(model.sessions.first { $0.id == "child" }?.isArchived, true, "children of removed turns are archived, not deleted")
        XCTAssertEqual(after.draft, "Add a test.\n\nNewer draft", "the message goes ahead of the newer draft, as a failed send does")
        XCTAssertEqual(after.attachments.map(\.url), [spec])
        XCTAssertFalse(transport.calls.contains { $0.0 == "prompt.submit" }, "never sent")
        XCTAssertFalse(model.isSubmitting("s"))
    }

    func testRewindRestoresTheConversationFromNativeHistoryWhenReported() async throws {
        model.sessions = [session(.opencode)]
        transport.rewound = ["history_complete": true, "messages": [["role": "user", "text": "Fix the parser.", "row_id": "msg_u1", "client_id": "u1"],
                                                                     ["role": "assistant", "text": "Fixed it, natively.", "row_id": "msg_a1"]]]
        model.rewindDecision = { _, _ in .conversation }
        await model.editFromHere("u2", in: "s")
        XCTAssertEqual(transport.calls.first { $0.0 == "session.rewind" }?.1["files"] as? Bool, false)
        XCTAssertEqual(model.sessions[0].messages.map(\.text), ["Fix the parser.", "Fixed it, natively."])
    }

    func testAFailedRewindChangesNothingAndShowsTheHarnesssError() async {
        model.sessions = [session()]
        let before = model.sessions[0]
        transport.failing["session.rewind"] = AppError("No such message")
        model.rewindDecision = { _, files in XCTAssertFalse(files, "Claude Code restores no files here"); return .conversation }
        await model.editFromHere("u2", in: "s")
        var expected = before
        expected.runtimeID = nil
        XCTAssertEqual(model.sessions[0], expected, "only the closed process's live alias is dropped")
        XCTAssertTrue(model.errorMessage?.contains("No such message") == true)
    }

    func testCancelLeavesEverything() async {
        model.sessions = [session()]
        let before = model.sessions[0]
        model.rewindDecision = { _, _ in .cancel }
        await model.editFromHere("u3", in: "s")
        XCTAssertEqual(model.sessions[0], before)
        XCTAssertFalse(transport.calls.contains { $0.0 == "session.rewind" })
    }

    func testClaudeKeepsItsResumePointUntilTheNextSend() async throws {
        model.sessions = [session()]
        transport.rewound = ["rewound": true, "resume_at": "2b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e"]
        model.rewindDecision = { _, _ in .conversation }
        await model.editFromHere("u3", in: "s")
        XCTAssertEqual(transport.calls.first { $0.0 == "session.rewind" }?.1["native_message_id"] as? String, "2b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e")
        XCTAssertEqual(model.sessions[0].resumeAt, "2b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e")
        XCTAssertEqual(model.sessions[0].draft, "Run it.")
        // A reopen before the next send resumes at the same answer.
        model.sessions[0].runtimeID = nil
        _ = try await model.ensureRuntime("s")
        XCTAssertEqual(transport.calls.last { $0.0 == "session.resume" }?.1["resume_at"] as? String, "2b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e")
        model.sessions[0].trustedProjectPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        model.currentID = "s"
        let sent = await model.submit(reply: nil)
        XCTAssertTrue(sent, model.errorMessage ?? "")
        XCTAssertNil(model.sessions[0].resumeAt, "the send extends the native chain from the rewind point")
    }

    func testASteerIsNotARewindPoint() {
        var opencode = session(.opencode)
        opencode.messages.insert(ChatMessage(id: "steer", role: "user", text: "Also the docs.", turnID: "u2"), at: 3)
        XCTAssertNil(model.rewindPoint("steer", in: opencode), "cutting inside a turn would drop the turn's earlier tools and changes")
        XCTAssertNotNil(model.rewindPoint("u2", in: opencode))
    }

    func testSendsInTheSameFolderWaitWhileFilesAreRestored() async {
        var other = CompanionSession(id: "other", title: "Other", draft: "Edit README", workspacePath: folder.path)
        other.runtime = .hermes
        model.sessions = [session(.opencode), other]
        model.restoringFilesSessionIDs = ["s"]
        model.currentID = "other"
        let sent = await model.submit(reply: nil)
        XCTAssertFalse(sent)
        XCTAssertEqual(model.errorMessage, "Wait for the rewind to restore files, then send.")
        XCTAssertEqual(model.sessions[1].draft, "Edit README")
    }

    func testARemovedResultNeverWakesTheParentAgain() async {
        var delegated = child()
        delegated.delegation = DelegationRecord(taskID: "task", wokenCompletionID: "result", wakeMessageID: "wake")
        var earlier = CompanionSession(id: "earlier", title: "Earlier", workspacePath: folder.path)
        earlier.parentSessionID = "s"
        earlier.delegation = DelegationRecord(taskID: "task-2", wakeMessageID: "wake-2")
        var rewinding = session(.opencode)
        rewinding.messages.insert(ChatMessage(id: "wake-2", role: "user", text: "Delegated task \"Explore\" finished", turnID: "wake-2", kind: ChatMessage.delegationResult), at: 4)
        model.sessions = [rewinding, delegated, earlier]
        model.rewindDecision = { _, _ in .conversation }
        await model.editFromHere("u2", in: "s")
        XCTAssertEqual(model.sessions.first { $0.id == "child" }?.delegation?.completionWake, false, "a child of a removed turn")
        XCTAssertEqual(model.sessions.first { $0.id == "earlier" }?.delegation?.completionWake, false, "a wake that left the conversation")
    }

    func testOlderRegistriesDecodeWithoutRewindFields() throws {
        let data = try JSONEncoder().encode(session())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "resumeAt")
        let decoded = try JSONDecoder().decode(CompanionSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.resumeAt)
        XCTAssertNil(decoded.messages[2].attachments)
    }
}
