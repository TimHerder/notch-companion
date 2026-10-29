import XCTest
@testable import NotchCompanion

@MainActor final class NotchUpdateSettingsTests: XCTestCase {
    func testCombinedPreferenceMigratesWithoutChangingAppearanceOnLayoutChange() {
        for legacy in [nil, "shoulder", "mascot", "unknown"] as [String?] {
            let suite = "notch-update-settings-\(UUID().uuidString)"
            let preferences = UserDefaults(suiteName: suite)!
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            defer {
                preferences.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: folder)
            }
            preferences.set(legacy, forKey: NotchUpdateStyle.key)
            let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false,
                                 client: UpdateSettingsTransport(), preferences: preferences)
            let expectedStyle: NotchUpdateStyle = legacy == "shoulder" ? .compact : .popup
            let expectedAppearance: CompanionAppearance = legacy == "shoulder" ? .eyes : .mascot
            XCTAssertEqual(model.updateStyle, expectedStyle)
            XCTAssertEqual(model.companionAppearance, expectedAppearance)
            XCTAssertEqual(preferences.string(forKey: NotchUpdateStyle.key), expectedStyle.rawValue)
            XCTAssertEqual(preferences.string(forKey: CompanionAppearance.key), expectedAppearance.rawValue)
            model.updateStyle = expectedStyle == .compact ? .popup : .compact
            model.shutdown()

            let reopened = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false,
                                    client: UpdateSettingsTransport(), preferences: preferences)
            XCTAssertEqual(reopened.updateStyle, model.updateStyle)
            XCTAssertEqual(reopened.companionAppearance, expectedAppearance, "Changing layout must not change the character after relaunch")
            reopened.shutdown()
        }
    }

    func testAllFourCombinationsPersistAndPopupAnswersUseAvailableWidth() throws {
        let suite = "notch-update-settings-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false,
                             client: UpdateSettingsTransport(), preferences: preferences)
        defer { model.shutdown() }
        for style in NotchUpdateStyle.allCases {
            for appearance in CompanionAppearance.allCases {
                model.updateStyle = style
                model.companionAppearance = appearance
                let reopened = AppModel(storageURL: folder.appendingPathComponent("reopened.json"), playsSounds: false,
                                        client: UpdateSettingsTransport(), preferences: preferences)
                defer { reopened.shutdown() }
                XCTAssertEqual(reopened.updateStyle, style)
                XCTAssertEqual(reopened.companionAppearance, appearance)
                // Until the selected character is rendered, Mascot falls back to the eyes.
                let mascot = appearance == .mascot && reopened.mascotLibrary.isAvailable
                XCTAssertEqual(reopened.mascotEnabled, mascot)
                reopened.sessions = [CompanionSession(id: "plan", runtimeID: "live", title: "Plan the release", state: .waiting)]
                reopened.requests = [PendingRequest(id: "q", kind: .clarification, title: "Question", detail: "What ships first?",
                                                    choices: ["The glance", "The aura", "Both together in one release"], sessionID: "live")]
                reopened.setAnnouncementForPreview(NotchAnnouncement(kind: .needsInput, sessionID: "plan", title: "Plan the release"))
                if style == .popup {
                    let content = try XCTUnwrap(reopened.stageContent)
                    XCTAssertEqual(reopened.stageTextInset, mascot ? 150 : 20)
                    XCTAssertEqual(content.textWidth, mascot ? 276 : 406)
                    XCTAssertEqual(content.choiceRows.count, mascot ? 2 : 1)
                    XCTAssertTrue(content.acceptsText)
                    XCTAssertEqual(reopened.stageAnswerRows, content.choiceRows.count + 1)
                } else {
                    XCTAssertNil(reopened.stageContent)
                    XCTAssertEqual(reopened.stageAnswerRows, 0)
                }
            }
        }
    }
}

@MainActor private final class UpdateSettingsTransport: HermesTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws {}
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}
