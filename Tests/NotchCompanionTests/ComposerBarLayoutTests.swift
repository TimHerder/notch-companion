import AppKit
import SwiftUI
import XCTest
@testable import NotchCompanion

private struct ComposerFixture: View {
    @ObservedObject var model: AppModel
    var isCompact = true
    var showsTitle = false
    @FocusState private var focused: Bool
    var body: some View { ComposerView(model: model, focused: $focused, isCompact: isCompact, showsTitle: showsTitle) }
}

/// The composer's field and the settings row under it must fit the compact
/// column with every control on: the bar's leading items give way so the field
/// never spills past the margins.
@MainActor final class ComposerBarLayoutTests: XCTestCase {
    func testStartedSessionBarWithEveryControlFitsTheCompactColumnInEveryDesign() throws {
        let savedTheme = PanelTheme.current
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("composer-bar-\(UUID().uuidString)")
        let suite = "composer-bar-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, preferences: preferences)
        defer {
            PanelTheme.current = savedTheme
            model.shutdown(); preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        model.page = .session
        model.showModelPicker = true
        model.showContextUsage = true
        model.showPermissionModes = true
        model.showSnapShot = true
        model.snapShotSource = SnapShotSource(processID: 1, appName: "Safari", windowID: 1, title: "Release notes")
        model.sessions[0].runtime = .hermes
        model.sessions[0].storedID = "native-session"
        model.sessions[0].workspacePath = "/tmp/A deliberately long project folder name"
        model.sessions[0].runtimeInfo = RuntimeSessionInfo(model: "fixture-long-context-model", provider: "fixture-provider",
            context: RuntimeContextUsage(used: 42000, limit: 200000, estimated: true))
        model.draft = "Summarize the changes."
        // The compact panel's 560-point width less its 20-point margins.
        let column: CGFloat = 520
        // Legacy Hermes adds its label and Continue in Hermes…; a started session elsewhere keeps its harness label.
        // Runtime default (no model known) keeps its whole label and still fits.
        for (legacy, name) in [(true, "fixture-long-context-model"), (false, "fixture-long-context-model"), (true, nil)] {
            model.sessions[0].isLegacyPrivate = legacy
            model.sessions[0].runtimeInfo?.model = name
            XCTAssertFalse(model.canChangeRuntime(model.sessions[0].id))
            for theme in PanelTheme.allCases {
                PanelTheme.current = theme
                let size = NSHostingController(rootView: ComposerFixture(model: model))
                    .sizeThatFits(in: CGSize(width: column, height: 1000))
                XCTAssertLessThanOrEqual(size.width, column, "\(theme.label)'s composer spills past the column (legacy: \(legacy), \(name ?? "Runtime default"))")
            }
        }
        model.sessions[0].runtimeInfo?.model = "fixture-long-context-model"
        // Codex adds permission modes and a reasoning effort; archiving adds Restore.
        model.sessions[0].isLegacyPrivate = false
        model.sessions[0].runtime = .codex
        model.sessions[0].permissionMode = nil
        let choice = RuntimeModelChoice(model: "fixture-long-context-model", provider: "fixture-provider", reasoningEffort: "xhigh")
        model.sessions[0].modelOverride = choice
        model.modelCatalogs[model.modelCatalogKey(for: model.sessions[0])] = RuntimeModelCatalog(defaultModel: choice, models: [
            RuntimeModelOption(choice: choice, title: "Fixture long context model", reasoningEfforts: ["low", "medium", "high", "xhigh"])])
        for archived in [false, true] {
            model.sessions[0].isArchived = archived
            for theme in PanelTheme.allCases {
                PanelTheme.current = theme
                let size = NSHostingController(rootView: ComposerFixture(model: model))
                    .sizeThatFits(in: CGSize(width: column, height: 1000))
                XCTAssertLessThanOrEqual(size.width, column, "\(theme.label)'s Codex composer spills past the column (archived: \(archived))")
            }
        }
    }
}
