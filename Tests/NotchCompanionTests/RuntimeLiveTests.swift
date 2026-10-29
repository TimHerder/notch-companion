import XCTest
@testable import NotchCompanion

/// Opt-in account-backed checks. Uses production AppModel/router/adapters with a
/// temporary UI registry and clearly titled native conversations. No live app
/// state or pre-existing conversation is touched.
@MainActor
final class RuntimeLiveTests: XCTestCase {
    private var nativeTemporaryDirectory: URL {
        // Foundation shortens /private/var attachments to /var, which native
        // OpenCode correctly treats as outside its POSIX cwd. A disposable
        // cache workspace avoids that alias without overriding permissions.
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
    }

    private func liveModel(storageURL: URL) -> AppModel {
        // XCTest's executable cannot run the app's ownership helper. Use the
        // same built app executable as the offline HTTP/supervisor tests.
        let supervisor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/NotchCompanion")
        return AppModel(storageURL: storageURL, playsSounds: false,
                        client: RuntimeRouter(opencodeSupervisorURL: supervisor))
    }

    private func selectedRuntimes() throws -> [RuntimeKind] {
        guard let names = ProcessInfo.processInfo.environment["NOTCH_LIVE_RUNTIMES"] else { return [.hermes, .codex] }
        let values = names.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !values.isEmpty, values.allSatisfy({ RuntimeKind(rawValue: $0)?.isSupported == true }) else {
            throw AppError("NOTCH_LIVE_RUNTIMES must explicitly name supported runtime IDs; unknown targets never skip silently.")
        }
        return values.compactMap(RuntimeKind.init(rawValue:))
    }

