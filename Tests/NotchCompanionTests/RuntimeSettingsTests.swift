import XCTest
@testable import NotchCompanion

@MainActor private final class RuntimeSettingsTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var connects = 0
    var disconnects = 0
    var requests = 0
    var requestHandler: ((String, [String: Any]) async throws -> [String: Any])?
    func connect() async throws { connects += 1 }
    func disconnect() { disconnects += 1 }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests += 1
        return try await requestHandler?(method, params) ?? [:]
    }
}

private final class RuntimeSettingsFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-settings-\(UUID().uuidString)")
    let suite = "notch-runtime-settings-\(UUID().uuidString)"
    let defaults: UserDefaults
    var storage: URL { folder.appendingPathComponent("sessions.json") }
    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        // Off, so reconnect does not reload catalogs through the tests' unanswered handlers.
        defaults.set(false, forKey: "notch.showModelPicker")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func clean() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
    func profile(_ name: String, runtime: RuntimeKind = .hermes) throws -> URL {
        let profile = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("# Fixture configuration\n".utf8).write(to: profile.appendingPathComponent(runtime == .hermes ? "config.yaml" : "config.toml"))
        return profile.resolvingSymlinksInPath()
    }
}

@MainActor final class RuntimeSettingsTests: XCTestCase {
    func testSavedProfilePrecedenceAndLegacyIdentityRemainSeparate() throws {
        let fixture = try RuntimeSettingsFixture()
        defer { fixture.clean() }
        let hermes = try fixture.profile("Saved Hermes")
        let codex = try fixture.profile("Saved Codex", runtime: .codex)
        fixture.defaults.set(hermes.path, forKey: RuntimeLocation.hermesProfile.rawValue)
        fixture.defaults.set(codex.path, forKey: RuntimeLocation.codexProfile.rawValue)
        let environment = ["HERMES_HOME": "/native/hermes", "NOTCH_HERMES_SOURCE_HOME": "/override/hermes",
                           "CODEX_HOME": "/native/codex", "NOTCH_HERMES_HOME": "/legacy/hermes"]
        XCTAssertEqual(RuntimeRoute.defaultProfile(.hermes, environment: environment, userHome: fixture.folder, defaults: fixture.defaults), hermes.path)
        XCTAssertEqual(RuntimeRoute.defaultProfile(.codex, environment: environment, userHome: fixture.folder, defaults: fixture.defaults), codex.path)
        XCTAssertEqual(RuntimeRoute.defaultProfile(.hermes, legacy: true, environment: environment, userHome: fixture.folder, defaults: fixture.defaults), "/legacy/hermes")
        fixture.defaults.removeObject(forKey: RuntimeLocation.hermesProfile.rawValue)
        fixture.defaults.removeObject(forKey: RuntimeLocation.codexProfile.rawValue)
        XCTAssertEqual(RuntimeRoute.defaultProfile(.hermes, environment: environment, userHome: fixture.folder, defaults: fixture.defaults), "/override/hermes")
        XCTAssertEqual(RuntimeRoute.defaultProfile(.hermes, environment: ["HERMES_HOME": "/native/hermes"], userHome: fixture.folder, defaults: fixture.defaults), "/native/hermes")
        XCTAssertEqual(RuntimeRoute.defaultProfile(.codex, environment: environment, userHome: fixture.folder, defaults: fixture.defaults), "/native/codex")
        XCTAssertEqual(RuntimeRoute.defaultProfile(.hermes, environment: ["HERMES_HOME": " \n"], userHome: fixture.folder, defaults: fixture.defaults),
                       fixture.folder.appendingPathComponent(".hermes").resolvingSymlinksInPath().path)
        XCTAssertEqual(RuntimeRoute.defaultProfile(.codex, environment: ["CODEX_HOME": "~/Codex"], userHome: fixture.folder, defaults: fixture.defaults),
                       fixture.folder.appendingPathComponent("Codex").resolvingSymlinksInPath().path)
    }

