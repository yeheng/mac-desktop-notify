import SwiftUI

enum CompactIslandSide {
    case leading
    case trailing
}

extension UrgencyLevel {
    var color: Color {
        switch self {
        case .low: .secondary
        case .normal: .blue
        case .critical: .red
        }
    }

    var symbolName: String {
        switch self {
        case .low: "circle.fill"
        case .normal: "sparkles"
        case .critical: "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .low: "低紧急度"
        case .normal: "普通紧急度"
        case .critical: "紧急"
        }
    }
}

/// Circular icon button on the dark panel: the fill lightens on hover and the
/// glyph sinks while pressed. `.plain` alone gives no feedback at all, which
/// makes the header buttons feel dead.
///
/// 28×28: macOS's hard floor is 20×20, but comfort starts higher, and these
/// buttons sit above a scroll view where a mis-click costs a scroll, not a tap.
private struct PanelIconButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(hovering ? 0.18 : 0.08), in: Circle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

/// Capsule action button: primary is solid white, secondary a translucent
/// fill; both respond to hover and press.
private struct ActionCapsuleStyle: ButtonStyle {
    let primary: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? Color.black : Color.white)
            .background(fill(pressed: configuration.isPressed), in: Capsule())
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private func fill(pressed: Bool) -> Color {
        if primary {
            return .white.opacity(pressed ? 0.6 : (hovering ? 0.82 : 1))
        }
        return .white.opacity(pressed ? 0.08 : (hovering ? 0.22 : 0.12))
    }
}

/// Text opacities on the black panel, chosen against WCAG AA (4.5:1 for body,
/// 3:1 for large text). The old 0.35/0.42 values measured ~3.0:1/4.0:1.
private enum PanelTextOpacity {
    static let timestamp: Double = 0.62
    static let pending: Double = 0.62
    static let subtle: Double = 0.66
}

/// One-line text clipped to `maxWidth`; while `active` (pointer near the
/// island), any overflow scrolls back and forth so a long title stays readable
/// without widening the pill. The width cap is also what keeps the pill's
/// reported width - and thus the activation frame - stable across titles.
private struct MarqueeText: View {
    let text: String
    let active: Bool
    var maxWidth: CGFloat = 220

    @State private var textWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - maxWidth) }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { textWidth = $0 }
            .offset(x: -scrollOffset)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .clipped()
            .onChange(of: active) { _, isActive in
                if isActive, overflow > 0 {
                    withAnimation(.linear(duration: Double(overflow) / 30).repeatForever(autoreverses: true)) {
                        scrollOffset = overflow
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { scrollOffset = 0 }
                }
            }
            .onChange(of: text) { _, _ in scrollOffset = 0 }
    }
}

/// The right-click menu shared by the compact pill and the expanded panel, so
/// the high-frequency management actions no longer require a round trip to
/// the menu bar icon. Destructive/global actions post notifications that the
/// app delegate routes through the same paths as its own menu items - one
/// confirmation dialog, one settings window.
struct IslandContextMenu: ViewModifier {
    /// Which presentation the menu is attached to; decides the first item.
    let expanded: Bool

    func body(content: Content) -> some View {
        content.contextMenu {
            let manager = NotificationManager.shared
            if expanded {
                Button("收起面板") { manager.dismissPanel() }
            } else {
                Button("打开面板") { manager.togglePanel() }
                    .disabled(!manager.hasContent)
            }
            Divider()
            // The full backlog in a real window: the panel's history section
            // is a glance, this is the browse-and-manage surface.
            Button("历史信息…") {
                NotificationCenter.default.post(name: .openHistoryWindow, object: nil)
            }
            .disabled(manager.history.isEmpty)
            Button(manager.isSilenced ? "取消静默" : "静默 1 小时") {
                if manager.isSilenced {
                    manager.resumeFromSilence()
                } else {
                    manager.silence(until: Date().addingTimeInterval(3600))
                }
            }
            Button("清除全部消息…") {
                NotificationCenter.default.post(name: .requestClearAll, object: nil)
            }
            .disabled(!manager.hasContent)
            Divider()
            Button("设置…") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
        }
    }
}