    func testBusyComposerSteeringAndQueue() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_BUSY_INPUT_TEST"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_BUSY_INPUT_TEST=1 for native steering and queued follow-up checks.")
        }
        for runtime in try selectedRuntimes() {
            let folder = nativeTemporaryDirectory.appendingPathComponent("notch-busy-input-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let model = liveModel(storageURL: folder.appendingPathComponent("sessions.json"))
            defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
            await model.connect()
            await model.newSession(showPanel: false, runtime: runtime)
            model.sessions[0].workspacePath = folder.path
            if runtime.requiresProjectTrust { model.sessions[0].trustedProjectPath = folder.path }
            model.renameSession(try XCTUnwrap(model.currentID), title: "Notch Companion steering and queue verification")
            model.draft = "This is a message delivery test. Run exactly one shell command: sleep 8. Then reply ORIGINAL_REPLY. Do not read or change files, memory, settings or delegate work."
            await model.send()
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline && model.current?.isBusy == true {
                if let request = model.currentRequest {
                    guard request.kind == .approval, request.detail.contains("sleep 8"), request.choices.contains("once") else { throw AppError("Unexpected live test interaction: \(request.title)") }
                    await model.answer(request, choice: "once")
                }
                if model.current?.canSteer == true, model.currentRequest == nil,
                   model.current?.tools.contains(where: { $0.state == .working }) == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(model.current?.tools.contains(where: { $0.state == .working }) == true, model.errorMessage ?? "No running test tool for \(runtime.title)")
            guard model.current?.canSteer == true else { throw AppError(model.errorMessage ?? "\(runtime.title) did not reach a steerable turn") }
            model.draft = "New instruction: after the running command finishes, reply exactly STEERING_RECEIVED instead of ORIGINAL_REPLY. Do not run any more tools."
            await model.send()
            XCTAssertNil(model.current?.pendingSubmission, model.errorMessage ?? "Unconfirmed steering")
            XCTAssertEqual(model.draft, "", model.errorMessage ?? runtime.title)
            model.draft = "Reply exactly QUEUED_RECEIVED. Do not use tools."
            await model.send(queue: true)
            try await settle(model)
            XCTAssertEqual(model.current?.state, .finished, model.errorMessage ?? runtime.title)
            XCTAssertTrue(model.current?.messages.contains { $0.role == "assistant" && $0.text.contains("STEERING_RECEIVED") } == true, "\(runtime.title) did not follow steering")
            XCTAssertFalse(model.current?.messages.contains { $0.role == "assistant" && $0.text.contains("ORIGINAL_REPLY") } == true,
                           "\(runtime.title) finished the original instruction before processing steering")
            XCTAssertTrue(model.current?.latestResponse.contains("QUEUED_RECEIVED") == true, "\(runtime.title) did not deliver its queued follow-up")
            XCTAssertTrue(model.current?.queuedSends.isEmpty == true)
            print("BUSY INPUT VERIFIED: \(runtime.title), native steer acknowledged and applied; queued follow-up completed")
        }
    }

    func testPiModelsBeforeFirstMessage() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_PI_CATALOG_TEST"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_PI_CATALOG_TEST=1 to read the installed Pi catalog without sending a prompt.")
        }
        let folder = nativeTemporaryDirectory.appendingPathComponent("notch-pi-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = liveModel(storageURL: folder.appendingPathComponent("sessions.json"))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        await model.newSession(showPanel: false, runtime: .pi)
        model.sessions[0].workspacePath = folder.path
        model.draft = "Unsent Pi draft"
        let session = try XCTUnwrap(model.current)
        let key = model.modelCatalogKey(for: session)
        await model.loadModels(for: key)
        let catalog = try XCTUnwrap(model.modelCatalogs[key], model.modelCatalogErrors[key] ?? "Missing Pi catalog")
        let selection = try XCTUnwrap(catalog.models.first?.choice, "The existing Pi profile needs an available model")
        model.setModel(selection, for: session.id)
        XCTAssertEqual(model.current?.modelOverride, selection)
        XCTAssertEqual(model.current?.draft, "Unsent Pi draft")
        XCTAssertNil(model.current?.storedID)
        XCTAssertNil(model.current?.runtimeID)
        XCTAssertFalse(model.hasActiveWork)
        try await NativeJSONProcess.awaitPendingStops()
        print("PI CATALOG VERIFIED: \(catalog.models.count) models before the first message; no native conversation or prompt")
    }

    func testInstalledHarnessModelsToolsContextAndQuestions() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_HARNESS_COMPATIBILITY_TESTS"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_HARNESS_COMPATIBILITY_TESTS=1 for native model, tool, usage and question checks.")
        }
        let folder = nativeTemporaryDirectory.appendingPathComponent("notch-harness-verification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("HARNESS_TOOL_OK".utf8).write(to: folder.appendingPathComponent("marker.txt"))
        let model = liveModel(storageURL: folder.appendingPathComponent("sessions.json"))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        for runtime in try selectedRuntimes() {
            await model.newSession(showPanel: false, runtime: runtime)
            model.sessions[0].workspacePath = folder.path
            if runtime.requiresProjectTrust { model.sessions[0].trustedProjectPath = folder.path }
            let local = try XCTUnwrap(model.currentID)
            model.renameSession(local, title: "Notch Companion harness compatibility verification")
            model.draft = "Read marker.txt with your file tool. Reply with its exact contents. Do not modify files or memory."
            await model.send(); try await settle(model)
            XCTAssertEqual(model.current?.state, .finished, model.errorMessage ?? runtime.title)
            XCTAssertTrue(model.current?.latestResponse.contains("HARNESS_TOOL_OK") == true)
            XCTAssertTrue(model.current?.tools.contains { $0.state == .finished && !$0.detail.isEmpty } == true, "\(runtime.title) must expose tool calls and arguments")
            // Pi reads its native occupancy asynchronously after settlement.
            for _ in 0..<100 {
                if model.current?.runtimeInfo?.context?.used != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertGreaterThan(model.current?.runtimeInfo?.context?.used ?? 0, 0, runtime.title)
            if runtime != .antigravity { XCTAssertGreaterThan(model.current?.runtimeInfo?.context?.limit ?? 0, 0, runtime.title) }
            let session = try XCTUnwrap(model.current)
            let key = model.modelCatalogKey(for: session)
            await model.loadModels(for: key, refresh: true)
            let catalog = try XCTUnwrap(model.modelCatalogs[key], model.modelCatalogErrors[key] ?? runtime.title)
            let current = try XCTUnwrap(catalog.defaultModel)
            // Keep the existing account/provider; OpenCode's public test models stay free.
            let candidates = catalog.models.filter {
                $0.choice.provider == current.provider && (runtime != .opencode || $0.choice.model.contains("free"))
                    && (runtime != .antigravity || $0.choice.model.hasPrefix("gemini-"))
            }
            let changed = try XCTUnwrap(candidates.first { $0.choice.model != current.model }?.choice, "Need another model on the same native provider")
            let stored = try XCTUnwrap(model.current?.storedID)
            model.setModel(changed, for: local)
            XCTAssertEqual(model.current?.modelOverride, changed)
            model.draft = "Reply with exactly SWITCH_OK. Do not use tools or change files or memory."
            await model.send(); try await settle(model)
            XCTAssertEqual(model.current?.state, .finished, model.errorMessage ?? runtime.title)
            XCTAssertEqual(model.current?.runtimeInfo?.model, changed.model)
            XCTAssertEqual(model.current?.storedID, stored)
            XCTAssertTrue(model.current?.latestResponse.contains("SWITCH_OK") == true)
            if runtime == .pi || runtime == .opencode {
                model.draft = "Use your \(runtime == .pi ? "notch_ask_user" : "question or form") tool to ask me to choose Sage or Indigo. Wait for my answer and then reply with just the chosen color. Do not use other tools or modify files or memory."
                await model.send()
                let until = Date().addingTimeInterval(120)
                while model.currentRequest == nil && model.hasActiveWork && Date() < until { try await Task.sleep(for: .milliseconds(100)) }
                let request = try XCTUnwrap(model.currentRequest, model.errorMessage ?? "\(runtime.title) did not emit a question")
                XCTAssertEqual(request.kind, .clarification)
                XCTAssertTrue(request.choices.contains("Sage"))
                await model.answer(request, choice: "Sage")
                try await settle(model)
                XCTAssertTrue(model.current?.latestResponse.contains("Sage") == true)
            }
            print("HARNESS VERIFIED: \(runtime.rawValue), tools=\(model.current?.tools.count ?? 0), model=\(model.current?.runtimeInfo?.model ?? ""), used=\(model.current?.runtimeInfo?.context?.used ?? -1), window=\(model.current?.runtimeInfo?.context?.limit ?? -1)")
        }
    }

    func testModelSelectionAndContext() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_LIVE_MODEL_TESTS"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_LIVE_MODEL_TESTS=1 for account-backed model selection checks.")
        }
        let folder = nativeTemporaryDirectory.appendingPathComponent("notch-model-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let storage = folder.appendingPathComponent("sessions.json")
        var model = liveModel(storageURL: storage)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        await model.connect()
        var report: [[String: Any]] = []
        for runtime in try selectedRuntimes() {
            await model.newSession(showPanel: false, runtime: runtime)
            model.sessions[0].workspacePath = folder.path
            if runtime.requiresProjectTrust { model.sessions[0].trustedProjectPath = folder.standardizedFileURL.resolvingSymlinksInPath().path }
            let session = try XCTUnwrap(model.current)
            model.renameSession(session.id, title: "Notch Companion model and context verification \(runtime.title)")
            let key = model.modelCatalogKey(for: session)
            if runtime == .claude {
                // Claude discovers models only after an explicitly trusted
                // conversation opens; browsing the picker never runs hooks.
                model.draft = "Reply with exactly: CATALOG_READY. Do not use tools or change files or memory."
                await model.send()
                try await settle(model)
                XCTAssertEqual(model.current?.state, .finished, model.errorMessage ?? "Claude catalog startup failed")
            }
            await model.loadModels(for: key)
            let catalog = try XCTUnwrap(model.modelCatalogs[key], model.modelCatalogErrors[key] ?? "Missing model catalog")
            XCTAssertNotNil(catalog.defaultModel)
            // Discover names at runtime; prefer smaller models for this tiny check.
            let choices = catalog.models.sorted {
                let left = $0.choice.model.contains("luna"), right = $1.choice.model.contains("luna")
                return left == right ? $0.choice.model < $1.choice.model : left
            }
            guard choices.count >= 2 else { throw AppError("Live model check needs two available models") }
            // Exercise the names that Hermes previously auto-routed to an
            // unauthenticated aggregator, not just the older luna variants.
            var first = (runtime == .hermes ? choices.first { $0.choice.model == "gpt-6-luna" } : nil)?.choice ?? choices[0].choice
            var second = (runtime == .hermes ? choices.first { $0.choice.model == "gpt-6.1-sol" } : nil)?.choice
                ?? choices.first { $0.choice != first }!.choice
            if runtime == .claude {
                // Use ordinary plan models, discovered from this CLI's catalog.
                first = try XCTUnwrap(catalog.models.first { $0.title.hasPrefix("Sonnet") }?.choice)
                second = try XCTUnwrap(catalog.models.first { $0.title.hasPrefix("Opus") }?.choice)
                first.reasoningEffort = "low"
                second.reasoningEffort = "high"
                XCTAssertTrue(catalog.contains(first)); XCTAssertTrue(catalog.contains(second))
            }
            model.setModel(first, for: session.id)
            XCTAssertEqual(model.current?.modelOverride, first)
            model.draft = "Reply with exactly: MODEL_OK. Do not use tools or change files or memory."
            await model.send()
            try await settle(model)
            XCTAssertEqual(model.current?.state, .finished, model.errorMessage ?? "First model failed")
            XCTAssertTrue(model.current?.latestResponse.contains("MODEL_OK") == true)
            XCTAssertEqual(model.current?.runtimeInfo?.model, first.model)
            if let provider = first.provider { XCTAssertEqual(model.current?.runtimeInfo?.provider, provider) }
            XCTAssertNotNil(model.current?.runtimeInfo?.context?.used)
            XCTAssertNotNil(model.current?.runtimeInfo?.context?.limit)
            let stored = try XCTUnwrap(model.current?.storedID)
            model.setModel(second, for: session.id)
            XCTAssertEqual(model.current?.modelOverride, second)
            model.draft = "Reply with exactly: SWITCH_OK. Do not use tools or change files or memory."
            await model.send()
            try await settle(model)
            XCTAssertEqual(model.current?.state, .finished, model.errorMessage ?? "Second model failed")
            XCTAssertTrue(model.current?.latestResponse.contains("SWITCH_OK") == true)
            XCTAssertEqual(model.current?.runtimeInfo?.model, second.model)
            if let provider = second.provider { XCTAssertEqual(model.current?.runtimeInfo?.provider, provider) }
            XCTAssertEqual(model.current?.storedID, stored)
            if runtime == .claude {
                second.reasoningEffort = nil
                model.setModel(second, for: session.id)
                model.draft = "Reply with exactly: EFFORT_RESET_OK. Do not use tools or change files or memory."
                await model.send()
                try await settle(model)
                XCTAssertEqual(model.current?.state, .finished, model.errorMessage ?? "Same-model effort reset failed")
                XCTAssertTrue(model.current?.latestResponse.contains("EFFORT_RESET_OK") == true)
                second.reasoningEffort = "high"
                model.setModel(second, for: session.id)
            }
            let context = try XCTUnwrap(model.current?.runtimeInfo?.context)
            report.append(["runtime": runtime.rawValue, "native_session_id": stored,
                "default_model": catalog.defaultModel?.model ?? "", "first_model": first.model, "second_model": second.model,
                "reported_model": model.current?.runtimeInfo?.model ?? "", "reported_provider": model.current?.runtimeInfo?.provider ?? "", "context_used": context.used ?? -1,
                "context_window": context.limit ?? -1, "context_estimated": context.estimated])
        }
        model.shutdown()
        model = liveModel(storageURL: storage)
        await model.connect()
        for saved in model.sessions.filter({ $0.storedID != nil }) {
            model.selectSession(saved.id)
            model.draft = "Reply with exactly: RESUMED_OK. Do not use tools or change files or memory."
            await model.send()
            try await settle(model)
            XCTAssertEqual(model.current?.state, .finished, model.errorMessage ?? "Resume failed")
            XCTAssertTrue(model.current?.latestResponse.contains("RESUMED_OK") == true)
            XCTAssertEqual(model.current?.storedID, saved.storedID)
            XCTAssertEqual(model.current?.runtimeInfo?.model, saved.modelOverride?.model)
            if let provider = saved.modelOverride?.provider { XCTAssertEqual(model.current?.runtimeInfo?.provider, provider) }
        }
        if let output = ProcessInfo.processInfo.environment["NOTCH_MODEL_LIVE_EVIDENCE"] {
            try JSONSerialization.data(withJSONObject: ["model_context_sessions": report], options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    func testNativeConversationsThroughAppModel() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_LIVE_RUNTIME_TESTS"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_LIVE_RUNTIME_TESTS=1 for real account-backed runtime checks.")
        }
        let folder = nativeTemporaryDirectory.appendingPathComponent("notch-model-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let storage = folder.appendingPathComponent("sessions.json")
        let marker = "notch" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let attachment = folder.appendingPathComponent("validation-marker.txt")
        try Data(marker.utf8).write(to: attachment)
        var model = liveModel(storageURL: storage)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        await model.connect()
        var ids: [RuntimeKind: String] = [:]
        for runtime in try selectedRuntimes() {
            await model.newSession(showPanel: false, runtime: runtime)
            let local = try XCTUnwrap(model.currentID)
            model.renameSession(local, title: "Notch Companion adapter verification \(runtime.title) \(marker)")
            model.sessions[0].workspacePath = folder.path
            if runtime.requiresProjectTrust { model.sessions[0].trustedProjectPath = folder.standardizedFileURL.resolvingSymlinksInPath().path }
            model.draft = "Read the attached validation-marker.txt. Reply with only its exact contents. Do not modify files or memory."
            XCTAssertTrue(model.addAttachments([attachment], showPanel: false))
            await model.send()
            try await settle(model)
            XCTAssertEqual(model.current?.state, .finished, model.errorMessage ?? "Turn did not finish")
            XCTAssertTrue(model.current?.latestResponse.contains(marker) == true)
            XCTAssertTrue(model.current?.attachments.isEmpty == true)
            XCTAssertNotNil(model.current?.storedID)
            XCTAssertFalse(model.current?.isLegacyPrivate ?? true)
            ids[runtime] = local
        }
        XCTAssertFalse(model.hasActiveWork)
        model.shutdown()
        // Each native adapter restarts and resumes the same durable conversation.
        model = liveModel(storageURL: storage)
        await model.connect()
        for runtime in try selectedRuntimes() {
            let local = try XCTUnwrap(ids[runtime])
            model.selectSession(local)
            let stored = try XCTUnwrap(model.current?.storedID)
            model.draft = "What were the exact contents of the file in our previous turn? Reply with only that value using conversation context; do not use tools or modify memory."
            await model.send()
            try await settle(model)
            XCTAssertEqual(model.current?.state, .finished, model.errorMessage ?? "Resume did not finish")
            XCTAssertEqual(model.current?.storedID, stored)
            XCTAssertTrue(model.current?.latestResponse.contains(marker) == true)
            XCTAssertEqual(model.current?.messages.filter { $0.role == "user" }.count, 2)
        }
        let evidence = model.sessions.filter { ids.values.contains($0.id) }.map { session in
            ["runtime": session.runtime.rawValue, "profile_id": session.profileID ?? "", "native_session_id": session.storedID ?? "",
             "title": session.title, "status": session.state.rawValue,
             "native_resume_retained_context": session.latestResponse.contains(marker),
             "user_turns": session.messages.filter { $0.role == "user" }.count] as [String: Any]
        }
        if let output = ProcessInfo.processInfo.environment["NOTCH_LIVE_EVIDENCE"] {
            try JSONSerialization.data(withJSONObject: ["app_model_native_sessions": evidence], options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    /// Newer Hermes asks through server→client requests; older builds use
    /// clarify.request events. Either way the card must appear and the answer
    /// must reach the native tool.
    func testHermesClarificationRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_LIVE_CLARIFY_TEST"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_LIVE_CLARIFY_TEST=1 for an account-backed Hermes clarification round trip.")
        }
        let folder = nativeTemporaryDirectory.appendingPathComponent("notch-clarify-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let model = liveModel(storageURL: folder.appendingPathComponent("sessions.json"))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        await model.connect()
        await model.newSession(showPanel: false, runtime: .hermes)
        let local = try XCTUnwrap(model.currentID)
        model.renameSession(local, title: "Notch Companion clarification verification")
        model.sessions[0].workspacePath = folder.path
        model.draft = "Use your clarify tool to ask me one question, \"Pick a colour\", with the choices Sage and Blue. Then reply with only the colour I chose. Do not use other tools or change files or memory."
        await model.send()
        let deadline = Date().addingTimeInterval(180)
        while model.currentRequest == nil && model.hasActiveWork && Date() < deadline { try await Task.sleep(for: .milliseconds(150)) }
        let request = try XCTUnwrap(model.currentRequest, model.errorMessage ?? "Hermes did not ask through the companion")
        XCTAssertEqual(request.kind, .clarification)
        await model.answer(request, choice: "Sage")
        try await settle(model)
        XCTAssertEqual(model.current?.state, .finished, model.errorMessage ?? "Turn did not finish")
        XCTAssertTrue(model.current?.latestResponse.contains("Sage") == true)
    }

    /// Codex's asynchronous question tool ends its turn with the questions on
    /// an agent message. The card's answer is the next ordinary message.
    func testCodexAsyncQuestionRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_LIVE_CODEX_QUESTION_TEST"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_LIVE_CODEX_QUESTION_TEST=1 for an account-backed Codex question round trip.")
        }
        let folder = nativeTemporaryDirectory.appendingPathComponent("notch-codex-question-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let model = liveModel(storageURL: folder.appendingPathComponent("sessions.json"))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        await model.connect()
        await model.newSession(showPanel: false, runtime: .codex)
        let local = try XCTUnwrap(model.currentID)
        model.renameSession(local, title: "Notch Companion question verification")
        model.sessions[0].workspacePath = folder.path
        model.draft = "Use your question tool to ask me one question, \"Pick a colour\", with the options Sage and Blue, then end your turn. When I answer, reply with only the colour I chose. Do not use other tools or change files or memory."
        await model.send()
        try await settle(model)
        let asked = try XCTUnwrap(model.current?.messages.last(where: { $0.questions != nil })?.questions,
                                  model.errorMessage ?? "Codex did not ask through its question tool")
        XCTAssertTrue(asked.contains { $0.options.contains("Sage") })
        XCTAssertFalse(model.current?.latestResponse.contains("- Sage") ?? true, "The question's plain rendering stays out of the answer text")
        let replied = await model.replyToQuestions(asked, answers: asked.map { $0.options.contains("Sage") ? "Sage" : "" })
        XCTAssertTrue(replied, model.errorMessage ?? "The answer was not sent")
        try await settle(model)
        XCTAssertEqual(model.current?.state, .finished, model.errorMessage ?? "Turn did not finish")
        XCTAssertTrue(model.current?.latestResponse.contains("Sage") == true)
    }

    /// Claude's AskUserQuestion arrives as a permission request for that tool;
    /// the card's answer goes back as the tool's native answers.
    func testClaudeQuestionRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_LIVE_CLAUDE_QUESTION_TEST"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_LIVE_CLAUDE_QUESTION_TEST=1 for an account-backed Claude Code question round trip.")
        }
        let folder = nativeTemporaryDirectory.appendingPathComponent("notch-claude-question-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let model = liveModel(storageURL: folder.appendingPathComponent("sessions.json"))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        await model.connect()
        await model.newSession(showPanel: false, runtime: .claude)
        let local = try XCTUnwrap(model.currentID)
        model.renameSession(local, title: "Notch Companion question verification")
        model.sessions[0].workspacePath = folder.path
        model.sessions[0].trustedProjectPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        model.draft = "Use your AskUserQuestion tool to ask me one question, \"Pick a colour\", with the options Sage and Blue. Then reply with only the colour I chose. Do not use other tools or change files or memory."
        await model.send()
        let deadline = Date().addingTimeInterval(180)
        while model.currentRequest == nil && model.hasActiveWork && Date() < deadline { try await Task.sleep(for: .milliseconds(150)) }
        let request = try XCTUnwrap(model.currentRequest, model.errorMessage ?? "Claude Code did not ask through the companion")
        XCTAssertEqual(request.kind, .clarification)
        XCTAssertTrue(request.choices.contains("Sage"))
        XCTAssertFalse(request.detail.contains("Sage:"), "Option descriptions stay beside their choice")
        await model.answer(request, choice: "Sage")
        try await settle(model)
        XCTAssertEqual(model.current?.state, .finished, model.errorMessage ?? "Turn did not finish")
        XCTAssertTrue(model.current?.latestResponse.contains("Sage") == true)
    }

    func testCodingChangeSummaries() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_LIVE_CHANGES_TEST"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_LIVE_CHANGES_TEST=1 for account-backed file-change checks.")
        }
        let runtimes = ProcessInfo.processInfo.environment["NOTCH_LIVE_RUNTIMES"] == nil ? RuntimeKind.allCases : try selectedRuntimes()
        for runtime in runtimes {
            do { try await verifyCodingChangeSummary(runtime) }
            catch { XCTFail("\(runtime.title) change summary: \(error.localizedDescription)") }
        }
    }

    private func verifyCodingChangeSummary(_ runtime: RuntimeKind) async throws {
        var directory = nativeTemporaryDirectory
        if runtime == .openclaw {
            let profile = RuntimeProfileIdentity.decodeOpenClaw(RuntimeRoute.defaultProfile(runtime))
            guard let workspace = try OpenClawConfiguration.workspace(profileID: profile.directory, agent: profile.agent) else {
                throw AppError("OpenClaw needs its existing configured agent workspace for this live check.")
            }
            directory = URL(fileURLWithPath: workspace, isDirectory: true)
        }
        let folder = directory.appendingPathComponent("notch-changes-live-\(UUID().uuidString)")
        let project = folder.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("message.txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try WorkspaceChanges.run(["init", "--quiet"], at: project.path)
        _ = try WorkspaceChanges.run(["add", "message.txt"], at: project.path)
        _ = try WorkspaceChanges.run(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "Fixture"], at: project.path)
        let model = liveModel(storageURL: folder.appendingPathComponent("sessions.json"))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        await model.connect()
        await model.newSession(showPanel: false, runtime: runtime)
        model.sessions[0].workspacePath = project.path
        if runtime.requiresProjectTrust { model.sessions[0].trustedProjectPath = project.standardizedFileURL.resolvingSymlinksInPath().path }
        model.renameSession(try XCTUnwrap(model.currentID), title: "Notch Companion file-change verification")
        model.draft = "In this disposable test project, use your built-in file edit tool to replace the single line before in message.txt with after, keeping its trailing newline. Only change that file. Do not run commands, commit, delegate, or change memory. Then reply Done."
        await model.send()
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let request = model.currentRequest {
                guard request.kind == .approval, request.detail.contains("message.txt"), request.choices.contains("once") else {
                    throw AppError("Live change verification needs an unexpected interaction: \(request.title)")
                }
                await model.answer(request, choice: "once")
            }
            if !model.hasActiveWork, model.current?.changes.first?.capturedAt != nil { break }
            if !model.hasActiveWork, model.current?.state == .failed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard model.current?.state == .finished else { throw AppError(model.errorMessage ?? "Native turn did not finish") }
        let summary = try XCTUnwrap(model.current?.changes.first)
        XCTAssertNil(summary.notice)
        XCTAssertEqual(summary.source, runtime == .codex ? .agent : .workspace)
        XCTAssertEqual(summary.files.count, 1)
        XCTAssertTrue(summary.files.first?.path.hasSuffix("message.txt") == true)
        XCTAssertEqual(summary.files.first?.url(in: summary.workspace)?.standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(summary.additions, 1)
        XCTAssertEqual(summary.deletions, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after\n")
        print("Native \(runtime.title) change summary: \(summary.source.rawValue), \(summary.files.count) file, +\(summary.additions) -\(summary.deletions)")
    }

    private func settle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(180)
        while model.hasActiveWork && Date() < deadline {
            if let request = model.currentRequest {
                XCTFail("Native verification requires interaction: \(request.title) — \(request.detail)")
                throw AppError("Native verification requires interaction: \(request.title) — \(request.detail)")
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        if model.hasActiveWork {
            await model.interrupt()
            let stopDeadline = Date().addingTimeInterval(15)
            while model.hasActiveWork && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(150)) }
            throw AppError("Test-owned runtime did not settle before timeout")
        }
    }
}
