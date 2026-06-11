import Cocoa
import Combine
import Foundation
import SwiftUI

struct UISettingsState: Codable, Equatable {
    var autoCloseSeconds: Double = 4
    var showMessageIcons: Bool = true
    var showTimestamps: Bool = true

    static let `default` = UISettingsState()

    enum CodingKeys: String, CodingKey {
        case autoCloseSeconds
        case showMessageIcons
        case showTimestamps
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoCloseSeconds = try values.decodeIfPresent(Double.self, forKey: .autoCloseSeconds) ?? 4
        showMessageIcons = try values.decodeIfPresent(Bool.self, forKey: .showMessageIcons) ?? true
        showTimestamps = try values.decodeIfPresent(Bool.self, forKey: .showTimestamps) ?? true
    }
}

enum DynamicIslandLayout {
    static let panelMaxWidth: CGFloat = 720
    static let panelMaxHeight: CGFloat = 340
    static let panelSpacing: CGFloat = 16
    static let panelCornerRadius: CGFloat = 32
    static let listSpacing: CGFloat = 8
    static let cardPadding: CGFloat = 10
    static let cardCornerRadius: CGFloat = 8
    static let windowShadowPadding: CGFloat = 24

    static func openedSize(for screenRect: CGRect) -> CGSize {
        guard screenRect.width > 0, screenRect.height > 0 else {
            return .init(width: panelMaxWidth, height: panelMaxHeight)
        }

        let width = min(panelMaxWidth, max(320, screenRect.width - 48))
        let height = min(panelMaxHeight, max(280, screenRect.height * 0.42))
        return .init(width: width, height: height)
    }
}

class DynamicIslandViewModel: NSObject, ObservableObject {
    private static let uiSettingsStorageKey = "MacDesktopNotify.UISettings"

    var cancellables: Set<AnyCancellable> = []
    let inset: CGFloat

    init(inset: CGFloat = -4) {
        self.inset = inset
        super.init()
        restoreUISettings()
        setupCancellables()
    }

    deinit {
        destroy()
    }

    @Published var uiSettings: UISettingsState = .default {
        didSet {
            guard uiSettings != oldValue else { return }
            persistUISettings()
        }
    }

    let animation: Animation = .interactiveSpring(
        duration: 0.5,
        extraBounce: 0.25,
        blendDuration: 0.125
    )

    var notchOpenedSize: CGSize {
        DynamicIslandLayout.openedSize(for: screenRect)
    }

    enum Status: String, Codable, Hashable, Equatable {
        case closed
        case opened
        case popping
    }

    enum OpenReason: String, Codable, Hashable, Equatable {
        case click
        case drag
        case boot
        case unknown
    }

    enum ContentType: Int, Codable, Hashable, Equatable {
        case normal
        case menu
        case settings
    }

    var notchOpenedRect: CGRect {
        .init(
            x: screenRect.origin.x + (screenRect.width - notchOpenedSize.width) / 2,
            y: screenRect.origin.y + screenRect.height - notchOpenedSize.height,
            width: notchOpenedSize.width,
            height: notchOpenedSize.height
        )
    }

    var windowFrame: CGRect {
        guard screenRect.width > 0, screenRect.height > 0 else { return .zero }

        let windowWidth = min(
            screenRect.width,
            notchOpenedSize.width + DynamicIslandLayout.windowShadowPadding * 2
        )
        let windowHeight = min(
            screenRect.height,
            notchOpenedSize.height + DynamicIslandLayout.windowShadowPadding
        )

        return CGRect(
            x: screenRect.midX - windowWidth / 2,
            y: screenRect.maxY - windowHeight,
            width: windowWidth,
            height: windowHeight
        )
    }

    var deviceNotchRect: CGRect = .zero
    var screenRect: CGRect = .zero

    /// Expanded hit-test area for click/hover detection (min 200×44pt per HIG).
    var hitTestRect: CGRect {
        let minHitWidth: CGFloat = 200
        let minHitHeight: CGFloat = 44
        let expandedWidth = max(deviceNotchRect.width + 16, minHitWidth)
        let expandedHeight = max(deviceNotchRect.height + 8, minHitHeight)
        return CGRect(
            x: deviceNotchRect.midX - expandedWidth / 2,
            y: deviceNotchRect.midY - expandedHeight / 2,
            width: expandedWidth,
            height: expandedHeight
        )
    }

    var activeHitTestRect: CGRect {
        switch status {
        case .opened:
            return notchOpenedRect.insetBy(dx: -8, dy: -8)
        case .closed, .popping:
            return hitTestRect
        }
    }

    @Published private(set) var status: Status = .closed
    @Published var openReason: OpenReason = .unknown
    @Published var contentType: ContentType = .normal
    @Published var optionKeyPressed: Bool = false
    @Published var notchVisible: Bool = true
    @Published var closeLocked: Bool = false

    var spacing: CGFloat { DynamicIslandLayout.panelSpacing }

    let hapticSender = PassthroughSubject<Void, Never>()

    func notchOpen(_ reason: OpenReason) {
        openReason = reason
        status = .opened
        contentType = .normal
    }

    func notchClose() {
        openReason = .unknown
        status = .closed
        contentType = .normal
    }

    func showSettings() {
        contentType = .settings
    }

    func showNotificationCenter() {
        contentType = .normal
    }

    func notchPop() {
        openReason = .unknown
        status = .popping
    }

    func resetUISettings() {
        uiSettings = .default
    }

    private func restoreUISettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.uiSettingsStorageKey),
              let state = try? JSONDecoder().decode(UISettingsState.self, from: data)
        else { return }

        uiSettings = state
    }

    private func persistUISettings() {
        guard let data = try? JSONEncoder().encode(uiSettings) else { return }
        UserDefaults.standard.set(data, forKey: Self.uiSettingsStorageKey)
    }
}
