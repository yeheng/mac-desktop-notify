import SwiftUI

/// A frame-fresh snapshot of everything the DSL is allowed to read. Every
/// value is pre-formatted in Swift: the DSL never formats a number or a date,
/// and `badge.format` is the renderer's only formatting point.
///
/// Defaults make `IslandBindings()` inert (blank text, no content), which is
/// what a preview or a test renders when nothing was injected.
struct IslandBindings: Equatable, Sendable {
    var status: String = ""
    var islandText: String?
    var panelTitle: String = ""
    var panelSubtitle: String = ""
    var icon: String = "sparkles"
    var unread: Int = 0
    var progress: Double?
    var urgency: UrgencyLevel?
    var showUrgency: Bool = true
    var showHistoryCount: Bool = true
    var currentExists: Bool = false
    var isCritical: Bool = false
    var showsCurrentCard: Bool = true

    static let empty = IslandBindings()

    @MainActor
    init(
        manager: NotificationManager,
        settings: AppSettings
    ) {
        let current = manager.current
        let showsFullList = manager.displayState.openReason != .notification || current == nil
        status = manager.compactStatus
        islandText = current?.island?.text
        panelTitle = showsFullList ? "通知中心" : "当前通知"
        panelSubtitle = showsFullList ? "\(manager.unreadCount) 条未读" : manager.compactStatus
        icon = current?.island?.icon ?? manager.displayUrgency?.symbolName ?? "sparkles"
        unread = manager.unreadCount
        progress = current?.island?.progress
        urgency = manager.displayUrgency
        showUrgency = settings.showUrgency
        showHistoryCount = settings.showHistoryCount
        currentExists = current != nil
        isCritical = manager.displayUrgency == .critical
        showsCurrentCard = !showsFullList
    }

    init() {}

    // MARK: - Predicates

    func predicate(_ predicate: IslandPredicate) -> Bool {
        switch predicate {
        case .hasStatus: !status.isEmpty
        case .hasIslandText: islandText != nil
        case .hasCurrent: currentExists
        case .hasUnread: unread > 0
        case .manyUnread: unread > 1
        case .isCritical: isCritical
        case .showUrgency: showUrgency
        case .showHistoryCount: showHistoryCount
        case .showsPillBadge: showHistoryCount && unread > 1
        case .showsMiniBarBadge: showHistoryCount && unread > 0
        case .hasProgress: progress != nil
        case .showsCurrentCard: showsCurrentCard
        }
    }

    // MARK: - Values

    func string(for key: IslandBindingKey) -> String? {
        switch key {
        case .status: status
        case .islandText: islandText
        case .panelTitle: panelTitle
        case .panelSubtitle: panelSubtitle
        case .icon: icon
        case .unread, .progress, .urgency: nil
        }
    }

    func text(_ source: IslandTextSource) -> String? {
        switch source {
        case .literal(let string): string
        case .binding(let key): string(for: key)
        }
    }

    func icon(_ source: IslandIconSource) -> String? {
        switch source {
        case .literal(let string): string
        case .binding(let key): string(for: key)
        }
    }

    /// `$urgency` is the only color binding, and it honours `showUrgency` the
    /// way the builtin compact pill does (all-secondary when the user turned
    /// urgency colouring off).
    func color(_ source: IslandColorSource, tokens: ResolvedIslandTokens, scheme: ColorScheme) -> Color? {
        switch source {
        case .literal(let color): color.color
        case .adaptive(let light, let dark): (scheme == .dark ? dark : light).color
        case .token(let key): tokens.color(for: key)
        case .binding(.urgency): showUrgency ? tokens.urgencyColor(urgency) : .secondary
        case .binding: nil
        }
    }
}

extension EnvironmentValues {
    /// Injected once per presentation root; leaves re-read it every frame.
    @Entry var islandBindings: IslandBindings = .empty
}
