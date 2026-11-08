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

/// The composer's one bar must fit the compact column with every control on:
/// its leading items give way so the field never spills past the margins.
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

    /// A short model name and Runtime default keep their width beside a long session
    /// name in the full window's bar, instead of collapsing to a lone "…".
    func testShortModelNameAndRuntimeDefaultKeepTheirWidthBesideALongSessionName() throws {
        _ = NSApplication.shared
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
        model.showModelPicker = true
        model.showContextUsage = true
        model.sessions[0].runtime = .codex
        model.sessions[0].storedID = "native-session"
        // A short folder, so a short session name leaves the bar room to spare.
        model.sessions[0].workspacePath = "/tmp/Site"
        // The full window at its minimum width, less the 252-point sidebar and the 22-point margins.
        let bar: CGFloat = 780 - 252 - 44
        let longTitle = String(String(repeating: "A long session name ", count: 4).prefix(64))
        // SwiftUI builds no accessibility tree without a client, so the label is found by its pixels.
        func render(_ title: String, model shown: Bool) throws -> NSBitmapImageRep {
            model.sessions[0].title = title
            model.showModelPicker = shown
            let fixture = ComposerFixture(model: model, isCompact: false, showsTitle: true)
            // A whole label's fractional width can round the bar up by half a point (one pixel).
            XCTAssertLessThanOrEqual(NSHostingController(rootView: fixture).sizeThatFits(in: CGSize(width: bar, height: 1000)).width, bar + 0.5,
                                     "\(PanelTheme.current.label)'s bar spills past the window")
            let hosting = NSHostingView(rootView: fixture)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: bar, height: 80),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            return bitmap
        }
        func differs(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, column x: Int) -> Bool {
            (0..<a.pixelsHigh).contains { a.colorAt(x: x, y: $0) != b.colorAt(x: x, y: $0) }
        }
        for name in ["gpt-5.2", nil] {
            model.sessions[0].runtimeInfo = RuntimeSessionInfo(model: name, provider: nil,
                context: RuntimeContextUsage(used: 42000, limit: 200000, estimated: true))
            for theme in PanelTheme.allCases {
                PanelTheme.current = theme
                let label = "\(theme.label), \(name ?? "Runtime default")"
                // With a short session name, the columns the model control alone draws are its natural width.
                let natural = try render("Notes", model: true), without = try render("Notes", model: false)
                let columns = (0..<natural.pixelsWide).filter { differs(natural, without, column: $0) }
                XCTAssertGreaterThan(columns.count, 20, label)
                // Beside a 64-character name it draws the same, in the same place.
                let crowded = try render(longTitle, model: true)
                XCTAssertFalse(columns.contains { differs(natural, crowded, column: $0) }, "\(label) gives way to the session name")
            }
        }
    }
}