    func testProfileValidationRequiresExistingNativeProfileAndCanonicalizesAliases() throws {
        let fixture = try RuntimeSettingsFixture()
        defer { fixture.clean() }
        for (setting, runtime) in [(RuntimeLocation.hermesProfile, RuntimeKind.hermes), (.codexProfile, .codex)] {
            let profile = try fixture.profile(runtime.rawValue, runtime: runtime)
            let alias = fixture.folder.appendingPathComponent(runtime.rawValue + " alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: profile)
            XCTAssertEqual(try setting.validate(alias.path, environment: [:], userHome: fixture.folder), profile.path)
            XCTAssertThrowsError(try setting.validate(fixture.folder.appendingPathComponent("missing").path))
            XCTAssertThrowsError(try setting.validate(profile.appendingPathComponent(runtime == .hermes ? "config.yaml" : "config.toml").path))
        }
        let empty = fixture.folder.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try RuntimeLocation.hermesProfile.validate(empty.path))
        XCTAssertThrowsError(try RuntimeLocation.codexProfile.validate(empty.path))
        try FileManager.default.createDirectory(at: empty.appendingPathComponent("config.yaml"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try RuntimeLocation.hermesProfile.validate(empty.path), "A directory named config.yaml is not a configured profile.")
    }

    func testProfileChangeAndResetPersistOnlyCurrentUnstartedDraftWithoutTouchingNativeFiles() throws {
        let fixture = try RuntimeSettingsFixture()
        defer { fixture.clean() }
        let transport = RuntimeSettingsTransport()
        let model = AppModel(storageURL: fixture.storage, playsSounds: false, client: transport)
        defer { model.shutdown() }
        let selected = try fixture.profile("Selected Hermes")
        let config = selected.appendingPathComponent("config.yaml")
        let configBefore = try Data(contentsOf: config)
        let standardBefore = UserDefaults.standard.string(forKey: RuntimeLocation.hermesProfile.rawValue)
        let attachment = Attachment(url: fixture.folder.appendingPathComponent("attached.txt"))
        model.sessions = [CompanionSession(id: "draft", runtime: .hermes, profileID: "/original", draft: "Keep this prompt", attachments: [attachment]),
                          CompanionSession(id: "other", runtime: .hermes, profileID: "/other"),
                          CompanionSession(id: "codex", runtime: .codex, profileID: "/codex")]
        model.currentID = "draft"
        model.sessions[0].modelOverride = RuntimeModelChoice(model: "old-provider-model", provider: "old-provider")
        model.sessions[0].runtimeInfo = RuntimeSessionInfo(model: "old-provider-model", provider: "old-provider",
                                                        context: RuntimeContextUsage(used: 200, limit: 1000))
        try model.setRuntimeLocation(.hermesProfile, path: selected.path, defaults: fixture.defaults)
        XCTAssertEqual(model.current?.profileID, selected.path)
        XCTAssertNil(model.current?.modelOverride, "A different profile must inherit its own configured model.")
        XCTAssertNil(model.current?.runtimeInfo, "Reported context and provider belong to the old profile.")
        XCTAssertEqual(model.current?.draft, "Keep this prompt")
        XCTAssertEqual(model.current?.attachments, [attachment])
        XCTAssertEqual(model.sessions[1].profileID, "/other")
        XCTAssertEqual(model.sessions[2].profileID, "/codex")
        XCTAssertEqual(RuntimeLocation.hermesProfile.saved(in: fixture.defaults), selected.path)
        XCTAssertEqual(model.runtimeSettingsPending, [.hermes])
        XCTAssertEqual(transport.disconnects, 0)
        XCTAssertEqual(transport.connects, 0)
        XCTAssertEqual(transport.requests, 0)
        let saved = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: fixture.storage))
        XCTAssertEqual(saved.first?.profileID, selected.path)
        XCTAssertEqual(try Data(contentsOf: config), configBefore)
        XCTAssertEqual(UserDefaults.standard.string(forKey: RuntimeLocation.hermesProfile.rawValue), standardBefore)

