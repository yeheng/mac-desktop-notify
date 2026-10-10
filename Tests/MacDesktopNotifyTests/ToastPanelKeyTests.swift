import AppKit
import XCTest
@testable import MacDesktopNotify

/// The window capability the comment field depends on.
///
/// `&input=1` opens a one-line `TextField` inside the toast panel, and a
/// text field only accepts keystrokes in a *key* window. The panel is
/// `.nonactivatingPanel` (it must never steal the menu bar from the front
/// app), which does not stop it becoming key — but `canBecomeKey == false`
/// would have made every keystroke vanish with no visible symptom. This pins
/// the capability so the field can never silently go inert again.
@MainActor
final class ToastPanelKeyTests: XCTestCase {
    private func makePanel() -> ToastPanel {
        ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: 362, height: 112),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    func testPanelCanBecomeKeySoTheCommentFieldAcceptsTyping() {
        let panel = makePanel()

        XCTAssertTrue(panel.canBecomeKey,
                      "a comment field in a non-key window renders but drops every keystroke")
    }

    /// The panel borrows key status for one line of typing; it is never the
    /// app's main window, so main status stays with the real windows.
    func testPanelIsNeverTheMainWindow() {
        let panel = makePanel()

        XCTAssertFalse(panel.canBecomeMain)
    }
}
