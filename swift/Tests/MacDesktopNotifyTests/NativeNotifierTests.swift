import XCTest
@testable import MacDesktopNotify

/// The system-notification mirror: what it decides, and what it sends.
///
/// These tests deliberately never touch `UNUserNotificationCenter` — the
/// routing table and the content mapping are pure functions, and the AppKit
/// shell around them needs a window server this suite does not have. The spy
/// below is how the ingress' wiring is observed instead.
@MainActor
final class NativeNotifierTests: SettingsIsolatedTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
        AppSettings.shared.resetForTests()
    }

    private func make(
        _ title: String,
        body: String = "",
        urgency: UrgencyLevel = .normal,
        group: String? = nil,
        tags: [String] = [],
        native: Bool? = nil
    ) -> CardPayload {
        CardPayload(
            title: title, bodyMarkdown: body, urgency: urgency, timeout: 60,
            group: group, tags: tags, native: native
        )
    }

    // MARK: - Routing table

    /// The whole three-way table. `.auto` is the default, so its two cells are
    /// the ones a regression would silently break.
    func testAutoMirrorsOnlyWhenTheCardsCannotCarryIt() {
        XCTAssertFalse(NativeRouting.shouldDeliver(mode: .auto, outcome: .displayed, suppressed: false),
                       "a message on screen must not be duplicated")
        XCTAssertTrue(NativeRouting.shouldDeliver(mode: .auto, outcome: .withheld, suppressed: false),
                      "a withheld message has no cards at all")
        XCTAssertTrue(NativeRouting.shouldDeliver(mode: .auto, outcome: .displayed, suppressed: true),
                      "a suppressed display leaves the message unreachable on screen")
    }

    func testOffNeverMirrorsAndAlwaysMirrorsEverything() {
        XCTAssertFalse(NativeRouting.shouldDeliver(mode: .off, outcome: .withheld, suppressed: true))
        XCTAssertFalse(NativeRouting.shouldDeliver(mode: .off, outcome: .displayed, suppressed: false))

        XCTAssertTrue(NativeRouting.shouldDeliver(mode: .always, outcome: .displayed, suppressed: false))
        XCTAssertTrue(NativeRouting.shouldDeliver(mode: .always, outcome: .withheld, suppressed: true))
    }

    /// The sender's `native` field outranks the app-wide setting in both
    /// directions — that is the whole point of shipping it.
    func testSenderOverrideBeatsTheGlobalSetting() {
        for mode in NativeNotificationMode.allCases {
            XCTAssertTrue(NativeRouting.shouldDeliver(
                mode: mode, outcome: .displayed, suppressed: false, override: true),
                "native:true mirrors even with the feature off")
            XCTAssertFalse(NativeRouting.shouldDeliver(
                mode: mode, outcome: .withheld, suppressed: true, override: false),
                "native:false suppresses even under always")
        }
    }

    /// An absent override must fall through, not be read as `false` — the
    /// tri-state is the whole reason the field is `Bool?`.
    func testAbsentOverrideFallsThroughToTheSetting() {
        XCTAssertNil(make("t").native)
        XCTAssertEqual(NativeRouting.shouldDeliver(mode: .always, outcome: .displayed, suppressed: false),
                       NativeRouting.shouldDeliver(mode: .always, outcome: .displayed, suppressed: false, override: nil))
    }

    /// Forcing the mirror on must not double the noise: sound stays tied to
    /// "the cards were not heard".
    func testOverrideDoesNotGrantSound() {
        XCTAssertFalse(NativeRouting.soundAllowed(outcome: .displayed, suppressed: false),
                       "a card on screen was heard; the mirror stays silent")
    }

    /// The invariant that keeps `.always` tolerable: the mirror only speaks
    /// when the cards were not heard.
    func testSoundAllowedIsExactlyWhenTheCardsWereSilent() {
        XCTAssertTrue(NativeRouting.soundAllowed(outcome: .withheld, suppressed: false))
        XCTAssertTrue(NativeRouting.soundAllowed(outcome: .displayed, suppressed: true))
        XCTAssertFalse(NativeRouting.soundAllowed(outcome: .displayed, suppressed: false))
    }

    // MARK: - Content mapping

    func testBodyIsFlattenedPlainTextNeverRawMarkdown() {
        let content = NativeContent.make(
            from: make("构建报告", body: "## 摘要\n\n- API：✅\n- Web：✅\n\n```\nlog dump\n```"),
            soundAllowed: true
        )
        XCTAssertFalse(content.body.contains("#"), "heading markers must not leak")
        XCTAssertFalse(content.body.contains("```"), "code fences must not leak")
        XCTAssertFalse(content.body.contains("- "), "list markers must not leak")
        XCTAssertTrue(content.body.contains("API"), "the prose survives")
        XCTAssertFalse(content.body.contains("log dump"), "code blocks are dropped")
    }

    func testBodyIsCapped() {
        let long = String(repeating: "x", count: 500)
        let content = NativeContent.make(from: make("t", body: long), soundAllowed: true)
        XCTAssertLessThanOrEqual(content.body.count, NativeContent.maxBodyLength)
        XCTAssertTrue(content.body.hasSuffix("…"), "truncation is marked, not silent")
    }

    func testIdentifierIsTheMessageIDSoGroupsUpdateInPlace() {
        let message = make("t", group: "ci")
        let content = NativeContent.make(from: message, soundAllowed: true)
        XCTAssertEqual(content.identifier, message.id.uuidString)
        XCTAssertEqual(content.threadIdentifier, "ci")
    }

    func testUngroupedMessagesShareOneThread() {
        let content = NativeContent.make(from: make("t"), soundAllowed: true)
        XCTAssertEqual(content.threadIdentifier, "default")
    }

    func testSubtitleCarriesTagsAndIsAbsentWithoutThem() {
        XCTAssertNil(NativeContent.make(from: make("t"), soundAllowed: true).subtitle)
        XCTAssertEqual(
            NativeContent.make(from: make("t", tags: ["ci", "prod"]), soundAllowed: true).subtitle,
            "ci · prod"
        )
    }

    func testUrgencyMapsToInterruptionLevel() {
        XCTAssertEqual(NativeContent.make(from: make("t", urgency: .low), soundAllowed: true).level, .passive)
        XCTAssertEqual(NativeContent.make(from: make("t", urgency: .normal), soundAllowed: true).level, .active)
        // `.timeSensitive`, not `.critical`: the latter needs Apple's
        // critical-alerts entitlement, which this project does not have.
        XCTAssertEqual(NativeContent.make(from: make("t", urgency: .critical), soundAllowed: true).level, .timeSensitive)
    }

    func testLowUrgencyIsSilentAndSoundAllowedGatesTheRest() {
        XCTAssertFalse(NativeContent.make(from: make("t", urgency: .low), soundAllowed: true).playsSound)
        XCTAssertFalse(NativeContent.make(from: make("t", urgency: .critical), soundAllowed: false).playsSound)
        XCTAssertTrue(NativeContent.make(from: make("t", urgency: .critical), soundAllowed: true).playsSound)
    }

    // MARK: - Ingress wiring

    /// A recording stand-in for the real notifier: the singleton is reachable
    /// from every test process, so the funnel takes the notifier as a
    /// parameter and the tests hand it this.
    private final class SpyNotifier: NativeDelivering {
        var calls: [(CardPayload, PushOutcome, Bool)] = []

        func mirror(_ notification: CardPayload, outcome: PushOutcome, suppressed: Bool) {
            calls.append((notification, outcome, suppressed))
        }
    }

    func testDeliverMirrorsWithTheOutcomeItGot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeIngress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        let manager = NotificationManager()
        let runner = ScriptRunner(store: ScriptStore(directory: dir), target: manager)
        let spy = SpyNotifier()
        let message = make("plain")

        let outcome = NotificationIngress.deliver(
            message, to: manager, runner: runner, notifier: spy
        )

        XCTAssertEqual(outcome, .displayed)
        XCTAssertEqual(spy.calls.count, 1, "the funnel mirrors exactly once per message")
        XCTAssertEqual(spy.calls.first?.1, .displayed)
        XCTAssertEqual(spy.calls.first?.0.id, message.id)
        XCTAssertFalse(spy.calls.first?.2 ?? true, "a normal push is not suppressed")
    }
}
