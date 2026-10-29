import XCTest
@testable import NotchCompanion

@MainActor private final class MultiRuntimeFixture: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var connections = 0
    var calls: [(String, [String: Any])] = []
    var history: [[String: Any]]?
    var historyComplete: Bool?
    var acceptedTurnIDs: [String] = []
    var running = false
    var subagents: [[String: Any]] = []
    var parentComplete: Bool?
    var onOpen: (() -> Void)?
    func connect() async throws { connections += 1 }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        if method == "session.create" || method == "session.resume" {
            onOpen?()
            var result: [String: Any] = ["session_id": "same-id", "stored_session_id": "native-id"]
            if let history { result["messages"] = history }
            if let historyComplete { result["history_complete"] = historyComplete }
            result["accepted_turn_ids"] = acceptedTurnIDs
            result["running"] = running
            result["subagents"] = subagents
            if let parentComplete { result["parent_complete"] = parentComplete }
            return result
        }
        return [:]
    }
    func disconnect() {}
}

@MainActor final class MultiRuntimeTests: XCTestCase {
    func testUnknownRuntimeSurvivesWholeRegistryAndReencode() throws {
        let unknown = RuntimeKind(rawValue: "future-agent")!
        let original = [CompanionSession(id: "known", runtime: .codex, title: "Known"),
                        CompanionSession(id: "future", storedID: "durable", runtime: unknown, profileID: "/future",
                                         title: "Keep me", draft: "unsent")]
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([CompanionSession].self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded[1].runtime.isSupported)
        XCTAssertEqual(decoded[1].route.profileID, "/future")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sessions.json")
        try encoded.write(to: file)
        let model = AppModel(storageURL: file, playsSounds: false, client: MultiRuntimeFixture())
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.sessions[1].draft, "unsent")
        model.shutdown()
        XCTAssertEqual(try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: file))[1].runtime, unknown)
    }

    func testStartupDoesNotLaunchAnyAdapterAndOnlySelectedRouteConnects() async throws {
        var adapters: [RuntimeRoute: MultiRuntimeFixture] = [:]
        let router = RuntimeRouter { route in let adapter = MultiRuntimeFixture(); adapters[route] = adapter; return adapter }
        defer { router.disconnect() }
        try await router.connect()
        XCTAssertTrue(adapters.isEmpty)
        _ = try await router.request("session.create", params: ["runtime": "pi", "companion_id": "owned", "profile_id": "/native/pi"])
        XCTAssertEqual(adapters.count, 1)
        XCTAssertEqual(adapters.first?.key.runtime, .pi)
        XCTAssertEqual(adapters.first?.value.connections, 1)
    }

    func testEveryRuntimeAndProfileScopesNativeIDsAndApprovalReplies() async throws {
        var adapters: [RuntimeRoute: MultiRuntimeFixture] = [:]
        let router = RuntimeRouter { route in let adapter = MultiRuntimeFixture(); adapters[route] = adapter; return adapter }
        defer { router.disconnect() }
        var aliases = Set<String>()
        for runtime in RuntimeKind.allCases {
            for profile in ["/profile/one", "/profile/two"] {
                let result = try await router.request("session.create", params: ["runtime": runtime.rawValue, "companion_id": UUID().uuidString, "profile_id": profile])
                let alias = try XCTUnwrap(result["session_id"] as? String)
                XCTAssertTrue(aliases.insert(alias).inserted)
                var forwarded: [String: Any]?
                router.onEvent = { _, values in forwarded = values }
                let adapter = try XCTUnwrap(adapters[RuntimeRoute(runtime: runtime, profileID: profile)])
                adapter.onEvent?("approval.request", ["session_id": "same-id", "request_id": "same-request"])
                XCTAssertEqual(forwarded?["session_id"] as? String, alias)
                XCTAssertEqual(forwarded?["request_id"] as? String, alias + ":same-request")
                _ = try await router.request("approval.respond", params: ["session_id": alias, "request_id": alias + ":same-request", "decision": "deny"])
                XCTAssertEqual(adapter.calls.last?.1["request_id"] as? String, "same-request")
                XCTAssertEqual(adapter.calls.last?.1["session_id"] as? String, "same-id")
            }
        }
        XCTAssertEqual(aliases.count, RuntimeKind.allCases.count * 2)
    }

    func testOpaqueUnknownRouteNeverInstantiatesKnownAdapter() async {
        var factoryCalled = false
        let router = RuntimeRouter { _ in factoryCalled = true; return MultiRuntimeFixture() }
        do { try await router.connect(RuntimeRoute(runtime: RuntimeKind(rawValue: "future")!)); XCTFail() } catch {}
        XCTAssertFalse(factoryCalled)
    }

    func testMissingHistoryNeverClearsUncertainSendAndResumeKeepsFolder() async throws {
        let fixture = MultiRuntimeFixture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        await model.connect()
        model.sessions = [CompanionSession(id: "pending", storedID: "native", runtime: .pi, profileID: "/native/pi",
            pendingSubmission: .init(id: "turn", draft: "keep", userTurnCount: 1, attachmentIDs: []),
            draft: "keep", workspacePath: "/saved/project")]
        model.currentID = "pending"
        await model.send()
        XCTAssertNotNil(model.current?.pendingSubmission)
        XCTAssertEqual(model.current?.draft, "keep")
        XCTAssertEqual(fixture.calls.last?.0, "session.resume")
        XCTAssertEqual(fixture.calls.last?.1["cwd"] as? String, "/saved/project")
        XCTAssertTrue(model.errorMessage?.contains("protected from retry") == true)
        fixture.history = []; fixture.historyComplete = false
        await model.send()
        XCTAssertNotNil(model.current?.pendingSubmission)
        XCTAssertFalse(fixture.calls.contains { $0.0 == "prompt.submit" })
    }

    func testHeadlessTrustPrecedesNativeLaunchAndIsBoundToProject() async throws {
        let fixture = MultiRuntimeFixture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        await model.connect()
        await model.newSession(showPanel: false, runtime: .claude)
        model.sessions[0].workspacePath = folder.path
        model.draft = "fixture-only request"
        await model.send()
        XCTAssertEqual(model.projectTrustSessionID, model.currentID)
        XCTAssertTrue(fixture.calls.isEmpty)
        await model.trustProjectAndSend()
        XCTAssertTrue(fixture.calls.contains { $0.0 == "session.create" && $0.1["project_trusted"] as? Bool == true })
        XCTAssertTrue(fixture.calls.contains { $0.0 == "prompt.submit" })
        model.sessions[0].workspacePath = "/different/project"
        XCTAssertFalse(model.isProjectTrusted(model.sessions[0]))
    }

    func testNewContextIgnoresBillingTotalsAndKeepsUnknownDistinct() {
        var info = RuntimeSessionInfo()
        info.merge(["usage": ["last": ["totalTokens": 9999], "total_tokens": 9999]], runtime: .pi)
        XCTAssertNil(info.context)
        info.merge(["usage": ["context_used": 42, "context_max": 1000]], runtime: .pi)
        XCTAssertEqual(info.context?.used, 42)
        XCTAssertEqual(info.context?.limit, 1000)
        info.merge(["model": "new"], runtime: .pi)
        XCTAssertNil(info.context)
    }

    func testGatewayIdentitySeparatesAgentsAndEscapesPathDelimiters() {
        let first = RuntimeProfileIdentity.openClaw(directory: "/tmp/a|b", agent: "agent:one")
        let second = RuntimeProfileIdentity.openClaw(directory: "/tmp/a|b", agent: "agent:two")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(RuntimeProfileIdentity.decodeOpenClaw(first).agent, "agent:one")
        XCTAssertEqual(RuntimeProfileIdentity.decodeOpenClaw(first).directory, URL(fileURLWithPath: "/tmp/a|b").standardizedFileURL.resolvingSymlinksInPath().path)
    }

    func testNativeEnvironmentPreservesProvidersButDropsHostIdentity() {
        let env = RuntimeEnvironment.native(environment: ["PROVIDER_API_KEY": "fixture", "CODEX_THREAD_ID": "host",
            "CLAUDECODE": "1", "PATH": "/custom/bin"], runtime: .pi, profileID: "/native/pi")
        XCTAssertEqual(env["PROVIDER_API_KEY"], "fixture")
        XCTAssertNil(env["CODEX_THREAD_ID"]); XCTAssertNil(env["CLAUDECODE"])
        XCTAssertEqual(env["PI_CODING_AGENT_DIR"], "/native/pi")
        XCTAssertTrue(env["PATH"]?.contains("/custom/bin") == true)
    }

    func testClaudeDefaultLoginNamespaceAndExplicitNativeProfilesArePreserved() {
        let profile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
            .standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertNil(RuntimeEnvironment.native(environment: [:], runtime: .claude, profileID: profile)["CLAUDE_CONFIG_DIR"])
        let explicitDefault = profile + "/"
        XCTAssertEqual(RuntimeEnvironment.native(environment: ["CLAUDE_CONFIG_DIR": explicitDefault], runtime: .claude,
                                                 profileID: profile)["CLAUDE_CONFIG_DIR"], explicitDefault)
        XCTAssertNil(RuntimeEnvironment.native(environment: ["CLAUDE_CONFIG_DIR": "/native/other"], runtime: .claude,
                                               profileID: profile)["CLAUDE_CONFIG_DIR"], "Selecting the ordinary default must not inherit another profile's login namespace")
        let custom = URL(fileURLWithPath: "/native/claude").standardizedFileURL.resolvingSymlinksInPath().path
        let nativeCustom = "/native/claude/./"
        XCTAssertEqual(RuntimeEnvironment.native(environment: ["CLAUDE_CONFIG_DIR": nativeCustom], runtime: .claude,
                                                 profileID: custom)["CLAUDE_CONFIG_DIR"], nativeCustom)
        XCTAssertEqual(RuntimeEnvironment.native(environment: ["CLAUDE_CONFIG_DIR": "/native/other"], runtime: .claude,
                                                 profileID: custom)["CLAUDE_CONFIG_DIR"], custom)
    }

    func testUnknownNativeChildActivitySurvivesParentCompletionAndRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("sessions.json")
        let fixture = MultiRuntimeFixture()
        var model = AppModel(storageURL: file, playsSounds: false, client: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        model.sessions = [CompanionSession(id: "local", runtimeID: "live", storedID: "native", runtime: .opencode, draft: "keep this")]
        model.currentID = "local"
        model.receive("runtime.activity_unverified", payload: ["session_id": "live", "message": "Check children in native OpenCode"])
        XCTAssertEqual(try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: file)).first?.nativeActivityUnverified,
                       "Check children in native OpenCode", "The protection must persist immediately, before a crash")
        model.receive("approval.request", payload: ["session_id": "live", "request_id": "child-request", "choices": ["deny"]])
        model.receive("message.complete", payload: ["session_id": "live", "text": "Parent response", "status": "complete"])
        XCTAssertEqual(model.requests.first?.id, "child-request", "A parent result cannot expire its live child's permission")
        XCTAssertEqual(model.current?.displayState, .waiting)
        XCTAssertTrue(model.hasActiveWork)
        XCTAssertFalse(model.current?.hasUnreadCompletion ?? true)
        model.shutdown()
        model = AppModel(storageURL: file, playsSounds: false, client: fixture)
        XCTAssertEqual(model.current?.nativeActivityUnverified, "Check children in native OpenCode")
        XCTAssertEqual(model.current?.displayState, .waiting)
        await model.send()
        XCTAssertTrue(fixture.calls.isEmpty)
        XCTAssertEqual(model.current?.draft, "keep this")
    }

    func testMultipleAnswersKeepCommaContainingChoicesIntactThroughRouting() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = MultiRuntimeFixture()
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let request = PendingRequest(id: "question", kind: .clarification, title: "Choose", detail: "Choose values",
                                     choices: ["Blue, green", "Red"], sessionID: "live", multiSelect: true)
        model.requests = [request]
        var draft = ClarificationAnswerState()
        draft.choose("Blue, green", multiple: true); draft.choose("Red", multiple: true)
        let answers = draft.answers(choices: request.choices, multiple: true)
        await model.answer(request, choice: draft.answer(choices: request.choices, multiple: true), answers: answers)
        XCTAssertEqual(fixture.calls.last?.1["answers"] as? [String], ["Blue, green", "Red"])
        XCTAssertTrue(model.requests.isEmpty)
    }

    func testOpeningPinsCapturedWorkingDirectoryDespiteSettingsChange() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = MultiRuntimeFixture()
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        await model.connect()
        model.workspacePath = "/project/original"
        model.draft = "hello"
        fixture.onOpen = { [weak model] in model?.workspacePath = "/project/changed" }
        await model.send()
        XCTAssertEqual(model.current?.workspacePath, "/project/original")
        XCTAssertEqual(fixture.calls.first?.1["cwd"] as? String, "/project/original")
    }

    func testUnknownSetupCannotResolveToHermesSettings() {
        let unknown = RuntimeKind(rawValue: "future-agent")!
        XCTAssertNotEqual(unknown.installationLocation, .hermesSource)
        XCTAssertNotEqual(unknown.profileLocation, .hermesProfile)
        XCTAssertThrowsError(try unknown.profileLocation.validate("/tmp"))
    }

    func testDefaultOpenClawDraftUsesNativeWorkspaceAtLaunchAndAfterDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = directory.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data(#"{"agents":{"list":[{"id":"native","default":true,"workspace":"/native/project"}]}}"#.utf8)
            .write(to: profile.appendingPathComponent("openclaw.json"))
        let suite = "notch-multi-default-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set("openclaw", forKey: "runtime.default")
        preferences.set(profile.path, forKey: RuntimeLocation.openclawProfile.rawValue)
        let model = AppModel(storageURL: directory.appendingPathComponent("sessions.json"), playsSounds: false,
                             client: MultiRuntimeFixture(), preferences: preferences)
        defer { model.shutdown(); preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(model.current?.workspacePath, "/native/project")
        model.deleteSession(try XCTUnwrap(model.currentID))
        XCTAssertEqual(model.current?.workspacePath, "/native/project")
    }

    func testExactNativeReceiptConfirmsPartialHistoryWithoutInventingCompletion() async throws {
        for isRunning in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let fixture = MultiRuntimeFixture()
            fixture.history = []; fixture.historyComplete = false
            fixture.acceptedTurnIDs = ["pending-turn"]; fixture.running = isRunning
            let model = AppModel(storageURL: directory.appendingPathComponent("sessions.json"), playsSounds: false, client: fixture)
            defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
            await model.connect()
            let transcript = [ChatMessage(id: "old", role: "assistant", text: "Preserve previous context"),
                              ChatMessage(id: "pending-turn", role: "user", text: "exact prompt", turnID: "pending-turn")]
            model.sessions = [CompanionSession(id: "local", storedID: "native", runtime: .openclaw, profileID: "/native",
                pendingSubmission: .init(id: "pending-turn", draft: "exact prompt", userTurnCount: 7, attachmentIDs: []),
                state: .interrupted, messages: transcript, draft: "exact prompt", workspacePath: "/project")]
            model.currentID = "local"
            await model.send()
            XCTAssertNil(model.current?.pendingSubmission)
            XCTAssertEqual(model.current?.draft, "")
            XCTAssertEqual(model.current?.messages, transcript, "A partial native snapshot cannot replace preserved history")
            XCTAssertEqual(model.current?.state, isRunning ? .working : .interrupted)
            XCTAssertFalse(model.current?.hasUnreadCompletion ?? true)
            XCTAssertEqual(fixture.calls.last?.1["pending_turn_id"] as? String, "pending-turn")
            XCTAssertFalse(fixture.calls.contains { $0.0 == "prompt.submit" }, "Checking delivery never resubmits")
        }
    }

    func testAbsentOrSimilarReceiptsNeverProveNonDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = MultiRuntimeFixture()
        fixture.history = []; fixture.historyComplete = false
        let model = AppModel(storageURL: directory.appendingPathComponent("sessions.json"), playsSounds: false, client: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await model.connect()
        model.sessions = [CompanionSession(id: "local", storedID: "native", runtime: .openclaw, profileID: "/native",
            pendingSubmission: .init(id: "pending-turn", draft: "keep", userTurnCount: 1, attachmentIDs: []), draft: "keep")]
        model.currentID = "local"
        for receipts in [[], ["pending-turn-other"], [" pending-turn"], ["PENDING-TURN"]] {
            fixture.acceptedTurnIDs = receipts
            await model.send()
            XCTAssertNotNil(model.current?.pendingSubmission)
            XCTAssertEqual(model.current?.draft, "keep")
        }
        XCTAssertFalse(fixture.calls.contains { $0.0 == "prompt.submit" })
    }

    func testNativeChildSnapshotReplacesTextAndRetainsTurnIdentity() {
        var session = CompanionSession(messages: [ChatMessage(id: "current", role: "user", text: "current", turnID: "current")],
            agents: [ChildAgent(id: "old-child", nativeID: "native-child", title: "Existing", state: .interrupted,
                                tools: [ToolActivity(id: "tool", name: "Read", detail: "file")], text: "before", turnID: "old-turn")])
        let snapshots: [[String: Any]] = [["id": "native-child", "name": "Existing", "text": "native snapshot", "status": "error"],
                                         ["id": "new-active", "name": "Active", "text": "working", "status": "waiting"],
                                         ["id": "old-terminal", "name": "Previous", "text": "done", "status": "error"]]
        AppModel.mergeNativeSubagents(snapshots, into: &session)
        AppModel.mergeNativeSubagents(snapshots, into: &session)
        XCTAssertEqual(session.agents.count, 3)
        XCTAssertEqual(session.agents[0].id, "old-child")
        XCTAssertEqual(session.agents[0].text, "native snapshot")
        XCTAssertEqual(session.agents[0].turnID, "old-turn")
        XCTAssertEqual(session.agents[0].tools.first?.state, .failed)
        XCTAssertEqual(session.agents[1].turnID, "current")
        XCTAssertNil(session.agents[2].turnID)
        XCTAssertTrue(session.failedCurrentAgents.isEmpty)
    }

    func testResumeWithActiveChildBlocksSendUntilThatChildSettles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = MultiRuntimeFixture()
        fixture.subagents = [["id": "child", "name": "Native child", "text": "waiting", "status": "waiting"]]
        fixture.parentComplete = true
        let model = AppModel(storageURL: directory.appendingPathComponent("sessions.json"), playsSounds: false, client: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await model.connect()
        model.sessions = [CompanionSession(id: "local", storedID: "native", runtime: .opencode, profileID: "/native", draft: "next prompt")]
        model.currentID = "local"
        await model.send()
        XCTAssertEqual(model.current?.state, .waiting)
        XCTAssertEqual(model.current?.parentTurnComplete, true)
        XCTAssertEqual(model.current?.draft, "next prompt")
        XCTAssertFalse(fixture.calls.contains { $0.0 == "prompt.submit" })
        model.receive("subagent.complete", payload: ["session_id": "same-id", "subagent_id": "child", "status": "complete", "text": "done"])
        XCTAssertFalse(model.hasActiveWork)
        XCTAssertEqual(model.current?.state, .finished)
    }

    func testInterimNativeMessagePreservesTextWithoutSettlingQueuedWork() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storageURL: directory.appendingPathComponent("sessions.json"), playsSounds: false, client: MultiRuntimeFixture())
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        model.sessions = [CompanionSession(id: "local", runtimeID: "live", runtime: .pi, state: .working,
            messages: [ChatMessage(role: "user", text: "work"), ChatMessage(role: "assistant", text: "partial")], parentTurnComplete: false)]
        model.currentID = "local"
        model.receive("message.interim", payload: ["session_id": "live", "text": "authoritative interim", "already_streamed": true])
        XCTAssertEqual(model.current?.latestResponse, "authoritative interim")
        XCTAssertEqual(model.current?.state, .working)
        XCTAssertFalse(model.current?.parentTurnComplete ?? true)
        XCTAssertFalse(model.current?.hasUnreadCompletion ?? true)
        model.receive("message.complete", payload: ["session_id": "live", "text": "settled result", "status": "complete"])
        XCTAssertEqual(model.current?.state, .finished)
        XCTAssertEqual(model.current?.latestResponse, "settled result")
    }
}
