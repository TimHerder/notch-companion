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

    private func arrow(up: Bool, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        let key = up ? NSUpArrowFunctionKey : NSDownArrowFunctionKey
        let characters = String(Character(UnicodeScalar(UInt16(key))!))
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers.union([.function, .numericPad]),
                                timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: up ? 126 : 125)!
    }

    @MainActor func testArrowsRecallEarlierPromptsOnlyFromAnEmptyComposer() {
        let view = editor()
        view.recallPrompts = { ["First prompt", "Line one\nLine two", "Latest prompt"] }
        var edits = 0
        view.onEditQueued = { edits += 1; return false }
        view.keyDown(with: arrow(up: false))
        XCTAssertEqual(view.string, "", "↓ in an empty composer recalls nothing")
        view.keyDown(with: arrow(up: true))
        XCTAssertEqual(view.string, "Latest prompt")
        view.keyDown(with: arrow(up: true))
        XCTAssertEqual(view.string, "Line one\nLine two")
        XCTAssertEqual(view.selectedRange().location, ("Line one\nLine two" as NSString).length, "The caret lands after the recalled text")
        view.keyDown(with: arrow(up: true))
        XCTAssertEqual(view.string, "Line one\nLine two", "A recalled prompt's own lines take the caret first")
        // Offscreen, AppKit's own caret movement is not reliable; place it on the first line.
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.keyDown(with: arrow(up: true))
        XCTAssertEqual(view.string, "First prompt")
        view.keyDown(with: arrow(up: true))
        XCTAssertEqual(view.string, "First prompt", "↑ stays at the oldest prompt")
        view.keyDown(with: arrow(up: false))
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.keyDown(with: arrow(up: false))
        view.keyDown(with: arrow(up: false))
        XCTAssertEqual(view.string, "", "↓ past the newest prompt returns to empty")
        view.keyDown(with: arrow(up: true, .option))
        XCTAssertEqual(edits, 1, "Option–↑ still edits the newest queued message")
        XCTAssertEqual(view.string, "")

        view.keyDown(with: arrow(up: true))
        view.insertText("!", replacementRange: view.selectedRange())
        view.keyDown(with: arrow(up: true))
        XCTAssertEqual(view.string, "Latest prompt!", "Once edited, the arrows move the caret again")
        view.string = "Typed draft"
        view.keyDown(with: arrow(up: true))
        XCTAssertEqual(view.string, "Typed draft")
    }

    @MainActor func testRecalledWrappedParagraphMovesTheCaretBeforeGoingBack() {
        let view = editor()
        let paragraph = String(repeating: "A paragraph that wraps across several displayed lines. ", count: 6)
        view.recallPrompts = { ["Older prompt", paragraph] }
        view.keyDown(with: arrow(up: true))
        XCTAssertEqual(view.string, paragraph)
        view.keyDown(with: arrow(up: true))
        XCTAssertEqual(view.string, paragraph, "From a wrapped last line, ↑ moves the caret up")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.keyDown(with: arrow(up: true))
        XCTAssertEqual(view.string, "Older prompt", "From the first displayed line, ↑ goes back")
        view.keyDown(with: arrow(up: false))
        // ⌘→ on the line above the last leaves the caret at the wrap with upstream affinity, still on that line.
        var lastLine = NSRange()
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        view.layoutManager!.lineFragmentRect(forGlyphAt: view.layoutManager!.numberOfGlyphs - 1, effectiveRange: &lastLine)
        view.setSelectedRange(NSRange(location: lastLine.location, length: 0), affinity: .upstream, stillSelecting: false)
        view.keyDown(with: arrow(up: false))
        XCTAssertEqual(view.string, paragraph, "At the end of a wrapped line above the last, ↓ moves the caret down")
    }

    @MainActor func testPasteStaysEnabledForAPictureAlone() {
        let view = editor()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("notch-validate-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        view.pasteboard = pasteboard
        view.onPaste = { _ in true }
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pasteboard.clearContents(); pasteboard.writeObjects([NSImage(cgImage: context.makeImage()!, size: NSSize(width: 2, height: 2))])
        let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        XCTAssertTrue(view.validateUserInterfaceItem(item), "⌘V reaches the composer, which stages or refuses the picture")
    }

    @MainActor func testPasteRoutingAndQuotes() {
        let view = editor()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("notch-input-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        view.pasteboard = pasteboard
        let long = String(repeating: "b", count: 40_000)
        pasteboard.clearContents(); pasteboard.setString(long, forType: .string)
        var offered = 0
        view.onPaste = { _ in offered += 1; return true }
        view.paste(nil)
        XCTAssertEqual(offered, 1)
        XCTAssertEqual(view.string, "", "A staged paste types nothing")
        view.pasteAsPlainText(nil)
        XCTAssertEqual(offered, 1, "⌘⇧V never stages")
        XCTAssertEqual(view.string, long, "⌘⇧V types the text however long")

        XCTAssertEqual(ComposerTextView.blockQuote("  First line\n\nSecond line\n"), "> First line\n>\n> Second line\n\n")
        view.string = "Before"
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertAtCaret(ComposerTextView.blockQuote("Quoted"))
        XCTAssertEqual(view.string, "Before\n> Quoted\n\n", "A quote starts on its own line and keeps the draft")
        view.string = "Ask about this"
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertAtCaret(ComposerTextView.blockQuote("Quoted"))
        XCTAssertEqual(view.string, "> Quoted\n\nAsk about this")
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
