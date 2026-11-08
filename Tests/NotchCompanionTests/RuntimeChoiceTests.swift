import XCTest
@testable import NotchCompanion

@MainActor private final class RuntimeChoiceFixture: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var connectError: Error?
    var connects = 0
    var calls: [(String, [String: Any])] = []
    func connect() async throws { connects += 1; if let connectError { throw connectError } }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        return method == "session.create" ? ["session_id": "native-choice", "stored_id": "native-choice"] : [:]
    }
    func disconnect() {}
}

/// The draft's inline agent selector writes through `setRuntime`.
@MainActor final class RuntimeChoiceTests: XCTestCase {
    func testSetupChecksFilterPickerPersistReadinessAndRouteTheSelectedDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-ready-choice-\(UUID().uuidString)")
        let suite = "notch-ready-choice-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let hermes = RuntimeChoiceFixture(), codex = RuntimeChoiceFixture(), missing = RuntimeChoiceFixture()
        missing.connectError = AppError("Installation unavailable")
        let router = RuntimeRouter { $0.runtime == .hermes ? hermes : $0.runtime == .codex ? codex : missing }
        let file = directory.appendingPathComponent("sessions.json")
        let model = AppModel(storageURL: file, playsSounds: false, client: router, preferences: preferences)
        defer { model.shutdown(); preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        await model.connect()
        XCTAssertTrue(model.readyRuntimes.isEmpty)
        XCTAssertTrue(model.currentDraftNeedsSetup)
        XCTAssertEqual(hermes.connects + codex.connects + missing.connects, 0)

        model.setRuntime(.opencode, for: try XCTUnwrap(model.currentID))
        model.draft = "Keep this draft"
        model.sessions[0].attachments = [Attachment(url: URL(fileURLWithPath: "/tmp/keep.txt"))]
        await model.connectRuntime(.opencode)
        XCTAssertTrue(model.readyRuntimes.isEmpty)
        await model.connectRuntime(.codex)
        XCTAssertEqual(model.readyRuntimes, [.codex])
        XCTAssertEqual(model.current?.runtime, .codex)
        XCTAssertEqual(model.draft, "Keep this draft")
        XCTAssertEqual(model.current?.attachments.first?.url.path, "/tmp/keep.txt")
        XCTAssertFalse(model.currentDraftNeedsSetup)
        await model.connectRuntime(.hermes)
        XCTAssertEqual(model.readyRuntimes, [.hermes, .codex])
        let id = try XCTUnwrap(model.currentID)
        let choice = RuntimeModelChoice(model: "fixture-reasoner", reasoningEffort: "high")
        model.sessions[0].modelOverride = choice
        model.sessions[0].runtimeInfo = RuntimeSessionInfo(model: "fixture-reasoner", context: RuntimeContextUsage(used: 100, limit: 1000))
        model.chooseReadyRuntime(.pi, for: id)
        XCTAssertEqual(model.current?.runtime, .codex)
        XCTAssertEqual(model.current?.modelOverride, choice, "An unavailable harness must not erase the model or effort")
        model.chooseReadyRuntime(.codex, for: id)
        XCTAssertEqual(model.current?.modelOverride, choice, "Choosing the current harness preserves its model and effort")
        model.chooseReadyRuntime(.hermes, for: id)
        XCTAssertEqual(model.current?.runtime, .hermes)
        XCTAssertNil(model.current?.modelOverride, "Model and effort cannot follow a draft into another harness")
        XCTAssertNil(model.current?.runtimeInfo)
        XCTAssertEqual(model.draft, "Keep this draft")
        model.sessions[0].attachments = []
        await model.send()
        XCTAssertTrue(hermes.calls.contains { $0.0 == "prompt.submit" })
        XCTAssertFalse(codex.calls.contains { $0.0 == "prompt.submit" })
        model.chooseReadyRuntime(.codex, for: id)
        XCTAssertEqual(model.current?.runtime, .hermes)

        model.shutdown()
        let reopened = AppModel(storageURL: file, playsSounds: false, client: RuntimeChoiceFixture(), preferences: preferences)
        defer { reopened.shutdown() }
        XCTAssertEqual(reopened.readyRuntimes, [.hermes, .codex])
        reopened.defaultRuntime = .pi
        await reopened.newSession(showPanel: false)
        XCTAssertEqual(reopened.current?.runtime, .hermes)
        reopened.defaultRuntime = .codex
        await reopened.newSession(showPanel: false)
        XCTAssertEqual(reopened.current?.runtime, .codex)
    }