struct CompactIslandView: View {
    let side: CompactIslandSide
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        Group {
            switch side {
            case .leading:
                HStack(spacing: 5) {
                    // Clean mode is text-only (see README's layout table); the
                    // urgency icon belongs to normal and detailed.
                    if settings.showUrgency, settings.layoutMode != .clean {
                        Image(systemName: manager.displayUrgency?.symbolName ?? "sparkles")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(manager.displayUrgency?.color ?? .blue)
                            .accessibilityHidden(true)
                    }
                    if manager.compactShowsMessageTitle, let title = manager.current?.title {
                        MarqueeText(text: title, active: manager.pointerNearIsland)
                            .contentTransition(.opacity)
                    } else {
                        Text(manager.compactStatus)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
            case .trailing:
                // The leading side already announces "N 条未读" when nothing is
                // live, so the count only belongs here while a live message owns
                // the leading text - and it excludes that message itself.
                if settings.showHistoryCount, let current = manager.current {
                    let backlog = manager.unreadCount - (manager.isRead(current) ? 0 : 1)
                    if backlog > 0 {
                        Text("\(backlog) 条未读")
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(manager.pointerNearIsland ? 1 : 0.92))
        // Pre-expansion cue: the pill wakes up (slightly brighter, slightly
        // larger) the moment the pointer enters the activation zone, so the
        // hover-delayed panel never appears out of nowhere. `scaleEffect` is a
        // render transform - it does not feed back into `setCompactContentWidth`.
        .scaleEffect(manager.pointerNearIsland ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: manager.pointerNearIsland)
        .padding(.horizontal, max(4, 8 + settings.notchWidthOffset / 4))
        .padding(.vertical, max(2, 4 + settings.notchHeightOffset / 4))
        .fixedSize()
        // Status and count changes shift the pill's width; animate so it glides
        // instead of snapping.
        .animation(.easeInOut(duration: 0.15), value: manager.compactStatus)
        .animation(.easeInOut(duration: 0.15), value: manager.unreadCount)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
            manager.setCompactContentWidth(width, for: side)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(manager.current.map { "通知：\($0.title)" } ?? "通知中心")
        .modifier(IslandContextMenu(expanded: false))
    }
}

struct IslandExpandedView: View {
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    @State private var panelDragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // A hairline, not a Divider: Divider already draws a line, and
            // overlaying a tint on it double-draws.
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)
                .padding(.horizontal, 16)

            if showsFullList {
                MessageListView()
            } else if let current = manager.current {
                // An automatic opening gets the one actionable card, nothing
                // else: the panel asked for the screen, so it may not parade
                // the whole backlog. The full message center is reserved for
                // an explicit open (manualExpanded). The card keeps the
                // list's scroll + shrink-to-content bounds, minus the list.
                ScrollView {
                    CurrentCard(notification: current)
                        .id(current.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .padding(16)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: max(160, settings.panelHeight - 75))
            }
        }
        .offset(y: panelDragOffset)
        .opacity(1 - min(1, panelDragOffset / 120) * 0.4)
        .frame(width: max(320, settings.panelWidth))
        // The outer frame already clamps to `minHeight...maxHeight`, so the list
        // only needs an upper bound: with a fixed height here, a one-line message
        // rendered inside a 360pt-tall scroll view - every arrival looked like a
        // popup regardless of how much content it had.
        .frame(minHeight: 190, maxHeight: max(220, settings.panelHeight), alignment: .top)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(.white)
        // The deletion undo toast floats over the list's bottom edge.
        .overlay(alignment: .bottom) {
            if let notice = manager.deletionNotice {
                UndoToast(notice: notice) { manager.undoDeletion() }
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: manager.deletionNotice)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: manager.current?.id)
        .animation(reduceMotion ? nil : .default, value: panelDragOffset)
        .onHover { manager.setHovering($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("通知面板")
        .modifier(IslandContextMenu(expanded: true))
    }

    /// The two panel modes: the full message center belongs to a deliberate
    /// open (`panelOpenedManually` - displayState alone loses that bit when a
    /// message rotates into the open panel); automatic openings show the live
    /// card alone. `current == nil` in an automatic mode should not happen,
    /// but a panel with nothing live is exactly the history browser, so it
    /// falls back to the full list rather than rendering an empty shell.
    private var showsFullList: Bool {
        manager.panelOpenedManually || manager.current == nil
    }

    private var header: some View {
        HStack(spacing: 9) {
            if settings.showUrgency {
                Circle()
                    .fill(manager.displayUrgency?.color ?? .blue)
                    .frame(width: 7, height: 7)
                    .shadow(color: manager.displayUrgency?.color ?? .blue, radius: 4)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(manager.current?.title ?? "通知中心")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(manager.current == nil ? "最近消息" : manager.compactStatus)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
            }

            Spacer(minLength: 12)

            Button {
                manager.markAllRead()
            } label: {
                Image(systemName: "envelope.open")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PanelIconButtonStyle())
            .help("全部标为已读")
            .accessibilityLabel("全部标为已读")
            .disabled(manager.unreadCount == 0)

            // The confirmation must outlive this panel window: a hover-out or
            // outside-click collapse tears the window - and any inline
            // confirmationDialog inside it - down before the click lands.
            // Routing through the app delegate's modal NSAlert (same as the
            // right-click menu below) keeps one confirmation contract and one
            // window that no pointer state can destroy.
            Button {
                NotificationCenter.default.post(name: .requestClearAll, object: nil)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PanelIconButtonStyle())
            .help("清空全部消息")
            .accessibilityLabel("清空全部消息")
            .disabled(!manager.hasContent)

            Button {
                manager.dismissPanel()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PanelIconButtonStyle())
            .help("收起面板")
            .accessibilityLabel("收起面板")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        // Swipe-down collapses the panel but keeps the message - the gentle
        // counterpart to the card's swipe-up, which discards it. Header-only,
        // for the same reason the card's gesture is header-only: a panel-wide
        // drag would fight the message list's scroll and text selection.
        .contentShape(Rectangle())
        .gesture(collapseDrag)
    }

    private var collapseDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                panelDragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > 40 {
                    IslandHaptics.actionConfirmed()
                    manager.dismissPanel()
                }
                panelDragOffset = 0
            }
    }
}

/// Small label separating the list's three zones (正在显示 / 待显示 / 历史).
/// Section-wide operations （全部丢弃 / 清空 / 筛选 chips) live in the
/// trailing slot: neither in the panel header nor repeated on every row.
private struct SectionHeader<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
            if let detail {
                Text(detail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail, trailing: { EmptyView() })
    }
}

/// The small text button a section header carries （全部丢弃 / 清空）.
private struct SectionActionButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

/// One filter chip in the history section header (P2). Single-select.
private struct FilterChip: View {
    let title: String
    let isOn: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(isOn ? 0.95 : 0.55))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.white.opacity(isOn ? 0.22 : 0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// History flattened into display entries: messages sharing a `group` collapse
/// into one row fronted by the newest, singles stay as they are. Grouping
/// happens at render time only - persistence and unread state stay per message.
private enum HistoryEntry: Identifiable {
    case single(NotchNotification)
    /// Newest first; only ever built for groups with two or more entries.
    case grouped(key: String, items: [NotchNotification])

    var id: String {
        switch self {
        case .single(let notification): notification.id.uuidString
        case .grouped(let key, _): "grouped-\(key)"
        }
    }
}

/// Trackpad two-finger pans arrive as `.scrollWheel` events, never as drag
/// gestures, so SwiftUI's DragGesture is blind to them. This view installs a
/// local monitor *while the row is hovered* (`armed`) and converts
/// horizontally-dominant pans into swipe callbacks; vertical scrolls and
/// momentum phases pass through to the list untouched. One monitor per
/// hovered row, so at most one exists at a time.
///
/// `hitTest` returns nil: the view is click-transparent and events arrive
/// through the monitor, which filters by the view's frame in its window.
private struct HorizontalSwipeCatcher: NSViewRepresentable {
    var armed: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.armed = armed
    }

    final class CatcherView: NSView {
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: (CGFloat) -> Void = { _ in }
        var armed = false {
            didSet { armed ? install() : remove() }
        }

        // Installed/removed on the main thread only (SwiftUI updates, AppKit
        // window hooks, and event delivery are all main), but `deinit` is
        // nonisolated — hence unsafe opt-out. NSEvent.removeMonitor is
        // thread-safe in practice, and the closure only ever holds `weak self`.
        private nonisolated(unsafe) var monitor: Any?
        private var swipeActive = false
        private var decidedVertical = false
        private var accX: CGFloat = 0
        private var accY: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The panel window is recreated per presentation; when this row
            // leaves its window the monitor must not outlive it.
            if window == nil { remove() }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        private func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            swipeActive = false
        }

        /// Returns true when the event was consumed by the swipe.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window == window else { return false }
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
            // Mouse wheels and inertia scrolls are not swipes.
            guard event.hasPreciseScrollingDeltas, event.momentumPhase == [] else { return false }

            // Finger direction, not content direction: with natural scrolling
            // content follows the fingers so the raw delta already matches;
            // classic scrolling reports the content's movement instead.
            let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            let dy = event.scrollingDeltaY

            switch event.phase {
            case .began:
                swipeActive = false
                decidedVertical = false
                accX = 0
                accY = 0
                return false
            case .changed:
                if decidedVertical { return false }
                accX += dx
                accY += dy
                if !swipeActive {
                    // Wait for a decisive delta before claiming the gesture,
                    // so a mostly-vertical scroll that grazes the row still
                    // scrolls the list.
                    guard abs(accX) + abs(accY) > 3 else { return false }
                    if abs(accX) > abs(accY) {
                        swipeActive = true
                    } else {
                        decidedVertical = true
                        return false
                    }
                }
                onChanged(accX)
                return true
            case .ended, .cancelled:
                guard swipeActive else { return false }
                swipeActive = false
                onEnded(accX)
                accX = 0
                accY = 0
                return true
            default:
                return false
            }
        }
    }
}

