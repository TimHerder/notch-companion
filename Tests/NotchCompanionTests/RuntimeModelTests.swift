import XCTest
@testable import NotchCompanion

@MainActor private final class ModelFixture: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var calls: [(String, [String: Any])] = []
    var needsConfirmation = false
    var rejectSelection = false
    let choice = RuntimeModelChoice(model: "next-model", provider: "configured")
    var catalog: RuntimeModelCatalog {
        RuntimeModelCatalog(defaultModel: RuntimeModelChoice(model: "profile-model", provider: "configured"),
            models: [RuntimeModelOption(choice: choice, title: "Next model", reasoningEfforts: ["low", "high"])])
    }
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() { onConnectionChange?(false, nil) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        switch method {
        case "runtime.models": return ["catalog": catalog]
        case "session.create", "session.resume":
            return ["session_id": "live", "stored_session_id": "saved", "info": ["model": "profile-model", "provider": "configured"]]
        case "session.model.set":
            if rejectSelection { throw AppError("Model is unavailable") }
            return ["confirm_required": needsConfirmation && params["confirmed"] as? Bool != true, "confirm_message": "Runtime selection warning"]
        default: return [:]
        }
    }
}

@MainActor final class RuntimeModelTests: XCTestCase {
    func testModelSearchMatchesNamesAndIDsWithoutChangingCatalog() {
        let alpha = RuntimeModelOption(choice: RuntimeModelChoice(model: "model-a"), title: "Alpha", reasoningEfforts: ["low", "high"])
        let beta = RuntimeModelOption(choice: RuntimeModelChoice(model: "model-b"), title: "Beta")
        let catalog = RuntimeModelCatalog(defaultModel: alpha.choice, models: [alpha, beta])
        XCTAssertEqual(catalog.matchingModels(""), [alpha, beta])
        XCTAssertEqual(catalog.matchingModels("ALPHA"), [alpha])
        XCTAssertEqual(catalog.matchingModels("MODEL-B"), [beta])
        XCTAssertEqual(catalog.matchingModels("missing"), [])
        XCTAssertEqual(catalog.models, [alpha, beta])
        XCTAssertEqual(catalog.defaultModel, alpha.choice)
    }

    func testCatalogDefaultsProviderScopingAndSessionFlagInjection() {
        let hermes = RuntimeModelCatalog.hermes(["model": "preferred", "provider": "custom:local", "providers": [
            ["slug": "local", "aliases": ["custom:local"], "models": ["preferred", "small", "small", "bad --global"]],
            ["slug": "another-oauth-provider", "models": ["unrelated"]]
        ]])
        XCTAssertEqual(hermes.models.map(\.choice.model), ["preferred", "small"])
        XCTAssertEqual(hermes.defaultModel?.provider, "custom:local")
        XCTAssertEqual(hermes.defaultModel?.hermesSessionValue, "preferred --provider custom:local --session")
        XCTAssertNil(RuntimeModelChoice(model: "unscoped").hermesSessionValue)
        XCTAssertNil(RuntimeModelChoice(model: "x", provider: "p --global").hermesSessionValue)
        let codex = RuntimeModelCatalog.codex(config: ["model": "configured", "model_context_window": 123000], rows: [
            ["model": "recommended", "displayName": "Recommended", "isDefault": true],
            ["model": "hidden", "hidden": true], ["model": "recommended"]
        ])
        XCTAssertEqual(codex.defaultModel?.model, "configured")
        XCTAssertEqual(codex.models.map(\.choice.model), ["recommended"])
        XCTAssertEqual(codex.configuredContextWindow, 123000)
    }

