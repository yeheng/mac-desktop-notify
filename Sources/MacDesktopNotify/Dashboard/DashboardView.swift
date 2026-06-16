import SwiftUI

/// 统一通知中心（Phase 2 重做）。
///
/// 从「扁平列表 + 清空/退出 footer」升级为：
/// - 搜索（标题/正文实时过滤）
/// - 类型过滤 chip（info/success/warning/error，多选）
/// - 时间分组（今天/昨天/更早）可折叠
/// - 键盘导航（↑↓ 选择、Enter 触发主操作、⌫ 删除、Esc 关闭）
/// - 空状态（无通知 / 无搜索结果）
/// - 危险操作防护（清空二次确认、退出移回菜单栏）
struct DashboardView: View {
    @Bindable var manager: NotifyManager

    let clearAll: () -> Void
    let removeNotification: (UUID) -> Void
    let triggerAction: (UUID, String) -> Void
    let close: () -> Void

    // MARK: - 视图本地状态

    @State private var searchText = ""
    @State private var enabledTypes: Set<NotifyType> = []
    @State private var collapsedSections: Set<TimeBucket> = []
    @State private var selectedID: UUID? = nil
    @State private var showClearConfirmation = false
    /// 复制反馈 toast 的文案（非 nil 时显示，自动消失）
    @State private var copyFeedback: String? = nil
    /// 待撤销的删除项（非 nil 时显示撤销 toast）
    @State private var pendingDelete: NotificationRecord? = nil
    /// 自动清除撤销 toast 的延时任务（连续删除时取消上一个，避免误清当前 toast）
    @State private var deleteUndoTask: Task<Void, Never>? = nil
    @FocusState private var isRootFocused: Bool

    // MARK: - 派生数据

    /// 应用搜索 + 类型过滤后的通知（仍按插入顺序，最新在前）
    private var filteredItems: [NotificationRecord] {
        manager.items.filter { item in
            // 类型过滤：enabledTypes 为空 = 显示全部
            if !enabledTypes.isEmpty, !enabledTypes.contains(item.type) {
                return false
            }
            // 搜索：标题或正文命中（不区分大小写）
            if !searchText.isEmpty {
                let needle = searchText.lowercased()
                let inTitle = item.title.lowercased().contains(needle)
                let inBody = item.body.lowercased().contains(needle)
                if !inTitle && !inBody { return false }
            }
            return true
        }
    }

    /// 按时间分桶后的分组
    private var groupedSections: [(bucket: TimeBucket, items: [NotificationRecord])] {
        let bucketsOrder: [TimeBucket] = [.today, .yesterday, .earlier]
        var grouped: [TimeBucket: [NotificationRecord]] = [:]

        for item in filteredItems {
            let bucket = TimeBucket(for: item.createdAt)
            grouped[bucket, default: []].append(item)
        }

        return bucketsOrder.compactMap { bucket in
            guard let items = grouped[bucket], !items.isEmpty else { return nil }
            return (bucket, items)
        }
    }

    /// 扁平化的卡片列表（用于键盘导航的线性选择）
    private var flatItems: [NotificationRecord] {
        groupedSections.flatMap { $0.items }
    }

    private var hasAnyNotifications: Bool { !manager.items.isEmpty }
    private var hasFilters: Bool { !searchText.isEmpty || !enabledTypes.isEmpty }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header

            if hasAnyNotifications {
                Divider()
                toolbar  // 搜索 + 过滤 chips
            }

            Divider()

