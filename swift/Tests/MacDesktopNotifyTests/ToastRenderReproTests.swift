import SwiftUI
import XCTest
@testable import MacDesktopNotify

/// Throwaway repro: render the toast stack offscreen for a card whose body is
/// a fenced code block with one long line (the build-warning screenshot), and
/// print the hosting view's fitting size so a width/height blowup is visible
/// in numbers, not pixels.
@MainActor
final class ToastRenderReproTests: SettingsIsolatedTestCase {
    private func makePresentation(body: String, expanded: Bool) -> Presentation {
        let item = CardPayload(
            title: "Build",
            bodyMarkdown: body,
            urgency: .critical,
            timeout: nil
        )
        return Presentation(
            item: item,
            remaining: nil,
            actionsHoldReleased: false,
            policy: DwellPolicy.resolve(
                urgency: .critical, hasActions: false, senderTimeout: nil,
                dwellSeconds: 5, ageOutCriticals: true, timing: .standard
            ),
            expanded: expanded
        )
    }

    private func render(_ name: String) throws -> NSSize {
        let hosting = NSHostingView(rootView: ToastStackView())
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        print("=== FITTING \(name): \(fitting)")
        hosting.frame = NSRect(origin: .zero, size: fitting)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("no bitmap rep")
            return fitting
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])
        try png?.write(to: URL(fileURLWithPath: "/tmp/toast-\(name).png"))
        return fitting
    }

    func testRenderLongCodeLine() throws {
        let warning = "instance method 'windowWillClose' nearly matches optional requirement 'windowWillClose' of protocol 'NSWindowDelegate'"
        let multiLine = """
        /Users/yeheng/workspaces/mac-desktop-notify/Sources/MacDesktopNotify/UtilityWindowController.swift:43:10: warning: \(warning)
        41 |     }
        42 |
        43 |     func windowWillClose(_ notification: CardPayload) {
        44 |         WindowShortcuts.remove(keyMonitor)
        45 |         keyMonitor = nil
        46 |     }
        /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/AppKit.framework/Headers/NSWindow.h:914:1: note: requirement 'windowWillClose' declared here
        912 | - (void)windowDidBecomeMain:(NSNotification *)notification NS_SWIFT_UI_ACTOR;
        913 | - (void)windowDidResignMain:(NSNotification *)notification NS_SWIFT_UI_ACTOR;
        914 | - (void)windowWillClose:(NSNotification *)notification NS_SWIFT_UI_ACTOR;
        """
        let manager = NotificationManager.shared
        manager.presentations = [makePresentation(body: "```\n\(warning)\n```", expanded: true)]
        let expanded = try render("expanded-code")

        manager.presentations = [makePresentation(body: "```\n\(multiLine)\n```", expanded: true)]
        let expandedMulti = try render("expanded-multiline")

        manager.presentations = [makePresentation(body: "```\n\(warning)\n```", expanded: false)]
        let collapsed = try render("collapsed-code")

        print("=== expanded \(expanded) expandedMulti \(expandedMulti) collapsed \(collapsed)")
        manager.presentations = []
    }
}