/// Adds the horizontal swipe actions (left = delete, right = toggle read) to
/// a history row: the content slides with the fingers, revealing the action
/// layer underneath, and past the threshold the action fires with a haptic
/// tick. Deleting drops straight into the manager's undo journal.
private struct RowSwipe<Content: View>: View {
    /// Drives the right-swipe icon: unread rows offer 已读, read rows 未读.
    let isUnread: Bool
    /// The catcher only listens while the row is hovered (see it above).
    let armed: Bool
    let onDelete: () -> Void
    let onToggleRead: () -> Void
    @ViewBuilder let content: Content

    // Not static: generic types cannot hold stored statics, and the value
    // never varies per row anyway.
    private let threshold: CGFloat = 60
    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack {
            revealedLayer
            content.offset(x: offset)
        }
        .background(HorizontalSwipeCatcher(armed: armed, onChanged: { offset = $0 }, onEnded: finish))
        .clipped()
    }

    private var revealedLayer: some View {
        ZStack {
            if offset != 0 {
                (offset > 0 ? Color.blue : Color.red)
                    .opacity(min(1, abs(offset) / threshold) * 0.45)
                HStack {
                    if offset > 0 {
                        Image(systemName: isUnread ? "envelope.open" : "envelope.badge")
                        Spacer()
                    } else {
                        Spacer()
                        Image(systemName: "trash")
                    }
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func finish(_ translation: CGFloat) {
        if translation < -threshold {
            IslandHaptics.actionConfirmed()
            // The row vanishes via the list's own removal animation; the undo
            // toast is the feedback, so no slide-out choreography here.
            offset = 0
            onDelete()
        } else {
            if translation > threshold {
                IslandHaptics.actionConfirmed()
                onToggleRead()
            }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { offset = 0 }
        }
    }
}

/// The 4-second take-back after a delete: what was removed, plus the button
/// that puts it back. The journal lives in the manager; the toast is pure
/// reflection, so the panel collapsing mid-window costs nothing.
private struct UndoToast: View {
    let notice: NotificationManager.DeletionNotice
    let undo: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(notice.subject.map { "已删除 \($0)" } ?? "已删除 \(notice.count) 条消息")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Button(action: undo) {
                Text("撤销")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(hovering ? 1 : 0.75))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("撤销删除")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.white.opacity(0.16), in: Capsule())
        .accessibilityElement(children: .contain)
    }
}

/// The history section's filter chips (P2). Single-select.
private enum HistoryFilter: String, CaseIterable {
    case all, unread, critical

    var title: String {
        switch self {
        case .all: "全部"
        case .unread: "未读"
        case .critical: "紧急"
        }
    }
}

/// Single scrolling list in three labeled sections: the live message on top,
/// queued (not yet shown) messages dimmed below it, and tappable past
/// messages at the bottom.
private struct MessageListView: View {
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }

    // Accordion (one open body at a time), group expansion, and the keyboard
    // selection live on the manager: the notch window is recreated per
    // presentation, and view-local @State died with it - reopening the panel
    // used to reset all three. These forwards keep the body's reads and
    // writes spelled the same.
    private var expandedHistoryID: UUID? {
        get { manager.expandedHistoryID }
        nonmutating set { manager.expandedHistoryID = newValue }
    }
    private var expandedGroupKeys: Set<String> {
        get { manager.expandedGroupKeys }
        nonmutating set { manager.expandedGroupKeys = newValue }
    }
    /// The current card is deliberately not selectable (Q5) - it keeps its
    /// own ⌘1–⌘3 channel.
    private var selectedRowID: String? {
        get { manager.selectedRowID }
        nonmutating set { manager.selectedRowID = newValue }
    }
    /// Filter chips for the history section. Not persisted (Q4): a forgotten
    /// filter hiding unread messages is worse than re-tapping a chip, so it
    /// deliberately resets to 「全部」 on every opening.
    @State private var historyFilter: HistoryFilter = .all

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let current = manager.current {
                        SectionHeader(title: "正在显示")
                        CurrentCard(notification: current)
                            .id(current.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }

                    if manager.pendingCount > 0 {
                        SectionHeader(title: "待显示", detail: "\(manager.pendingCount) 条") {
                            SectionActionButton(title: "全部丢弃") {
                                manager.discardPending()
                            }
                        }
                        .help("待显示消息移出队列、不再弹出，保留在历史中")

                        if manager.pendingCount > NotificationManager.shownPendingCap {
                            Text("还有 \(manager.pendingCount - NotificationManager.shownPendingCap) 条未展示")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.horizontal, 4)
                        }

                        ForEach(manager.queue.prefix(NotificationManager.shownPendingCap)) { notification in
                            PendingRow(notification: notification)
                        }
                    }

                    if !historyEntries.isEmpty {
                        SectionHeader(
                            title: "历史",
                            detail: unreadHistoryCount > 0 ? "未读 \(unreadHistoryCount)" : nil
                        ) {
                            HStack(spacing: 6) {
                                ForEach(HistoryFilter.allCases, id: \.self) { filter in
                                    FilterChip(title: filter.title, isOn: historyFilter == filter) {
                                        withAnimation(.easeInOut(duration: 0.15)) { historyFilter = filter }
                                    }
                                }
                                SectionActionButton(title: "清空") {
                                    NotificationCenter.default.post(name: .requestClearHistory, object: nil)
                                }
                            }
                        }

                        if filteredHistoryEntries.isEmpty {
                            Text("没有匹配的\(historyFilter.title)消息")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.horizontal, 4)
                        }

                        ForEach(filteredHistoryEntries) { entry in
                            switch entry {
                            case .single(let notification):
                                HistoryRow(
                                    notification: notification,
                                    isExpanded: expandedHistoryID == notification.id,
                                    isUnread: !manager.isRead(notification),
                                    isSelected: selectedRowID == notification.id.uuidString
                                ) {
                                    toggleExpanded(notification.id)
                                }
                                .id(entry.id)
                            case .grouped(let key, let items):
                                HistoryGroupRow(
                                    groupKey: key,
                                    items: items,
                                    isExpanded: expandedGroupKeys.contains(key),
                                    expandedItemID: expandedHistoryID,
                                    isSelected: selectedRowID == entry.id,
                                    selectedRowID: selectedRowID,
                                    toggleGroup: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            if expandedGroupKeys.contains(key) {
                                                expandedGroupKeys.remove(key)
                                            } else {
                                                expandedGroupKeys.insert(key)
                                            }
                                        }
                                    },
                                    toggleItem: toggleExpanded
                                )
                                .id(entry.id)
                            }
                        }
                    }
                }
                .padding(16)
                // Animate queue/history churn so pushes slide in instead of popping.
                .animation(.easeInOut(duration: 0.2), value: manager.queue)
                .animation(.easeInOut(duration: 0.2), value: manager.pastHistory)
            }
            .scrollIndicators(.hidden)
            // Upper bound only, so the panel shrinks to its content (see the outer
            // frame's note). The header above costs ~75pt, which is the only fixed
            // tax on the panel's height.
            .frame(maxHeight: max(160, settings.panelHeight - 75))
            .onAppear(perform: expandFirstHistoryEntry)
            .onReceive(NotificationCenter.default.publisher(for: .islandListKey)) { note in
                guard let key = note.userInfo?["key"] as? String else { return }
                handleListKey(key)
            }
            .onChange(of: selectedRowID) { _, id in
                // Keep the keyboard-selected row visible while arrowing
                // through a long list.
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    /// The pre-redesign default state, now opt-in (设置 → 通用 →
    /// 「打开面板时展开最新一条历史」, off by default): when enabled, the
    /// newest history entry opens with its body already rendered. Only applied
    /// when no expansion survives from the previous opening - the accordion
    /// lives on the manager now, so an open row the user picked themselves
    /// must not be stomped by the default.
    private func expandFirstHistoryEntry() {
        guard settings.autoExpandLatestHistoryOnOpen else { return }
        guard expandedHistoryID == nil, expandedGroupKeys.isEmpty else { return }
        guard let first = historyEntries.first else { return }
        switch first {
        case .single(let notification):
            expandedHistoryID = notification.id
        case .grouped(let key, let items):
            // Both levels open when the newest message lives inside a group:
            // the cluster's rows, and the newest row's body underneath them.
            expandedGroupKeys.insert(key)
            if let id = items.first?.id { expandedHistoryID = id }
        }
    }

    /// Accordion toggle: tapping the open row folds it; tapping any other row
    /// opens it and folds the previous one in the same animation.
    private func toggleExpanded(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            expandedHistoryID = expandedHistoryID == id ? nil : id
        }
    }

    /// Unread messages inside the history section only — the header's 「未读 N」
    /// must not count the live or queued messages the other sections own.
    private var unreadHistoryCount: Int {
        manager.pastHistory.reduce(0) { $0 + (manager.isRead($1) ? 0 : 1) }
    }

    /// History entries after the filter chips. A group survives a filter if
    /// any member matches; its rows still render whole — the group is the
    /// unit the user reasons about.
    private var filteredHistoryEntries: [HistoryEntry] {
        switch historyFilter {
        case .all:
            return historyEntries
        case .unread:
            return historyEntries.filter { entry in
                switch entry {
                case .single(let notification): return !manager.isRead(notification)
                case .grouped(_, let items): return items.contains { !manager.isRead($0) }
                }
            }
        case .critical:
            return historyEntries.filter { entry in
                switch entry {
                case .single(let notification): return notification.urgency == .critical
                case .grouped(_, let items): return items.contains { $0.urgency == .critical }
                }
            }
        }
    }

    // MARK: - Keyboard navigation (P2)

    /// Rows the keyboard can land on, top to bottom: every visible history
    /// entry, with an expanded group's members inserted right after the group
    /// row. The current card and the queue stay out of it (Q5).
    private var selectableIDs: [String] {
        var ids: [String] = []
        for entry in filteredHistoryEntries {
            ids.append(entry.id)
            if case .grouped(let key, let items) = entry, expandedGroupKeys.contains(key) {
                ids.append(contentsOf: items.map { $0.id.uuidString })
            }
        }
        return ids
    }

    private func handleListKey(_ key: String) {
        let ids = selectableIDs
        guard !ids.isEmpty else { return }
        switch key {
        case "up":
            // Nothing selected yet: ↑ lands on the bottom row, ↓ on the top —
            // the direction the user pressed is the direction they think in.
            selectRow(at: (selectedRowID.flatMap { ids.firstIndex(of: $0) } ?? ids.count) - 1, in: ids)
        case "down":
            selectRow(at: (selectedRowID.flatMap { ids.firstIndex(of: $0) } ?? -1) + 1, in: ids)
        case "return":
            if let id = selectedRowID { toggleRow(id) }
        case "delete":
            guard let id = selectedRowID, let index = ids.firstIndex(of: id) else { return }
            deleteRow(id)
            // Keep the selection on the neighbor that slid into the deleted
            // row's slot, so repeated ⌫ walks down the list.
            let remaining = selectableIDs
            selectedRowID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        case "m":
            if let id = selectedRowID { toggleReadRow(id) }
        default:
            break
        }
    }

    private func selectRow(at index: Int, in ids: [String]) {
        selectedRowID = ids[min(max(index, 0), ids.count - 1)]
    }

    private func toggleRow(_ id: String) {
        if let key = groupKey(ofRowID: id) {
            withAnimation(.easeInOut(duration: 0.15)) {
                if expandedGroupKeys.contains(key) {
                    expandedGroupKeys.remove(key)
                } else {
                    expandedGroupKeys.insert(key)
                }
            }
        } else if let uuid = UUID(uuidString: id) {
            toggleExpanded(uuid)
        }
    }

    private func deleteRow(_ id: String) {
        if let key = groupKey(ofRowID: id) {
            manager.removeGroupWithUndo(key)
        } else if let uuid = UUID(uuidString: id) {
            manager.removeHistory(id: uuid)
        }
    }

    private func toggleReadRow(_ id: String) {
        if let key = groupKey(ofRowID: id) {
            let hasUnread = manager.pastHistory.contains { $0.groupingKey == key && !manager.isRead($0) }
            manager.setGroupRead(key, read: hasUnread)
        } else if let uuid = UUID(uuidString: id),
                  let notification = manager.pastHistory.first(where: { $0.id == uuid }) {
            manager.setRead(uuid, read: !manager.isRead(notification))
        }
    }

    /// Row ids double as ForEach identities: bare UUID strings for messages,
    /// "grouped-<key>" for clusters. This peels the prefix back off.
    private func groupKey(ofRowID id: String) -> String? {
        id.hasPrefix("grouped-") ? String(id.dropFirst("grouped-".count)) : nil
    }

    /// Newest-first history with same-group runs collapsed. A group only
    /// aggregates when it holds at least two entries - a lone message with a
    /// group key is not a cluster, it is a message.
    private var historyEntries: [HistoryEntry] {
        let ordered = Array(manager.pastHistory.reversed())
        var groupCounts: [String: Int] = [:]
        for notification in ordered {
            if let key = notification.groupingKey {
                groupCounts[key, default: 0] += 1
            }
        }
        var emitted: Set<String> = []
        var entries: [HistoryEntry] = []
        for notification in ordered {
            guard let key = notification.groupingKey, (groupCounts[key] ?? 0) > 1 else {
                entries.append(.single(notification))
                continue
            }
            guard emitted.insert(key).inserted else { continue }
            entries.append(.grouped(key: key, items: ordered.filter { $0.groupingKey == key }))
        }
        return entries
    }
}

