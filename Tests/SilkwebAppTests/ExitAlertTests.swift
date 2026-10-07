import AppKit
import XCTest

@testable import Silkweb

/// #111: one unsaved-exit alert with the verb of the action, and destructive discard buttons.
@MainActor
final class ExitAlertTests: XCTestCase {
    func testQuitAndCloseWindowUseTheirOwnVerbAndDestructiveRole() {
        _ = NSApplication.shared
        let quit = DocumentSession.exitAlert(.quit)
        XCTAssertEqual(quit.messageText, "Some changes couldn’t be saved.")
        XCTAssertEqual(
            quit.informativeText, "They’ll be kept as a recovery draft and offered the next time you open Silkweb.")
        XCTAssertEqual(quit.buttons.map(\.title), ["Cancel", "Quit Anyway"])
        XCTAssertEqual(quit.buttons.map(\.hasDestructiveAction), [false, true])
        // Like the deleted-document Close alert: Escape cancels and no key equivalent discards.
        XCTAssertEqual(quit.buttons.map(\.keyEquivalent), ["\u{1B}", ""], "Return never discards")

        let close = DocumentSession.exitAlert(.closeWindow)
        XCTAssertEqual(close.messageText, "Some changes couldn’t be saved.")
        XCTAssertEqual(
            close.informativeText,
            "They’ll be kept as a recovery draft and offered the next time you open the document.")
        XCTAssertEqual(close.buttons.map(\.title), ["Cancel", "Close Anyway"])
        XCTAssertEqual(close.buttons.map(\.hasDestructiveAction), [false, true])
        XCTAssertEqual(close.buttons.map(\.keyEquivalent), ["\u{1B}", ""])
    }

    func testDiscardRecoveredTextAlertIsSplitAndDestructive() {
        _ = NSApplication.shared
        let alert = DocumentSession.discardRecoveryAlert()
        XCTAssertEqual(alert.messageText, "Discard the recovered text?")
        XCTAssertEqual(alert.informativeText, "This can’t be undone.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Discard Recovered Text"])
        XCTAssertEqual(alert.buttons.map(\.hasDestructiveAction), [false, true])
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\u{1B}", ""])
    }
}