        let revision = model.runtimeSettingsRevision
        try model.setRuntimeLocation(.hermesProfile, path: selected.path, defaults: fixture.defaults)
        XCTAssertEqual(model.runtimeSettingsRevision, revision, "Selecting the same location is a no-op.")
        try model.setRuntimeLocation(.hermesProfile, path: nil, defaults: fixture.defaults)
        XCTAssertNil(RuntimeLocation.hermesProfile.saved(in: fixture.defaults))
        XCTAssertEqual(model.current?.profileID, RuntimeRoute.defaultProfile(.hermes, defaults: fixture.defaults))
        let reset = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: fixture.storage))
        XCTAssertEqual(reset.first?.profileID, model.current?.profileID)
        XCTAssertEqual(transport.disconnects, 0)
    }

    func testProfileChangesNeverReassignStartedSentAmbiguousOrLegacySessions() throws {
        let fixture = try RuntimeSettingsFixture()
        defer { fixture.clean() }
        let selected = try fixture.profile("Selected Hermes")
        let variants: [(String, (inout CompanionSession) -> Void)] = [
            ("saved", { $0.storedID = "native-id" }),
            ("live", { $0.runtimeID = "live-id" }),
            ("sent", { $0.messages = [ChatMessage(role: "user", text: "Already sent")] }),
            ("attempted", { $0.nativeSubmissionAttempted = true }),
            ("ambiguous", { $0.pendingSubmission = PendingSubmission(id: "unknown", draft: "Possibly accepted", userTurnCount: 1, attachmentIDs: []) }),
            ("working", { $0.state = .working }),
            ("legacy", { $0.isLegacyPrivate = true })
        ]
        for (name, mutate) in variants {
            fixture.defaults.removeObject(forKey: RuntimeLocation.hermesProfile.rawValue)
            let transport = RuntimeSettingsTransport()
            let storage = fixture.folder.appendingPathComponent(name + ".json")
            let model = AppModel(storageURL: storage, playsSounds: false, client: transport)
            var session = CompanionSession(id: name, runtime: .hermes, profileID: "/pinned-profile")
            session.modelOverride = RuntimeModelChoice(model: "saved-model", provider: "saved-provider")
            session.runtimeInfo = RuntimeSessionInfo(model: "saved-model", provider: "saved-provider",
                                                   context: RuntimeContextUsage(used: 50, limit: 1000))
            mutate(&session)
            model.sessions = [session]
            model.currentID = name
            try model.setRuntimeLocation(.hermesProfile, path: selected.path, defaults: fixture.defaults)
            XCTAssertEqual(model.current, session, name)
            XCTAssertEqual(transport.disconnects, 0, name)
            XCTAssertEqual(transport.requests, 0, name)
            model.shutdown()
            let saved = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: storage))
            XCTAssertEqual(saved.first?.profileID, "/pinned-profile", name)
            XCTAssertEqual(saved.first?.modelOverride, session.modelOverride, name)
            XCTAssertEqual(saved.first?.runtimeInfo, session.runtimeInfo, name)
        }
    }

    func testReconnectInvalidatesCatalogErrorsAndLoadingFromPreviousInstallation() async throws {
        let fixture = try RuntimeSettingsFixture()
        defer { fixture.clean() }
        let transport = RuntimeSettingsTransport()
        let model = AppModel(storageURL: fixture.storage, playsSounds: false, client: transport, preferences: fixture.defaults)
        defer { model.shutdown() }
        let key = model.modelCatalogKey(for: try XCTUnwrap(model.current))
        let failedKey = ModelCatalogKey(route: key.route, cwd: fixture.folder.appendingPathComponent("other-project").path)
        model.modelCatalogs[key] = RuntimeModelCatalog(defaultModel: RuntimeModelChoice(model: "old-installation"))
        transport.requestHandler = { _, _ in throw AppError("Old installation failure") }
        await model.loadModels(for: failedKey)
        XCTAssertNotNil(model.modelCatalogErrors[failedKey])
        var pending: CheckedContinuation<[String: Any], Error>?
        transport.requestHandler = { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        let oldRequest = Task { await model.loadModels(for: key, refresh: true) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let reply = try XCTUnwrap(pending)
        XCTAssertTrue(model.loadingModelCatalogs.contains(key))

        await model.reconnect()
        XCTAssertTrue(model.modelCatalogs.isEmpty)
        XCTAssertTrue(model.modelCatalogErrors.isEmpty)
        XCTAssertTrue(model.loadingModelCatalogs.isEmpty)
        XCTAssertEqual(transport.disconnects, 1)
        reply.resume(returning: ["catalog": RuntimeModelCatalog(defaultModel: RuntimeModelChoice(model: "stale-installation"))])
        await oldRequest.value
        XCTAssertTrue(model.modelCatalogs.isEmpty)
        XCTAssertTrue(model.modelCatalogErrors.isEmpty)
    }

    func testStaleCatalogCompletionCannotClearNewGenerationLoadingOrOverwriteItsCatalog() async throws {
        for staleFails in [false, true] {
            let fixture = try RuntimeSettingsFixture()
            defer { fixture.clean() }
            let transport = RuntimeSettingsTransport()
            let model = AppModel(storageURL: fixture.storage, playsSounds: false, client: transport, preferences: fixture.defaults)
            defer { model.shutdown() }
            let key = model.modelCatalogKey(for: try XCTUnwrap(model.current))
            var pending: [CheckedContinuation<[String: Any], Error>] = []
            transport.requestHandler = { _, _ in
                try await withCheckedThrowingContinuation { pending.append($0) }
            }
            let oldRequest = Task { await model.loadModels(for: key) }
            for _ in 0..<100 where pending.isEmpty { await Task.yield() }
            let oldReply = try XCTUnwrap(pending.first)
            await model.reconnect()
            let newRequest = Task { await model.loadModels(for: key) }
            for _ in 0..<100 where pending.count < 2 { await Task.yield() }
            guard pending.count == 2 else {
                oldReply.resume(throwing: AppError("Fixture cleanup"))
                await oldRequest.value
                await newRequest.value
                XCTFail("Reconnect must permit a fresh request for the same catalog.")
                continue
            }
            if staleFails { oldReply.resume(throwing: AppError("Stale connection failed")) }
            else { oldReply.resume(returning: ["catalog": RuntimeModelCatalog(defaultModel: RuntimeModelChoice(model: "stale"))]) }
            await oldRequest.value
            XCTAssertTrue(model.loadingModelCatalogs.contains(key), "Old cleanup must not clear the new request's loading state.")
            XCTAssertNil(model.modelCatalogs[key])
            XCTAssertNil(model.modelCatalogErrors[key])
            let fresh = RuntimeModelCatalog(defaultModel: RuntimeModelChoice(model: "fresh"))
            pending[1].resume(returning: ["catalog": fresh])
            await newRequest.value
            XCTAssertEqual(model.modelCatalogs[key], fresh)
            XCTAssertFalse(model.loadingModelCatalogs.contains(key))
            XCTAssertNil(model.modelCatalogErrors[key])
        }
    }

    func testInvalidLocationLeavesPreferencesDraftAndRuntimeUntouched() throws {
        let fixture = try RuntimeSettingsFixture()
        defer { fixture.clean() }
        let transport = RuntimeSettingsTransport()
        let model = AppModel(storageURL: fixture.storage, playsSounds: false, client: transport)
        defer { model.shutdown() }
        fixture.defaults.set("/previous", forKey: RuntimeLocation.hermesProfile.rawValue)
        let draft = model.current
        XCTAssertThrowsError(try model.setRuntimeLocation(.hermesProfile, path: fixture.folder.appendingPathComponent("missing").path, defaults: fixture.defaults))
        XCTAssertEqual(RuntimeLocation.hermesProfile.saved(in: fixture.defaults), "/previous")
        XCTAssertEqual(model.current, draft)
        XCTAssertTrue(model.runtimeSettingsPending.isEmpty)
        XCTAssertEqual(transport.disconnects, 0)
    }

    func testSetupChangeStillRequiresSafeReconnectWhileWorkIsActive() async throws {
        let fixture = try RuntimeSettingsFixture()
        defer { fixture.clean() }
        let transport = RuntimeSettingsTransport()
        let model = AppModel(storageURL: fixture.storage, playsSounds: false, client: transport)
        defer { model.shutdown() }
        model.sessions[0].state = .working
        let profile = try fixture.profile("Codex", runtime: .codex)
        try model.setRuntimeLocation(.codexProfile, path: profile.path, defaults: fixture.defaults)
        model.activeOperationDecision = { operation in
            XCTAssertEqual(operation, .reconnect)
            return .whenFinished
        }
        await model.reconnect()
        XCTAssertEqual(model.deferredOperation, .reconnect)
        XCTAssertEqual(model.runtimeSettingsPending, [.codex])
        XCTAssertEqual(transport.disconnects, 0)
        XCTAssertEqual(transport.connects, 0)
    }

    func testFullWindowSetupDoesNotAcknowledgeAnUnseenCompletion() throws {
        let fixture = try RuntimeSettingsFixture()
        defer { fixture.clean() }
        let model = AppModel(storageURL: fixture.storage, playsSounds: false, client: RuntimeSettingsTransport())
        defer { model.shutdown() }
        for runtime in RuntimeKind.allCases {
            model.page = .runtimeSetup(runtime)
            model.sessions = [CompanionSession(id: "unseen", state: .finished, completionID: runtime.rawValue)]
            model.currentID = "unseen"
            model.setSessionVisibility(fullSessionVisible: true, fullConversationVisible: true)
            XCTAssertTrue(model.current!.hasUnreadCompletion)
            model.page = .session
            XCTAssertFalse(model.current!.hasUnreadCompletion)
        }
    }
}
