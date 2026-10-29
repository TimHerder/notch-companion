import XCTest
import AppKit
@testable import NotchCompanion

final class NativeInputTests: XCTestCase {
    @MainActor private func editor() -> ComposerTextView {
        _ = NSApplication.shared
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        view.font = .systemFont(ofSize: 13)
        view.isRichText = false
        view.textContainerInset = NSSize(width: 0, height: 3)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        return view
    }

    private func returnEvent(_ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\r", charactersIgnoringModifiers: "\r",
                         isARepeat: false, keyCode: 36)!
    }

    @MainActor func testNotchPanelStaysAboveTheMenuBar() {
        _ = NSApplication.shared
        // Below the menu bar, clicks in the top band reach the menu bar instead.
        XCTAssertGreaterThan(CompanionPanel(canTakeFocus: false).level.rawValue, NSWindow.Level.mainMenu.rawValue)
    }

    @MainActor func testReturnAndCommandReturnSubmitWithoutChangingDraft() {
        let view = editor()
        view.string = "Keep this draft"
        var submissions = 0
        view.onSubmit = { submissions += 1 }
        view.keyDown(with: returnEvent())
        view.keyDown(with: returnEvent(.command))
        XCTAssertEqual(submissions, 2)
        XCTAssertEqual(view.string, "Keep this draft")
    }

    @MainActor func testShiftReturnAddsNewlineWithoutSubmitting() {
        let view = editor()
        view.string = "First line"
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        var submissions = 0
        view.onSubmit = { submissions += 1 }
        view.keyDown(with: returnEvent(.shift))
        XCTAssertEqual(view.string, "First line\n")
        XCTAssertEqual(submissions, 0)
    }

    @MainActor func testMarkedTextReturnDoesNotSubmitPrompt() {
        let view = editor()
        var submissions = 0
        view.onSubmit = { submissions += 1 }
        view.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.keyDown(with: returnEvent())
        XCTAssertEqual(submissions, 0)
    }

    @MainActor func testLongDraftHeightRemainsBoundedAtFourLines() {
        let view = editor()
        view.string = "One line"
        let oneLine = view.boundedHeight
        view.string = Array(repeating: "A line of instructions", count: 40).joined(separator: "\n")
        let longDraft = view.boundedHeight
        let lineHeight = view.layoutManager!.defaultLineHeight(for: view.font!)
        XCTAssertGreaterThan(longDraft, oneLine)
        XCTAssertLessThanOrEqual(longDraft, ceil(lineHeight * 4 + 2 * view.textContainerInset.height))
        XCTAssertEqual(view.string.components(separatedBy: "\n").count, 40)
    }

    func testSingleChoiceAndCustomAnswerAreMutuallyExclusive() {
        var draft = ClarificationAnswerState()
        draft.choose("Sage", multiple: false)
        draft.choose("Pearl", multiple: false)
        XCTAssertEqual(draft.answer(choices: ["Sage", "Pearl"], multiple: false), "Pearl")
        draft.usesFreeText = true
        draft.freeText = "  Neutral white  "
        XCTAssertEqual(draft.answer(choices: ["Sage", "Pearl"], multiple: false), "Neutral white")
        draft.choose("Sage", multiple: false)
        XCTAssertEqual(draft.answer(choices: ["Sage", "Pearl"], multiple: false), "Sage")
    }

    func testMultipleChoiceReplyPreservesChoiceOrderAndCustomAnswer() {
        var draft = ClarificationAnswerState()
        draft.choose("Third", multiple: true)
        draft.choose("First", multiple: true)
        draft.usesFreeText = true
        draft.freeText = "  Something else  "
        XCTAssertEqual(draft.answer(choices: ["First", "Second", "Third"], multiple: true), "First, Third, Something else")
        draft.choose("First", multiple: true)
        XCTAssertEqual(draft.answer(choices: ["First", "Second", "Third"], multiple: true), "Third, Something else")
    }

    func testWhitespaceOnlyFreeTextCannotBecomeAReply() {
        var draft = ClarificationAnswerState()
        draft.freeText = " \n\t "
        XCTAssertTrue(draft.answer(choices: [], multiple: false).isEmpty)
    }
}
