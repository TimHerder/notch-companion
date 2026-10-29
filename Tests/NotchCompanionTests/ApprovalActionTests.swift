import XCTest
@testable import NotchCompanion

final class ApprovalActionTests: XCTestCase {
    func testNoOneTimeApprovalWhenRuntimeOffersOnlySessionOrCancellation() {
        XCTAssertEqual(ApprovalAction.offered(in: ["session", "cancel"]), [.session, .cancel])
    }

    func testPersistentAndUnknownApprovalScopesCannotBecomeAnAllowAction() {
        XCTAssertEqual(ApprovalAction.offered(in: ["always", "unknown"]), [.deny])
        XCTAssertEqual(ApprovalAction.offered(in: ["once", "always", "deny"]), [.once, .deny])
    }

    func testDenyOnlyRequestCannotOfferPermission() {
        XCTAssertEqual(ApprovalAction.offered(in: ["deny"]), [.deny])
    }
}