/// A collapsed cluster of same-group history: the newest message fronts for
/// the rest, with the count and any unread state rolled up. Expanding reveals
/// the individual rows, which behave exactly like ungrouped history.
private struct HistoryGroupRow: View {
    let groupKey: String
    let items: [NotchNotification]
    let isExpanded: Bool
    /// The accordion's one open body, when it lives inside this group.
    let expandedItemID: UUID?
    /// Keyboard selection (P2) reaches both the group row and its members.
    var isSelected: Bool = false
    var selectedRowID: String? = nil
    let toggleGroup: () -> Void
    let toggleItem: (UUID) -> Void
    private var manager: NotificationManager { .shared }
    @State private var hovering = false

    private var latest: NotchNotification { items[0] }
    private var unreadCount: Int { items.reduce(0) { $0 + (manager.isRead($1) ? 0 : 1) } }
    /// Keyboard selection and hover share one highlight language.
    private var highlighted: Bool { hovering || isSelected }

    var body: some View {
        RowSwipe(
            isUnread: unreadCount > 0,
            armed: hovering,
            onDelete: { manager.removeGroupWithUndo(groupKey) },
            onToggleRead: { manager.setGroupRead(groupKey, read: unreadCount > 0) }
        ) {
            content
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: latest.urgency.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(latest.urgency.color)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(latest.urgency.accessibilityLabel)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(latest.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        if unreadCount > 0 {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                    }
                    Text("共 \(items.count) 条同组消息")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                }
                Spacer(minLength: 0)
                Text(latest.timestamp.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(PanelTextOpacity.timestamp))
                    .lineLimit(1)
                // Group-wide actions, persistent for the same reason as the
                // single row's: hover-revealed buttons were undiscoverable.
                HStack(spacing: 4) {
                    Button {
                        manager.setGroupRead(groupKey, read: unreadCount > 0)
                    } label: {
                        Image(systemName: unreadCount > 0 ? "envelope.open" : "envelope.badge")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(PanelIconButtonStyle())
                    .help(unreadCount > 0 ? "整组标为已读" : "整组标为未读")
                    .accessibilityHidden(true)

                    Button {
                        manager.removeGroupWithUndo(groupKey)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(PanelIconButtonStyle())
                    .help("删除整个分组")
                    .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleGroup)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(unreadCount > 0 ? "未读分组" : "消息分组")：\(latest.title)，共 \(items.count) 条")
            .accessibilityHint(isExpanded ? "收起分组" : "展开分组")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: unreadCount > 0 ? "整组标为已读" : "整组标为未读") {
                manager.setGroupRead(groupKey, read: unreadCount > 0)
            }
            .accessibilityAction(named: "删除整个分组") {
                manager.removeGroupWithUndo(groupKey)
            }

            if isExpanded {
                ForEach(items) { notification in
                    HistoryRow(
                        notification: notification,
                        isExpanded: expandedItemID == notification.id,
                        isUnread: !manager.isRead(notification),
                        isSelected: selectedRowID == notification.id.uuidString
                    ) {
                        toggleItem(notification.id)
                    }
                    .id(notification.id.uuidString)
                }
            }
        }
        .padding(10)
        .background(.white.opacity(highlighted ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The message currently being presented: full Markdown body, actions, swipe-up to dismiss.
private struct CurrentCard: View {
    let notification: NotchNotification
    @State private var dragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var manager: NotificationManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: notification.urgency.symbolName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(notification.urgency.color)
                    .accessibilityLabel(notification.urgency.accessibilityLabel)
                Text(notification.urgency == .critical ? "需要注意" : "新消息")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
                Spacer()
                Text(notification.timestamp, style: .time)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(PanelTextOpacity.timestamp))
            }
            // The swipe-up-to-dismiss gesture lives on this header row only.
            // On the whole card it fought the body's text selection: dragging
            // to select upwards could dismiss the message mid-gesture.
            .contentShape(Rectangle())
            .gesture(dismissDrag)
            // Combine the header only, never the whole card: a card-level
            // `.combine` folds ActionRow's buttons and the critical snooze
            // control out of VoiceOver. The header is also the only place the
            // title reaches assistive tech - the card renders just body and
            // actions - so the combined label carries it along with urgency.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("当前消息：\(notification.title)，\(notification.urgency.accessibilityLabel)")
            // Swipe-up dismiss is a gesture, invisible to assistive tech; expose
            // it as a named action, the same escape hatch HistoryRow gives its
            // hidden delete button.
            .accessibilityAction(named: "收起当前消息") {
                manager.dismissCurrent()
            }

            NotificationBodyView(bodyMarkdown: notification.bodyMarkdown)

            if !notification.actions.isEmpty {
                ActionRow(actions: notification.actions, shortcutHints: true) { action, comment in
                    manager.performAction(action, for: notification, comment: comment)
                }
            }

            if notification.urgency == .critical {
                criticalControls
            }
        }
        .padding(12)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .offset(y: dragOffset)
        .opacity(1 - min(1, abs(dragOffset) / 80) * 0.6)
        .animation(reduceMotion ? nil : .default, value: dragOffset)
    }

    /// Critical-specific affordances: snooze (it stays, but stops hogging the
    /// screen) and, when the backlog piles up, a path to all of them.
    @ViewBuilder
    private var criticalControls: some View {
        HStack(spacing: 8) {
            Button {
                manager.snoozeCurrentCritical()
            } label: {
                Text("稍后处理")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(ActionCapsuleStyle(primary: false))
            .help("降级为普通消息，5 分钟后自动收起；消息保留在历史中")
            .accessibilityLabel("稍后处理当前消息")

            if manager.criticalBacklogCount > 3 {
                Text("还有 \(manager.criticalBacklogCount - 1) 条紧急等待")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(PanelTextOpacity.subtle))
            }
            Spacer(minLength: 0)
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                dragOffset = min(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height < -40 {
                    IslandHaptics.actionConfirmed()
                    manager.dismissCurrent()
                } else {
                    dragOffset = 0
                }
            }
    }
}

/// A message still waiting in the queue: dimmed, title only.
private struct PendingRow: View {
    let notification: NotchNotification

    var body: some View {
        HStack(spacing: 9) {
            // The urgency glyph carries more information than a generic clock;
            // the trailing "待显示" label already says it is waiting.
            Image(systemName: notification.urgency.symbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(notification.urgency.color.opacity(0.85))
                .frame(width: 16, height: 16)
                .accessibilityLabel(notification.urgency.accessibilityLabel)
            Text(notification.title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("待显示")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(PanelTextOpacity.pending))
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("等待中的消息：\(notification.title)")
    }
}

/// A past message. Tap to expand the rendered Markdown body inline.
private struct HistoryRow: View {
    let notification: NotchNotification
    let isExpanded: Bool
    let isUnread: Bool
    /// Keyboard selection (P2) shares the hover look: one highlight language,
    /// two ways to land on a row.
    var isSelected: Bool = false
    let toggle: () -> Void
    private var manager: NotificationManager { .shared }
    @State private var hovering = false
    private var highlighted: Bool { hovering || isSelected }

    var body: some View {
        RowSwipe(
            isUnread: isUnread,
            armed: hovering,
            onDelete: { manager.removeHistory(id: notification.id) },
            onToggleRead: { manager.setRead(notification.id, read: isUnread) }
        ) {
            content
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        // Read rows drop the two-line preview and collapse to one line
        // (unread rows keep it). Read-state flips have no call-site
        // `withAnimation` - the visibility pipeline can mark a row at any
        // moment - so the collapse gets its own, matching the accordion's.
        .animation(.easeInOut(duration: 0.15), value: isUnread)
        // P3 visibility-based read marking: entering the viewport starts (or,
        // before the unlock, merely tracks) this row's one-second read budget.
        .onAppear { manager.noteRowVisible(notification.id) }
        .onDisappear { manager.noteRowHidden(notification.id) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header-only tap, and no Button wrapper: a Button's label
            // swallows clicks for every control inside it, which would kill
            // the delete button embedded here and the action row below.
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: notification.urgency.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(notification.urgency.color)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(notification.urgency.accessibilityLabel)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(notification.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        if isUnread {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                    }
                    if !isExpanded, isUnread, let previewText {
                        Text(previewText)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                // Relative time everywhere: absolute clock time made the
                // list read like a log file, not a message list.
                Text(notification.timestamp.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(PanelTextOpacity.timestamp))
                    .lineLimit(1)
                // Per-row read/delete actions stay visible at all times: an
                // action that only appears on hover is an action users never
                // find, and these two are the list's highest-frequency verbs.
                HStack(spacing: 4) {
                    Button {
                        manager.setRead(notification.id, read: isUnread)
                    } label: {
                        Image(systemName: isUnread ? "envelope.open" : "envelope.badge")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(PanelIconButtonStyle())
                    .help(isUnread ? "标为已读" : "标为未读")
                    // The header below folds its children into one element,
                    // which would swallow these buttons; they stay reachable
                    // through the header's named accessibility actions.
                    .accessibilityHidden(true)

                    Button {
                        manager.removeHistory(id: notification.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(PanelIconButtonStyle())
                    .help("从历史中删除这条消息")
                    .accessibilityHidden(true)
                }
                // Rows are tappable; without an affordance that was
                // undiscoverable. The chevron sits at the row's trailing edge,
                // rotating to signal the open state.
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(isUnread ? "未读消息" : "消息")：\(notification.title)")
            .accessibilityHint(isExpanded ? "收起正文" : "展开正文")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: isUnread ? "标为已读" : "标为未读") {
                manager.setRead(notification.id, read: isUnread)
            }
            .accessibilityAction(named: "删除这条消息") {
                manager.removeHistory(id: notification.id)
            }

            if isExpanded {
                NotificationBodyView(bodyMarkdown: notification.bodyMarkdown)
                if !notification.actions.isEmpty {
                    ActionRow(actions: notification.actions) { action, comment in
                        manager.performAction(action, for: notification, comment: comment)
                    }
                }
            }
        }
        .padding(10)
        .background(.white.opacity(highlighted ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Collapsed preview renders inline Markdown instead of showing raw source
    /// asterisks. Fenced code blocks are skipped entirely: log dumps read as
    /// noise two lines at a time, and their ``` markers would leak into the
    /// preview as literal backticks. A message with no prose (or no body at
    /// all) shows no preview rather than a placeholder like "无正文".
    private var previewText: AttributedString? {
        guard !notification.bodyMarkdown.isEmpty else { return nil }
        // The same fence definition `parse` splits on (MarkdownRenderer.segments):
        // a block skipped here is exactly a block rendered as a code card there.
        let flat = MarkdownRenderer.segments(in: notification.bodyMarkdown)
            .compactMap { if case .prose(let lines) = $0 { return lines } else { return nil } }
            .flatMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return MarkdownCache.shared.inline(flat)
    }
}

/// Renders parsed Markdown blocks (prose + code cards) for a message body.
private struct NotificationBodyView: View {
    let bodyMarkdown: String
    private var settings: AppSettings { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let attributed):
                    Text(attributed)
                        .font(.system(size: settings.contentFontSize, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                case .code(let code):
                    Text(code)
                        .font(.system(size: settings.contentFontSize, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [MarkdownBlock] {
        MarkdownCache.shared.blocks(for: bodyMarkdown)
    }
}

/// Callback buttons for a notification. The first action renders as primary.
private struct ActionRow: View {
    let actions: [NotificationAction]
    /// Only the live message's buttons are reachable via ⌘1–⌘3 (see
    /// `AppDelegate.handleActionShortcut`), so only it advertises the shortcut.
    var shortcutHints: Bool = false
    /// The comment the user typed, when the button asked for one.
    let perform: (NotificationAction, String?) -> Void

    /// A button that asked for a comment (`&input=1`) parks here instead of
    /// firing on click: the receipt is written when the reason is submitted.
    @State private var pending: NotificationAction?
    @State private var comment = ""
    @FocusState private var commentFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    Button {
                        request(action)
                    } label: {
                        Text(action.label)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(ActionCapsuleStyle(primary: index == 0))
                    .help(helpText(for: action, at: index))
                    .accessibilityLabel("操作：\(action.label)")
                }
                Spacer(minLength: 0)
            }
            if let pending {
                commentRow(for: pending)
            }
        }
        .onChange(of: actions) { _, _ in pending = nil; comment = "" }
        .onReceive(NotificationCenter.default.publisher(for: .islandActionShortcut)) { note in
            guard shortcutHints,
                  let index = note.userInfo?["index"] as? Int,
                  actions.indices.contains(index) else { return }
            request(actions[index])
        }
    }

    private func helpText(for action: NotificationAction, at index: Int) -> String {
        let base = action.wantsComment ? "操作：\(action.label)，需要填写原因" : "操作：\(action.label)"
        return shortcutHints ? "\(base)（快捷键 ⌘\(index + 1)，指针在面板上时生效）" : base
    }

    /// One line, because a reason is a sentence - and a two-line field inside
    /// the panel would push the rest of the card off screen.
    private func commentRow(for action: NotificationAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(action.label)：填写原因（可选）")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(PanelTextOpacity.subtle))
            HStack(spacing: 6) {
                TextField("原因", text: $comment)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .focused($commentFocused)
                    .onSubmit { submit(action) }
                    .accessibilityLabel("\(action.label) 的原因")
                Button("提交") { submit(action) }
                    .buttonStyle(ActionCapsuleStyle(primary: true))
                    .accessibilityLabel("提交 \(action.label)")
                Button("取消") { pending = nil; comment = "" }
                    .buttonStyle(ActionCapsuleStyle(primary: false))
                    .accessibilityLabel("取消 \(action.label)")
            }
        }
        .transition(.opacity)
    }

    private func request(_ action: NotificationAction) {
        guard action.wantsComment else {
            perform(action, nil)
            return
        }
        pending = action
        comment = ""
        commentFocused = true
    }

    private func submit(_ action: NotificationAction) {
        perform(action, comment)
        pending = nil
        comment = ""
    }
}