            if !hasAnyNotifications {
                emptyState
            } else if filteredItems.isEmpty {
                noResultsState
            } else {
                notificationList
            }

            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay(alignment: .bottom) { copyFeedbackOverlay }
        .overlay(alignment: .bottom) { undoOverlay }
        .focusable()
        .focused($isRootFocused)
        .onAppear { isRootFocused = true }
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { activateSelected(); return .handled }
        .onKeyPress(.delete) { deleteSelected(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .confirmationDialog(
            "\(L10n.clearAll)？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.clear, role: .destructive) {
                clearAll()
            }
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(L10n.clearConfirmation(count: manager.items.count))
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s + 2) {
            HStack(spacing: AppTheme.Spacing.s + 2) {
                Image(systemName: "bell.badge.fill")
                    .font(AppTheme.Fonts.iconLarge)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: AppTheme.Layout.iconSize, height: AppTheme.Layout.iconSize)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.appName)
                        .font(AppTheme.Fonts.panelTitle)
                        .foregroundStyle(AppTheme.Colors.primaryText)

                    HStack(spacing: AppTheme.Spacing.xs + 2) {
                        Image(systemName: manager.serviceState.statusImageName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(manager.serviceState.isRunning ? AppTheme.Colors.success : AppTheme.Colors.warning)
                            .accessibilityHidden(true)
                        Text(manager.serviceState.statusText)
                            .font(AppTheme.Fonts.endpointValue)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                            .lineLimit(1)
                            .accessibilityLabel(manager.serviceState.isRunning ? "服务运行中" : "服务未运行")
                    }
                }

                Spacer()

                HStack(spacing: AppTheme.Spacing.s) {
                    CountBadge(count: manager.items.count)
                    CloseButton(action: close, size: AppTheme.Layout.closeButtonSizeLarge)
                }
            }
        }
        .padding(AppTheme.Spacing.l + 2)
    }

    // MARK: - Toolbar（搜索 + 过滤 chips）

    private var toolbar: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            SearchField(text: $searchText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.xs + 2) {
                    AllFilterChip(isSelected: enabledTypes.isEmpty) {
                        enabledTypes.removeAll()
                    }
                    ForEach(NotifyType.allCases, id: \.self) { type in
                        FilterChip(
                            type: type,
                            isSelected: enabledTypes.contains(type)
                        ) {
                            toggleTypeFilter(type)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.l + 2)
        .padding(.top, AppTheme.Spacing.s)
        .padding(.bottom, AppTheme.Spacing.s)
    }

    private func toggleTypeFilter(_ type: NotifyType) {
        withAnimation(AppTheme.Motion.ease) {
            if enabledTypes.contains(type) {
                enabledTypes.remove(type)
            } else {
                enabledTypes.insert(type)
            }
            selectedID = nil
        }
    }

    // MARK: - 通知列表（分组 + 折叠）

    private var notificationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                    ForEach(groupedSections, id: \.bucket) { section in
                        sectionView(bucket: section.bucket, items: section.items)
                    }
                }
                .padding(AppTheme.Spacing.m)
            }
            .onChange(of: selectedID) { _, newID in
                if let newID { proxy.scrollTo(newID, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func sectionView(bucket: TimeBucket, items: [NotificationRecord]) -> some View {
        let isCollapsed = collapsedSections.contains(bucket)
        SectionHeader(
            title: bucket.title,
            count: items.count,
            isCollapsed: isCollapsed
        )
        .onTapGesture {
            withAnimation(AppTheme.Motion.cardSpring) {
                if isCollapsed {
                    collapsedSections.remove(bucket)
                } else {
                    collapsedSections.insert(bucket)
                }
            }
        }

        if !isCollapsed {
            VStack(spacing: AppTheme.Spacing.s) {
                ForEach(items) { item in
                    NotificationCard(
                        item: item,
                        density: .regular,
                        onTriggerAction: { action in
                            triggerAction(item.id, action.id)
                        },
                        onClose: {
                            deleteWithUndo(item)
                        },
                        isSelected: selectedID == item.id
                    )
                    .id(item.id)
                    // 双击复制正文（放在单击之前，SwiftUI 会优先尝试匹配双击）
                    .onTapGesture(count: 2) {
                        NSPasteboard.copy(item.body)
                        showCopyFeedback(L10n.copiedBody)
                    }
                    .onTapGesture {
                        selectedID = (selectedID == item.id) ? nil : item.id
                    }
                }
            }
            .padding(.leading, AppTheme.Spacing.xs)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "tray",
            title: L10n.emptyTitle,
            message: manager.serviceState.isRunning ? L10n.emptyMessageRunning : L10n.emptyMessageStopped
        )
    }

    private var noResultsState: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(AppTheme.Fonts.emptyIcon)
                .foregroundStyle(AppTheme.Colors.tertiaryText)
            Text(L10n.noResultsTitle)
                .font(AppTheme.Fonts.emptyTitle)
                .foregroundStyle(AppTheme.Colors.secondaryText)
            Text(L10n.noResultsMessage)
                .font(AppTheme.Fonts.cardBody)
                .foregroundStyle(AppTheme.Colors.tertiaryText)
            Button(L10n.clearFilters) {
                withAnimation(AppTheme.Motion.ease) {
                    searchText = ""
                    enabledTypes.removeAll()
                }
            }
            .buttonStyle(.bordered)
            .padding(.top, AppTheme.Spacing.xs)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                showClearConfirmation = true
            } label: {
                Label(L10n.clear, systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(manager.items.isEmpty)

            Spacer()

            if hasFilters {
                Text("\(filteredItems.count) / \(manager.items.count)")
                    .font(AppTheme.Fonts.timestamp)
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
            }
        }
        .padding(AppTheme.Spacing.m)
    }

    // MARK: - 键盘导航

    private func moveSelection(by delta: Int) {
        guard !flatItems.isEmpty else { return }
        let current = flatItems.firstIndex { $0.id == selectedID }
        let next: Int
        if let current {
            next = min(max(current + delta, 0), flatItems.count - 1)
        } else {
            next = delta > 0 ? 0 : flatItems.count - 1
        }
        selectedID = flatItems[next].id
    }

    private func activateSelected() {
        guard let id = selectedID,
              let item = flatItems.first(where: { $0.id == id })
        else { return }
        // 有操作则触发第一个，无操作则无效果（Phase 3 可接入「展开详情」）
        if let firstAction = item.actions.first {
            triggerAction(item.id, firstAction.id)
        }
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        let idx = flatItems.firstIndex { $0.id == id }
        removeNotification(id)
        selectedID = nil
        // 删除后自动选中相邻项，保持连续操作
        guard let idx, !flatItems.isEmpty else { return }
        let nextIdx = min(idx, flatItems.count - 1)
        if flatItems.indices.contains(nextIdx) {
            selectedID = flatItems[nextIdx].id
        }
    }

    // MARK: - 复制反馈 toast

    private func showCopyFeedback(_ message: String) {
        withAnimation(AppTheme.Motion.ease) { copyFeedback = message }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            await MainActor.run {
                withAnimation(AppTheme.Motion.ease) { copyFeedback = nil }
            }
        }
    }

    /// 复制反馈浮层（底部居中胶囊）
    @ViewBuilder
    private var copyFeedbackOverlay: some View {
        if let copyFeedback {
            Text(copyFeedback)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Colors.onAccentText)
                .padding(.horizontal, AppTheme.Spacing.m)
                .padding(.vertical, AppTheme.Spacing.xs + 2)
                .background(AppTheme.Colors.overlay)
                .clipShape(Capsule())
                .padding(.bottom, AppTheme.Spacing.xl)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    // MARK: - 单条删除撤销

    /// 删除一条通知，并展示可撤销 toast（4s 内可恢复）。
    private func deleteWithUndo(_ item: NotificationRecord) {
        // 删除当前项，并替换撤销 toast（若有上一个待撤销项，其 toast 自然被新项替换）
        removeNotification(item.id)
        selectedID = nil

        // 取消上一个自动清除任务，避免它误清新 toast
        deleteUndoTask?.cancel()

        withAnimation(AppTheme.Motion.ease) { pendingDelete = item }
        deleteUndoTask = Task {
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                // 4s 后清除 toast（通知已被真正删除，仅清 UI）
                guard pendingDelete?.id == item.id else { return }
                withAnimation(AppTheme.Motion.ease) { pendingDelete = nil }
                deleteUndoTask = nil
            }
        }
    }

    /// 撤销 toast 浮层（底部居中，带撤销按钮）
    @ViewBuilder
    private var undoOverlay: some View {
        if let pendingDelete {
            HStack(spacing: AppTheme.Spacing.s) {
                Text(L10n.deletedNotice)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.onAccentText)
                Spacer(minLength: AppTheme.Spacing.s)
                Button(L10n.undo) {
                    manager.restore(pendingDelete)
                    withAnimation(AppTheme.Motion.ease) { self.pendingDelete = nil }
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.s)
            .background(AppTheme.Colors.overlay)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.bottom, AppTheme.Spacing.l)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

// MARK: - TimeBucket

/// 通知按时间分桶（今天 / 昨天 / 更早）
enum TimeBucket: Hashable {
    case today
    case yesterday
    case earlier

    init(for date: Date) {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            self = .today
        } else if calendar.isDateInYesterday(date) {
            self = .yesterday
        } else {
            self = .earlier
        }
    }

    var title: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .earlier: return "更早"
        }
    }
}
