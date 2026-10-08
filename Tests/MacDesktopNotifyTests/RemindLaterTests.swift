import XCTest
@testable import MacDesktopNotify

@MainActor
final class RemindLaterTests: SettingsIsolatedTestCase {

    private func make(_ title: String, urgency: UrgencyLevel = .normal) -> CardPayload {
        CardPayload(title: title, bodyMarkdown: "", urgency: urgency, timeout: 60)
    }

    /// Reminding retires the live message the way every retirement does: no
    /// queue, the message waits in history, unread. The reminder is armed.
    func testRemindRetiresTheLiveMessageIntoHistory() {
        let m = NotificationManager()
        m.push(make("deploy"))
        let item = m.current!

        m.remindMeLater(for: item.id, duration: .seconds(1800))

        XCTAssertNil(m.current, "the reminder retires the card - there is no queue to promote")
        XCTAssertEqual(m.historyCount, 1, "the message stays in history")
        XCTAssertFalse(m.isRead(item), "deferring is not reading")
        XCTAssertTrue(m.delayed.isActive(.remindResurface), "the reminder is armed")
        XCTAssertEqual(m.snoozedReminderItem?.id, item.id)
    }

    /// To the minute, the message comes back exactly like a fresh push - same
    /// id, presented, and NOT duplicated in history: it never left.
    func testResurfacePresentsWithoutDuplicatingHistory() {
        let m = NotificationManager()
        m.push(make("deploy"))
        let item = m.current!

        m.remindMeLater(for: item.id, duration: .seconds(1800))
        m.resurfaceReminder()

        XCTAssertEqual(m.current?.id, item.id, "the same message returns, not a copy")
        XCTAssertTrue(m.presentations.contains { $0.item.id == item.id }, "the reminder re-presents as a card")
        XCTAssertEqual(m.historyCount, 1, "the reminder must not re-record the message")
        XCTAssertNil(m.snoozedReminderItem, "one firing consumes the reminder")
    }

    /// The wiring through DelayedEvents actually fires the closure.
    func testScheduledReminderFiresThroughDelayedEvents() async {
        let m = NotificationManager()
        m.push(make("deploy"))
        let item = m.current!

        m.remindMeLater(for: item.id, duration: .milliseconds(50))
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(m.current?.id, item.id, "the armed reminder resurfaced on its own")
    }

    /// Read since the reminder was armed: the message stays where the user
    /// put it - 历史. A reminder for read mail is noise.
    func testResurfaceSkipsWhenAlreadyRead() {
        let m = NotificationManager()
        m.push(make("deploy"))
        let item = m.current!

        m.remindMeLater(for: item.id, duration: .seconds(1800))
        m.setRead(item.id, read: true)
        m.resurfaceReminder()

        XCTAssertNil(m.current)
    }

    /// Deleted since: nothing to bring back. The contains-check keeps a stale
    /// reminder from resurrecting ghosts.
    func testResurfaceSkipsWhenDeleted() {
        let m = NotificationManager()
        m.push(make("deploy"))
        let item = m.current!

        m.remindMeLater(for: item.id, duration: .seconds(1800))
        m.removeHistory(id: item.id)
        m.resurfaceReminder()

        XCTAssertNil(m.current)
        XCTAssertEqual(m.historyCount, 0)
    }

    /// A critical holding the screen keeps it, exactly like `push`: the normal
    /// A critical reminder joins the stack regardless of what else is on it.
    func testCriticalReminderJoinsTheStack() {
        let m = NotificationManager()
        m.push(make("crit", urgency: .critical))
        m.remindMeLater(for: m.current!.id, duration: .seconds(1800))
        m.push(make("plain"))

        m.resurfaceReminder()

        XCTAssertEqual(m.presentations.map(\.item.title), ["plain", "crit"],
                       "the reminder rejoins the stack the moment it comes back")
        XCTAssertEqual(m.unreadCount, 2, "neither message has been opened")
    }

    /// A critical reminder displaces whatever holds the screen, as any
    /// critical push would.
    func testCriticalReminderDisplaces() {
        let m = NotificationManager()
        m.push(make("crit", urgency: .critical))
        let item = m.current!
        m.remindMeLater(for: item.id, duration: .seconds(1800))
        m.push(make("plain"))                        // owns the screen now

        m.resurfaceReminder()

        XCTAssertEqual(m.current?.id, item.id, "a critical reminder takes the screen back")
    }

    /// Away with quiet mode holding: the reminder must not light up a locked
    /// screen. The message stays in history; the return-from-away announce
    /// covers it.
    func testResurfaceStaysDownWhileQuiet() {
        let m = NotificationManager()
        m.push(make("deploy"))
        m.remindMeLater(for: m.current!.id, duration: .seconds(1800))

        AppSettings.shared.quietMode = .historyOnly
        m.isAway = true
        m.resurfaceReminder()

        XCTAssertNil(m.current, "quiet mode holds the reminder down")
    }

    /// A second reminder replaces the first: one reminder in flight, ever.
    func testNewRemindReplacesThePendingOne() {
        let m = NotificationManager()
        m.push(make("first"))
        m.remindMeLater(for: m.current!.id, duration: .seconds(1800))

        m.push(make("second"))
        let second = m.current!
        m.remindMeLater(for: second.id, duration: .seconds(3600))

        XCTAssertEqual(m.snoozedReminderItem?.id, second.id, "the newest reminder wins")
        XCTAssertEqual(m.unreadCount, 2, "the dropped reminder leaves the first message unread in history")
    }
}
