import SwiftUI
import XCTest
@testable import NotchCompanion

/// The expanded panel's design setting and the tokens it selects.
final class PanelThemeTests: XCTestCase {
    private var saved: Any?
    private var savedCurrent = PanelTheme.current

    override func setUp() {
        saved = UserDefaults.standard.object(forKey: PanelTheme.key)
        savedCurrent = PanelTheme.current
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: PanelTheme.key)
        PanelTheme.current = savedCurrent
    }

    func testRefinedIsTheDefaultAndUnknownValuesFallBackToIt() {
        UserDefaults.standard.removeObject(forKey: PanelTheme.key)
        XCTAssertEqual(PanelTheme.stored, .refined)
        UserDefaults.standard.set("obsidian", forKey: PanelTheme.key)
        XCTAssertEqual(PanelTheme.stored, .refined)
    }

    func testTheChoicePersistsUnderItsKey() {
        XCTAssertEqual(PanelTheme.key, "notch.panelTheme")
        for theme in PanelTheme.allCases {
            UserDefaults.standard.set(theme.rawValue, forKey: PanelTheme.key)
            XCTAssertEqual(PanelTheme.stored, theme)
        }
        XCTAssertEqual(PanelTheme.allCases.map(\.label), ["Refined", "Tahoe", "Instrument"])
    }

    func testTokensFollowTheCurrentThemeWhileTheIslandKeepsItsOwn() {
        let island = (IslandStyle.accent, IslandStyle.text, IslandStyle.indicatorColor(.running))

        PanelTheme.current = .refined
        XCTAssertEqual(CompanionStyle.accent, IslandStyle.accent)
        XCTAssertEqual(CompanionStyle.text, IslandStyle.text)
        // Refined's working status uses the island's orange; finished its green.
        XCTAssertEqual(CompanionStyle.color(.working), IslandStyle.indicatorColor(.running))
        XCTAssertEqual(NotchRowButtonStyle().cornerRadius, 10)

        PanelTheme.current = .tahoe
        XCTAssertEqual(CompanionStyle.accent, .accentColor)
        XCTAssertEqual(CompanionStyle.color(.finished), CompanionStyle.green)

        PanelTheme.current = .instrument
        XCTAssertEqual(CompanionStyle.accent, CompanionStyle.signal)
        XCTAssertEqual(CompanionStyle.color(.waiting), CompanionStyle.signal)
        XCTAssertEqual(CompanionStyle.color(.finished), CompanionStyle.text)
        XCTAssertEqual(NotchRowButtonStyle().cornerRadius, CompanionStyle.radius)

        XCTAssertEqual(island.0, IslandStyle.accent)
        XCTAssertEqual(island.1, IslandStyle.text)
        XCTAssertEqual(island.2, IslandStyle.indicatorColor(.running))
    }
}
