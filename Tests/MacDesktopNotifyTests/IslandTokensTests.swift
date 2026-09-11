import SwiftUI
import XCTest
@testable import MacDesktopNotify

/// The theme token layer: parsing, clamps, forward-compatible ignores, and the
/// guarantee that the built-in defaults are exactly the literals the shell drew
/// before themes existed (T1's acceptance is "default == today, pixel for pixel").
final class IslandTokensTests: XCTestCase {

    // MARK: - Hex parsing

    func testHexParsesSixDigits() throws {
        let color = try XCTUnwrap(IslandColor(hex: "#FF0080"))
        XCTAssertEqual(color.red, 1, accuracy: 0.0001)
        XCTAssertEqual(color.green, 0, accuracy: 0.0001)
        XCTAssertEqual(color.blue, 128.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(color.alpha, 1, accuracy: 0.0001)
    }

    func testHexParsesEightDigitsIncludingAlpha() throws {
        let color = try XCTUnwrap(IslandColor(hex: "#00000080"))
        XCTAssertEqual(color.red, 0, accuracy: 0.0001)
        XCTAssertEqual(color.alpha, 128.0 / 255, accuracy: 0.0001)
    }

    func testHexRejectsShorthandBareAndGarbage() {
        // §2.4: the `#` is mandatory, so a bare hex can never be mistaken for a
        // token name.
        XCTAssertNil(IslandColor(hex: "FF0000"))
        XCTAssertNil(IslandColor(hex: "#FFF"))
        XCTAssertNil(IslandColor(hex: "#GGGGGG"))
        XCTAssertNil(IslandColor(hex: ""))
    }

    // MARK: - Color specs

    func testSpecParsesFixedString() {
        XCTAssertEqual(IslandColorSpec.parse("#112233"), .fixed(IslandColor(hex: "#112233")!))
    }

    func testSpecResolvesAdaptivePairsPerScheme() throws {
        let spec = try XCTUnwrap(IslandColorSpec.parse(["light": "#FFFFFF", "dark": "#000000"]))
        guard case .adaptive = spec else { return XCTFail("expected adaptive") }
        XCTAssertEqual(spec.resolve(.light), IslandColor(hex: "#FFFFFF")!.color)
        XCTAssertEqual(spec.resolve(.dark), IslandColor(hex: "#000000")!.color)
        XCTAssertNotEqual(spec.resolve(.light), spec.resolve(.dark))
    }

    func testSpecRejectsIncompletePairAndWrongTypes() {
        XCTAssertNil(IslandColorSpec.parse(["light": "#FFFFFF"]))
        XCTAssertNil(IslandColorSpec.parse(["light": "#FFFFFF", "dark": "nope"]))
        XCTAssertNil(IslandColorSpec.parse(42))
        XCTAssertNil(IslandColorSpec.parse("#12345"))
    }

    // MARK: - Applying a theme

    func testBuiltinDefaultsMatchTodayLiterals() {
        let tokens = ResolvedIslandTokens.builtin
        XCTAssertEqual(tokens.panelFill, .black)
        XCTAssertEqual(tokens.panelBorder, .white.opacity(0.18))
        XCTAssertEqual(tokens.divider, .white.opacity(0.12))
        XCTAssertEqual(tokens.textPrimary, .white)
        XCTAssertEqual(tokens.textSubtle, .white.opacity(0.66))
        XCTAssertEqual(tokens.textTimestamp, .white.opacity(0.62))
        XCTAssertEqual(tokens.cardFill, .white.opacity(0.09))
        XCTAssertEqual(tokens.cardFillHover, .white.opacity(0.14))
        XCTAssertEqual(tokens.historyRowFill, .white.opacity(0.07))
        XCTAssertEqual(tokens.historyRowFillHover, .white.opacity(0.12))
        XCTAssertEqual(tokens.miniBarFill, .black.opacity(0.72))
        XCTAssertEqual(tokens.badgeFill, .white.opacity(0.24))
        XCTAssertEqual(tokens.accent, .blue)
        XCTAssertEqual(tokens.critical, .red)

        XCTAssertEqual(tokens.panelRadius, 22)
        XCTAssertEqual(tokens.cardRadius, 12)
        XCTAssertEqual(tokens.historyRowRadius, 10)
        XCTAssertEqual(tokens.paddingPanel, 16)
        XCTAssertEqual(tokens.paddingCard, 12)
        XCTAssertEqual(tokens.fontScale, 1.0)
        XCTAssertEqual(tokens.motionScale, 1.0)
        XCTAssertTrue(tokens.monoDigits)
        XCTAssertEqual(tokens.panelMaterial, .solid)
        XCTAssertEqual(tokens.fontDesign, .rounded)
    }

    func testUnknownTokenIsIgnored() {
        let tokens = ResolvedIslandTokens.builtin.applying(
            ["panelShadow": "#FFFFFF", "whatever": 3],
            colorScheme: .dark
        )
        XCTAssertEqual(tokens, .builtin)
    }

    func testMissingTokenKeepsDefault() {
        let tokens = ResolvedIslandTokens.builtin.applying(["panelRadius": 30], colorScheme: .dark)
        XCTAssertEqual(tokens.panelRadius, 30)
        XCTAssertEqual(tokens.cardRadius, ResolvedIslandTokens.builtin.cardRadius)
    }

    func testColorTokenAppliesAndAdaptiveResolves() {
        let light = ResolvedIslandTokens.builtin.applying(
            ["panelFill": ["light": "#FFFFFF", "dark": "#000000"]],
            colorScheme: .light
        )
        XCTAssertEqual(light.panelFill, IslandColor(hex: "#FFFFFF")!.color)

        let dark = ResolvedIslandTokens.builtin.applying(
            ["panelFill": ["light": "#FFFFFF", "dark": "#000000"]],
            colorScheme: .dark
        )
        XCTAssertEqual(dark.panelFill, IslandColor(hex: "#000000")!.color)
    }

    func testUnparsableColorKeepsDefault() {
        let tokens = ResolvedIslandTokens.builtin.applying(["accent": "not-a-color"], colorScheme: .dark)
        XCTAssertEqual(tokens.accent, ResolvedIslandTokens.builtin.accent)
    }

    func testNumericClamps() {
        let tokens = ResolvedIslandTokens.builtin.applying([
            "panelRadius": 999,
            "cardRadius": -5,
            "historyRowRadius": 100,
            "paddingPanel": 999,
            "paddingCard": -1,
            "fontScale": 9.9,
            "motionScale": -3,
        ], colorScheme: .dark)
        XCTAssertEqual(tokens.panelRadius, 48)
        XCTAssertEqual(tokens.cardRadius, 0)
        XCTAssertEqual(tokens.historyRowRadius, 48)
        XCTAssertEqual(tokens.paddingPanel, 64)
        XCTAssertEqual(tokens.paddingCard, 0)
        XCTAssertEqual(tokens.fontScale, 1.6)
        XCTAssertEqual(tokens.motionScale, 0)
    }

    func testNumericClampLowerBounds() {
        let tokens = ResolvedIslandTokens.builtin.applying([
            "fontScale": 0.1,
            "motionScale": 9,
        ], colorScheme: .dark)
        XCTAssertEqual(tokens.fontScale, 0.8)
        XCTAssertEqual(tokens.motionScale, 2)
    }

    func testWronglyTypedFieldsKeepDefaults() {
        let tokens = ResolvedIslandTokens.builtin.applying([
            "panelRadius": "big",
            "fontScale": true,
            "panelFill": 12,
            "fontDesign": "comic",
            "panelMaterial": "glass",
        ], colorScheme: .dark)
        XCTAssertEqual(tokens, .builtin)
    }

    func testEnumsAndBoolApply() {
        let tokens = ResolvedIslandTokens.builtin.applying([
            "fontDesign": "serif",
            "panelMaterial": "popover",
            "monoDigits": false,
        ], colorScheme: .dark)
        XCTAssertEqual(tokens.fontDesign, .serif)
        XCTAssertEqual(tokens.panelMaterial, .popover)
        XCTAssertFalse(tokens.monoDigits)
    }

    func testEveryTokenKeyRoundTrips() {
        // A full theme: one value per closed-set key. Guards against a key that
        // is declared but never wired into `applying`.
        var raw: [String: Any] = [:]
        for key in TokenKey.allCases {
            switch key {
            case .panelFill, .panelBorder, .divider, .textPrimary, .textSubtle, .textTimestamp,
                 .cardFill, .cardFillHover, .historyRowFill, .historyRowFillHover, .miniBarFill,
                 .badgeFill, .accent, .critical:
                raw[key.rawValue] = "#010203"
            case .panelRadius, .cardRadius, .historyRowRadius, .paddingPanel, .paddingCard,
                 .fontScale, .motionScale:
                raw[key.rawValue] = 1
            case .fontDesign:
                raw[key.rawValue] = "serif"
            case .panelMaterial:
                raw[key.rawValue] = "popover"
            case .monoDigits:
                raw[key.rawValue] = false
            }
        }
        let tokens = ResolvedIslandTokens.builtin.applying(raw, colorScheme: .dark)
        XCTAssertEqual(tokens.panelFill, IslandColor(hex: "#010203")!.color)
        XCTAssertEqual(tokens.accent, IslandColor(hex: "#010203")!.color)
        XCTAssertEqual(tokens.panelRadius, 1)
        XCTAssertEqual(tokens.fontScale, 1)
        XCTAssertEqual(tokens.fontDesign, .serif)
        XCTAssertEqual(tokens.panelMaterial, .popover)
        XCTAssertFalse(tokens.monoDigits)
    }

    // MARK: - Derived values

    func testUrgencyColorMapping() {
        let tokens = ResolvedIslandTokens.builtin
        XCTAssertEqual(tokens.urgencyColor(.normal), tokens.accent)
        XCTAssertEqual(tokens.urgencyColor(.critical), tokens.critical)
        XCTAssertEqual(tokens.urgencyColor(nil), tokens.accent)
        XCTAssertEqual(tokens.urgencyColor(.low), .secondary)
    }

    func testMotionScaleMultipliesDurations() {
        XCTAssertEqual(ResolvedIslandTokens.builtin.motion(0.2), 0.2, accuracy: 0.0001)
        let fast = ResolvedIslandTokens.builtin.applying(["motionScale": 2], colorScheme: .dark)
        XCTAssertEqual(fast.motion(0.2), 0.4, accuracy: 0.0001)
    }

    func testFontScaleMultipliesSizes() {
        let big = ResolvedIslandTokens.builtin.applying(["fontScale": 1.5], colorScheme: .dark)
        XCTAssertEqual(big.fontScale, 1.5)
    }
}
