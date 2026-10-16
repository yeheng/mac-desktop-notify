import XCTest
@testable import MacDesktopNotify

/// The attention presets: `apply` writes the values, `matching` derives the
/// preset back from them. Every preset must round-trip — a preset that does
/// not match its own values shows as "custom" the instant it is picked.
@MainActor
final class AttentionPresetTests: SettingsIsolatedTestCase {

    /// `apply` mutates the shared singleton in memory; leave it at factory
    /// defaults so later suites on the same runner are unaffected.
    override func tearDown() async throws {
        AppSettings.shared.resetForTests()
        try await super.tearDown()
    }

    func testEveryPresetRoundTripsThroughMatching() {
        for preset in AttentionPreset.allCases {
            AppSettings.shared.resetForTests()
            preset.apply(to: .shared)
            XCTAssertEqual(AttentionPreset.matching(.shared), preset,
                           "\(preset) must recognise its own values")
        }
    }

    /// A hand-tuned combination is none of the presets and must say so.
    func testCustomCombinationMatchesNothing() {
        AppSettings.shared.resetForTests()
        AppSettings.shared.messageDwellSeconds = 7
        AppSettings.shared.ageOutCriticals = true
        XCTAssertNil(AttentionPreset.matching(.shared))
    }
}
