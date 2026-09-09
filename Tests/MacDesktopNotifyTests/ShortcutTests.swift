import XCTest
import AppKit
@testable import MacDesktopNotify

@MainActor
final class ShortcutTests: XCTestCase {
    private func event(flags: NSEvent.ModifierFlags, chars: String = "q") -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: 12)!
    }

    /// Caps Lock 开着的 ⌘Q 仍然必须被认出来（评审 #8）。
    /// 旧实现拿 `intersection(.deviceIndependentFlagsMask) == [.command]`
    /// 做全等比较，而该掩码包含 capsLock / numericPad / function。
    func testQuitShortcutToleratesCapsLock() {
        // 先证明前提：旧代码拿这个掩码做全等比较，而它包含 capsLock。
        XCTAssertTrue(NSEvent.ModifierFlags.deviceIndependentFlagsMask.contains(.capsLock),
                      "掩码包含 capsLock，正是旧全等比较在 Caps Lock 下失效的原因")

        XCTAssertTrue(SettingsWindowController.isQuitShortcut(event(flags: [.command])))
        XCTAssertTrue(SettingsWindowController.isQuitShortcut(event(flags: [.command, .capsLock])))
        XCTAssertTrue(SettingsWindowController.isQuitShortcut(event(flags: [.command, .numericPad])))
    }

    func testQuitShortcutRejectsOtherChords() {
        XCTAssertFalse(SettingsWindowController.isQuitShortcut(event(flags: [.command, .shift])),
                       "⌘⇧Q 是系统注销，必须放行")
        XCTAssertFalse(SettingsWindowController.isQuitShortcut(event(flags: [.command, .option])))
        XCTAssertFalse(SettingsWindowController.isQuitShortcut(event(flags: [.command, .control])))
        XCTAssertFalse(SettingsWindowController.isQuitShortcut(event(flags: [])))
        XCTAssertFalse(SettingsWindowController.isQuitShortcut(event(flags: [.command], chars: "w")),
                       "只有 Q 是关闭窗口")
    }
}