    func testCodexTransmitsPerThreadEffortOnEveryTurnAndCanReplaceIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-codex-effort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("codex-peer")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys
        count = 0
        for line in sys.stdin:
            frame = json.loads(line)
            if "id" not in frame: continue
            method, params = frame["method"], frame.get("params", {})
            result = {}
            if method == "thread/start":
                count += 1
                result = {"thread": {"id": "thread-" + str(count)}}
            if method == "turn/start":
                with open(os.path.join(os.environ["CODEX_HOME"], "turns.jsonl"), "a") as f:
                    f.write(json.dumps(params) + "\n")
                result = {"turn": {"id": "turn", "status": "completed"}}
            print(json.dumps({"id": frame["id"], "result": result}), flush=True)
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = CodexClient(profileID: folder.path, executable: executable)
        defer { client.disconnect() }
        try await client.connect()
        let first = try await client.request("session.create", params: [:])["session_id"] as! String
        let second = try await client.request("session.create", params: [:])["session_id"] as! String
        for (sid, effort) in [(first, "high"), (second, "low"), (first, "medium")] {
            _ = try await client.request("session.model.set", params: ["session_id": sid, "model": "fixture", "reasoning_effort": effort])
            _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "fixture"])
        }
        let lines = try String(contentsOf: folder.appendingPathComponent("turns.jsonl")).split(separator: "\n")
        let turns = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(turns.compactMap { $0["effort"] as? String }, ["high", "low", "medium"])
        XCTAssertEqual(turns.compactMap { $0["threadId"] as? String }, [first, second, first])
        XCTAssertTrue(turns.allSatisfy { $0["model"] as? String == "fixture" })
    }

    func testReasoningCatalogValidationAndBackwardCompatiblePersistence() throws {
        let codex = RuntimeModelCatalog.codex(config: [:], rows: [
            ["model": "reasoner", "defaultReasoningEffort": "high", "supportedReasoningEfforts": [
                ["reasoningEffort": "low"], ["reasoningEffort": "high"], ["reasoningEffort": "ultra"]]],
            ["model": "plain"]])
        XCTAssertEqual(codex.models[0].reasoningEfforts, ["low", "high", "ultra"])
        XCTAssertEqual(codex.models[0].defaultReasoningEffort, "high")
        XCTAssertTrue(codex.contains(RuntimeModelChoice(model: "reasoner", reasoningEffort: "ultra")))
        XCTAssertFalse(codex.contains(RuntimeModelChoice(model: "plain", reasoningEffort: "high")))
        XCTAssertFalse(codex.contains(RuntimeModelChoice(model: "reasoner", reasoningEffort: "invented")))
        let old = try JSONDecoder().decode(RuntimeModelChoice.self, from: Data(#"{"model":"old"}"#.utf8))
        XCTAssertNil(old.reasoningEffort)
        let choice = RuntimeModelChoice(model: "reasoner", reasoningEffort: "high")
        XCTAssertEqual(try JSONDecoder().decode(RuntimeModelChoice.self, from: JSONEncoder().encode(choice)), choice)
        let hermes = RuntimeModelCatalog.hermes(["provider": "native", "model": "mandatory", "reasoning_efforts": ["none", "high"], "providers": [
            ["slug": "native", "models": ["mandatory", "plain"], "capabilities": [
                "mandatory": ["reasoning": true, "can_disable_reasoning": false], "plain": ["reasoning": false]]]]])
        XCTAssertEqual(hermes.models[0].reasoningEfforts, ["high"])
        XCTAssertTrue(hermes.models[1].reasoningEfforts.isEmpty)
    }

    func testHermesEffortIsValidatedAndAppliedToSessionOnlyAfterModel() async throws {
        let choice = RuntimeModelChoice(model: "chosen", provider: "native", reasoningEffort: "high")
        var changes: [String] = []
        _ = try await SharedHermesClient.setSessionModel(choice, sessionID: "owned", confirmed: false) { method, params in
            switch method {
            case "model.options": return ["model": "chosen", "provider": "native", "reasoning_efforts": ["low", "high"], "providers": [["slug": "native", "models": ["chosen"]]]]
            case "session.activate": return ["info": ["model": "chosen", "provider": "native"]]
            case "config.set":
                let key = params["key"] as! String
                changes.append(key)
                if key == "reasoning" {
                    XCTAssertEqual(params["scope"] as? String, "session")
                    XCTAssertEqual(params["session_id"] as? String, "owned")
                    XCTAssertEqual(params["value"] as? String, "high")
                }
                return ["value": params["value"]!]
            default: XCTFail("Unexpected RPC"); return [:]
            }
        }
        XCTAssertEqual(changes, ["model", "reasoning"])
        do {
            _ = try await SharedHermesClient.setSessionModel(choice, sessionID: "owned", confirmed: false) { method, _ in
                XCTAssertEqual(method, "model.options", "An unsupported effort cannot mutate the native session")
                return ["model": "chosen", "provider": "native"]
            }
            XCTFail("Unsupported effort was accepted")
        } catch {}
    }

    func testHermesPinsConfiguredProviderAfterInitializationAndVerifiesAppliedRoute() async throws {
        let choice = RuntimeModelChoice(model: "gpt-6-luna", provider: "openai-codex")
        var calls: [String] = []
        var activations = 0
        _ = try await SharedHermesClient.setSessionModel(choice, sessionID: "owned", confirmed: false) { method, params in
            calls.append(method)
            switch method {
            case "model.options":
                XCTAssertNil(params["session_id"], "Use the configured provider even when a broken session drifted to OpenRouter")
                return ["model": "default", "provider": "openai-codex", "providers": [
                    ["slug": "openai-codex", "models": ["gpt-6-luna"]]]]
            case "session.activate":
                XCTAssertEqual(params["session_id"] as? String, "owned")
                XCTAssertEqual(params["omit_messages"] as? Bool, true)
                activations += 1
                if activations == 1 { return ["info": ["lazy": true]] }
                return ["info": ["model": activations == 2 ? "openai/gpt-6-luna" : choice.model,
                                 "provider": activations == 2 ? "openrouter" : choice.provider!]]
            case "config.set":
                XCTAssertEqual(activations, 2, "Never race the deferred default-model build")
                XCTAssertEqual(params["value"] as? String, "gpt-6-luna --provider openai-codex --session")
                XCTAssertEqual(params["confirm_expensive_model"] as? Bool, false)
                return ["value": choice.model]
            default: XCTFail("Unexpected RPC: \(method)"); return [:]
            }
        }
        XCTAssertEqual(calls, ["model.options", "session.activate", "session.activate", "config.set", "session.activate"])
    }

    func testHermesModelConfirmationBusyAndMismatchedRouteCannotSubmit() async throws {
        let choice = RuntimeModelChoice(model: "chosen", provider: "openai-codex")
        for scenario in ["confirmation", "busy", "deferred", "mismatch"] {
            var switched = false
            do {
                let result = try await SharedHermesClient.setSessionModel(choice, sessionID: "owned", confirmed: false) { method, _ in
                    switch method {
                    case "model.options": return ["model": choice.model, "provider": choice.provider!]
                    case "session.activate":
                        if switched { XCTAssertEqual(scenario, "mismatch") }
                        return ["running": scenario == "busy", "info": ["model": "old", "provider": "openrouter"]]
                    case "config.set":
                        switched = true
                        return ["confirm_required": scenario == "confirmation", "deferred": scenario == "deferred"]
                    default: XCTFail("Unexpected RPC: \(method)"); return [:]
                    }
                }
                XCTAssertEqual(scenario, "confirmation")
                XCTAssertEqual(result["confirm_required"] as? Bool, true)
            } catch {
                if scenario == "busy" || scenario == "deferred" { XCTAssertTrue(error is NativeSessionBusy) }
                else { XCTAssertEqual(scenario, "mismatch") }
            }
            XCTAssertEqual(switched, scenario != "busy")
        }
    }

    func testContextUsesLatestRequestNotCumulativeAndClearsOnModelChange() throws {
        let sample = try XCTUnwrap(RuntimeContextUsage.codex([
            "last": ["totalTokens": 1200], "total": ["totalTokens": 900000], "modelContextWindow": 10000]))
        XCTAssertEqual(sample.used, 1200)
        XCTAssertEqual(sample.fraction, 0.12)
        XCTAssertNil(RuntimeContextUsage.codex(["total": ["totalTokens": 999]]))
        XCTAssertNil(RuntimeContextUsage.hermes(["context_used": -1, "context_max": 0]))
        XCTAssertEqual(RuntimeContextUsage.hermes(["context_used": 0])?.used, 0)
        var info = RuntimeSessionInfo(model: "old", context: sample)
        info.merge(["model": "new"], runtime: .codex)
        XCTAssertNil(info.context)
        info.merge(["usage": ["context_used": 500, "context_max": 8000, "context_estimated": true]], runtime: .hermes)
        XCTAssertTrue(info.context?.estimated == true)
        XCTAssertEqual(info.context?.limit, 8000)
        info.merge(["usage": ["context_used": 50, "context_max": 8000]], runtime: .hermes)
        XCTAssertEqual(info.context?.used, 50, "Compaction can decrease the snapshot")
    }

    func testUsageOwnershipLateCompletionAndStaleTurnFiltering() throws {
        var state = CodexProtocolState()
        _ = try state.register(["id": "parent"])
        _ = state.notifications("thread/started", ["thread": ["id": "child", "parentThreadId": "parent"]])
        _ = state.notifications("turn/started", ["threadId": "parent", "turn": ["id": "t1"]])
        _ = state.notifications("turn/completed", ["threadId": "parent", "turn": ["id": "t1", "status": "completed"]])
        let usage: [String: Any] = ["last": ["totalTokens": 123], "modelContextWindow": 1000]
        XCTAssertEqual(state.notifications("thread/tokenUsage/updated", ["threadId": "parent", "turnId": "t1", "tokenUsage": usage]).first?.name, "session.info")
        XCTAssertTrue(state.notifications("thread/tokenUsage/updated", ["threadId": "child", "turnId": "c1", "tokenUsage": usage]).isEmpty)
        XCTAssertTrue(state.notifications("thread/tokenUsage/updated", ["threadId": "unowned", "turnId": "x", "tokenUsage": usage]).isEmpty)
        _ = state.notifications("turn/started", ["threadId": "parent", "turn": ["id": "t2"]])
        XCTAssertTrue(state.notifications("thread/tokenUsage/updated", ["threadId": "parent", "turnId": "t1", "tokenUsage": usage]).isEmpty)
    }

    func testSelectionPersistsIsSessionScopedAndAppliesBeforeSend() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "notch-model-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let transport = ModelFixture()
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: transport, preferences: preferences)
        defer { model.shutdown(); preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(model.showModelPicker && model.showContextUsage, "Both controls start on")
        model.showContextUsage = false
        await model.connect()
        let session = try XCTUnwrap(model.current)
        let key = model.modelCatalogKey(for: session)
        await model.loadModels(for: key)
        XCTAssertEqual(transport.calls.map(\.0), ["runtime.models"], "Catalog reads must not create sessions")
        model.draft = "Keep the draft"
        var selection = transport.choice
        selection.reasoningEffort = "high"
        model.setModel(selection, for: session.id)
        var invalid = selection
        invalid.reasoningEffort = "unsupported"
        model.setModel(invalid, for: session.id)
        XCTAssertEqual(model.current?.draft, "Keep the draft")
        XCTAssertNil(model.current?.storedID)
        XCTAssertEqual(model.current?.modelOverride, selection)
        model.setRuntime(session.runtime, for: session.id)
        XCTAssertEqual(model.current?.modelOverride, selection, "Pressing the selected runtime must retain the model")
        await model.send()
        XCTAssertEqual(Array(transport.calls.map(\.0).suffix(3)), ["session.create", "session.model.set", "prompt.submit"])
        XCTAssertEqual(transport.calls.first(where: { $0.0 == "session.model.set" })?.1["model"] as? String, "next-model")
        XCTAssertEqual(transport.calls.first(where: { $0.0 == "session.model.set" })?.1["reasoning_effort"] as? String, "high")
        XCTAssertFalse(model.canChangeModel(session.id))
        model.setModel(nil, for: session.id)
        XCTAssertEqual(model.current?.modelOverride, selection)
        model.shutdown()
        let restored = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: ModelFixture(), preferences: preferences)
        defer { restored.shutdown() }
        XCTAssertTrue(restored.showModelPicker)
        XCTAssertFalse(restored.showContextUsage, "An explicit off persists")
        XCTAssertEqual(restored.current?.modelOverride, selection)
        await restored.newSession(showPanel: false, runtime: .codex)
        XCTAssertNil(restored.current?.modelOverride, "New sessions inherit their own runtime, not another conversation's pick")
    }

    func testChangingDraftRuntimeClearsModelButKeepsDraftAndFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: ModelFixture())
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let session = try XCTUnwrap(model.current)
        model.sessions[0].modelOverride = RuntimeModelChoice(model: "chosen")
        model.sessions[0].runtimeInfo = RuntimeSessionInfo(model: "reported")
        model.sessions[0].draft = "Draft"
        model.sessions[0].attachments = [Attachment(url: URL(fileURLWithPath: "/tmp/file"))]
        model.setRuntime(session.runtime == .hermes ? .codex : .hermes, for: session.id)
        XCTAssertNil(model.current?.modelOverride)
        XCTAssertNil(model.current?.runtimeInfo)
        XCTAssertEqual(model.current?.draft, "Draft")
        XCTAssertEqual(model.current?.attachments.count, 1)
    }

    func testClaudeAppliesDefaultEffortEvenWhenTheModelAlreadyMatches() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transport = ModelFixture()
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        await model.connect()
        await model.newSession(showPanel: false, runtime: .claude)
        model.sessions[0].workspacePath = folder.path
        model.sessions[0].trustedProjectPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let session = try XCTUnwrap(model.current)
        await model.loadModels(for: model.modelCatalogKey(for: session))
        model.setModel(transport.catalog.defaultModel, for: session.id)
        model.draft = "Use the default effort"
        await model.send()
        XCTAssertEqual(Array(transport.calls.map(\.0).suffix(3)), ["session.create", "session.model.set", "prompt.submit"])
        let selection = try XCTUnwrap(transport.calls.first { $0.0 == "session.model.set" }?.1)
        XCTAssertEqual(selection["model"] as? String, "profile-model")
        XCTAssertNil(selection["reasoning_effort"], "Omitted effort must still reach Claude to clear an earlier override")
    }

    func testFailedOrDeclinedModelChangeCannotSubmitOrConsumeDraft() async throws {
        for reject in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let transport = ModelFixture()
            transport.needsConfirmation = true
            transport.rejectSelection = reject
            let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: transport)
            defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
            await model.connect()
            let session = try XCTUnwrap(model.current)
            await model.loadModels(for: model.modelCatalogKey(for: session))
            model.setModel(transport.choice, for: session.id)
            model.modelChangeDecision = { _ in false }
            model.draft = "Preserve this"
            await model.send()
            XCTAssertFalse(transport.calls.contains { $0.0 == "prompt.submit" })
            XCTAssertEqual(model.current?.draft, "Preserve this")
            XCTAssertNil(model.current?.pendingSubmission)
            XCTAssertTrue(model.current?.messages.isEmpty == true)
            if !reject { XCTAssertEqual(model.current?.state, .idle) }
            else {
                XCTAssertTrue(model.current!.hasUnreadFailure)
                model.setSessionVisibility(notchVisible: true)
                XCTAssertTrue(model.sessionIndicators.isEmpty)
                let readReceipt = model.current?.completionID
                model.setSessionVisibility(notchVisible: false)
                await model.send()
                XCTAssertNotEqual(model.current?.completionID, readReceipt, "A separate rejected send needs a new receipt even without a submitted turn")
                XCTAssertTrue(model.current!.hasUnreadFailure)
                XCTAssertFalse(transport.calls.contains { $0.0 == "prompt.submit" })
            }
        }
    }

    func testConfirmedNativeWarningRetriesOnlyModelChangeBeforeOnePrompt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transport = ModelFixture()
        transport.needsConfirmation = true
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        await model.connect()
        let session = try XCTUnwrap(model.current)
        await model.loadModels(for: model.modelCatalogKey(for: session))
        model.setModel(transport.choice, for: session.id)
        model.modelChangeDecision = { $0 == "Runtime selection warning" }
        model.draft = "Send once"
        await model.send()
        let changes = transport.calls.filter { $0.0 == "session.model.set" }
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.last?.1["confirmed"] as? Bool, true)
        XCTAssertEqual(transport.calls.filter { $0.0 == "prompt.submit" }.count, 1)
    }
}
