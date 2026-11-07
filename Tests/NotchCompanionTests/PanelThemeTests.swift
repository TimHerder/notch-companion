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

        // Instrument: orange only for live work; the primary key is lit white and
        // the other statuses use the island's colors.
        PanelTheme.current = .instrument
        XCTAssertNotEqual(CompanionStyle.accent, CompanionStyle.signal)
        XCTAssertEqual(CompanionStyle.color(.working), CompanionStyle.signal)
        XCTAssertEqual(CompanionStyle.indicatorColor(.running), CompanionStyle.signal)
        XCTAssertEqual(CompanionStyle.color(.waiting), IslandStyle.amber)
        XCTAssertEqual(CompanionStyle.indicatorColor(.waiting), IslandStyle.amber)
        XCTAssertEqual(CompanionStyle.color(.finished), IslandStyle.indicatorColor(.finished))
        XCTAssertEqual(CompanionStyle.color(.failed), IslandStyle.error)
        XCTAssertEqual(CompanionStyle.amber, IslandStyle.amber)
        XCTAssertEqual(NotchRowButtonStyle().cornerRadius, CompanionStyle.radius)

        XCTAssertEqual(island.0, IslandStyle.accent)
        XCTAssertEqual(island.1, IslandStyle.text)
        XCTAssertEqual(island.2, IslandStyle.indicatorColor(.running))
    }
}