    func testProfileChangesAndFailedChecksRemoveReadinessWithoutRetargetingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-ready-profile-\(UUID().uuidString)")
        let suite = "notch-ready-profile-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let transport = RuntimeChoiceFixture()
        let model = AppModel(storageURL: directory.appendingPathComponent("sessions.json"), playsSounds: false,
                             client: RuntimeRouter { _ in transport }, preferences: preferences)
        defer { model.shutdown(); preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        await model.connectRuntime(.codex)
        let oldProfile = try XCTUnwrap(model.current?.profileID)
        model.sessions[0].storedID = "saved-native"
        let profile = directory.appendingPathComponent("other-profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("# fixture".utf8).write(to: profile.appendingPathComponent("config.toml"))
        try model.setRuntimeLocation(.codexProfile, path: profile.path, defaults: preferences)
        XCTAssertTrue(model.readyRuntimes.isEmpty)
        XCTAssertEqual(model.current?.profileID, oldProfile)
        XCTAssertFalse(model.currentDraftNeedsSetup)
        transport.connectError = AppError("Sign-in unavailable")
        await model.reconnect()
        await model.connectRuntime(.codex)
        XCTAssertTrue(model.readyRuntimes.isEmpty)
        XCTAssertTrue(model.errorMessage?.contains("Sign-in unavailable") == true)
        await model.newSession(showPanel: false)
        XCTAssertTrue(model.currentDraftNeedsSetup)
    }

    func testUpgradeKeepsOnlySuccessfulCurrentProfilesAndDoesNotDiscoverInstallations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-ready-upgrade-\(UUID().uuidString)")
        let suite = "notch-ready-upgrade-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let file = directory.appendingPathComponent("sessions.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reply = ChatMessage(role: "assistant", text: "A successful reply")
        let sessions = [
            CompanionSession(id: "success", storedID: "native", runtime: .codex, profileID: RuntimeRoute.defaultProfile(.codex, defaults: preferences), messages: [reply]),
            CompanionSession(id: "draft", runtime: .pi),
            CompanionSession(id: "different", storedID: "other", runtime: .hermes, profileID: "/different-profile", messages: [reply]),
            CompanionSession(id: "legacy", storedID: "private", isLegacyPrivate: true, messages: [reply])
        ]
        try JSONEncoder().encode(sessions).write(to: file)
        let transport = RuntimeChoiceFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport, preferences: preferences)
        defer { model.shutdown(); preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(model.readyRuntimes, [.codex])
        XCTAssertEqual(model.sessions.count, sessions.count)
        XCTAssertEqual(transport.connects, 0)
    }

    func testDraftChoicePersistsForOnlyItsDraftAndKeepsTextAndFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-runtime-choice-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("sessions.json")
        let model = AppModel(storageURL: file, playsSounds: false, client: RuntimeChoiceFixture())
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let id = try XCTUnwrap(model.currentID)
        model.draft = "Keep this prompt"
        model.sessions[0].attachments = [Attachment(url: URL(fileURLWithPath: "/tmp/keep-me.txt"))]
        model.sessions.append(CompanionSession(id: "other", title: "Other conversation"))
        model.setRuntime(.codex, for: id)
        let saved = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: file))
        let draft = try XCTUnwrap(saved.first { $0.id == id })
        XCTAssertEqual(draft.runtime, .codex)
        XCTAssertEqual(draft.profileID, RuntimeRoute.defaultProfile(.codex))
        XCTAssertEqual(draft.draft, "Keep this prompt")
        XCTAssertEqual(draft.attachments.first?.url.path, "/tmp/keep-me.txt")
        XCTAssertNil(draft.storedID)
        XCTAssertEqual(saved.first { $0.id == "other" }?.runtime, .hermes)

        // A late choice after the first native session exists keeps its identity.
        model.sessions[0].storedID = "native-thread"
        model.setRuntime(.hermes, for: id)
        XCTAssertEqual(model.current?.runtime, .codex)
    }

    /// The pickers show each agent's bundled mark; an unknown agent keeps its name alone.
    func testEveryAgentLogoLoadsFromTheResourceBundle() throws {
        for runtime in RuntimeKind.allCases {
            let logo = try XCTUnwrap(runtime.logo, "\(runtime.title) has no bundled logo")
            XCTAssertFalse(logo.representations.isEmpty, runtime.title)
            XCTAssertGreaterThan(logo.size.width, 0, runtime.title)
            XCTAssertGreaterThan(logo.size.height, 0, runtime.title)
        }
        XCTAssertNil(RuntimeKind(rawValue: "future-agent")?.logo)
    }

    /// AppKit draws a bundled SVG without filters, embedded HTML, scripts or remote
    /// references, so a mark that needs them ships as a PNG rasterized from it instead.
    func testBundledAgentSVGsUseOnlyWhatAppKitDraws() throws {
        let bundle = CompanionResources.bundle
        func url(_ runtime: RuntimeKind, _ ext: String) -> URL? {
            bundle.url(forResource: runtime.rawValue, withExtension: ext)
                ?? bundle.url(forResource: runtime.rawValue, withExtension: ext, subdirectory: "AgentLogos")
        }
        for runtime in RuntimeKind.allCases {
            XCTAssertEqual([url(runtime, "svg"), url(runtime, "png")].compactMap { $0 }.count, 1, "\(runtime.title) ships one mark")
            guard let svg = url(runtime, "svg") else { continue }
            let text = try String(contentsOf: svg, encoding: .utf8)
            for unsupported in ["<filter", "<foreignObject", "<script", "href=\"http"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(unsupported), "\(runtime.title)'s SVG uses \(unsupported)")
            }
        }
    }
}
