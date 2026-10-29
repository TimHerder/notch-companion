import XCTest
@testable import NotchCompanion

final class AppVersionTests: XCTestCase {
    func testPreviewCannotDisplayAsAnOfficialRelease() {
        let metadata: [String: Any] = [
            "NotchCompanionReleaseVersion": "2026.10.28-r2",
            "CFBundleVersion": "3",
            "NotchCompanionPreview": "pr-1-abcdef123456"
        ]
        XCTAssertEqual(AppVersion.label(metadata: metadata), "Notch Companion · Preview pr-1-abcdef123456")
    }

    func testReleaseAndUnbundledDevelopmentLabels() {
        XCTAssertEqual(AppVersion.label(metadata: [
            "NotchCompanionReleaseVersion": "2026.10.28-r2", "CFBundleVersion": "3"
        ]), "Notch Companion 2026.10.28-r2 · Build 3")
        XCTAssertEqual(AppVersion.label(metadata: [:]), "Notch Companion · Development build")
    }
}
