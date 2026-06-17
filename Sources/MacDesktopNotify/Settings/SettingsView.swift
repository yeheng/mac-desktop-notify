import SwiftUI

/// 设置面板视图。
///
/// 4 个分区：服务 / Banner / 通知 / 外观。
/// - 服务配置改动标记 needsServerRestart，用户点「立即应用」重建 APIServer。
/// - 其余配置通过 SettingsStore.didSet 实时生效。
struct SettingsView: View {
    @Bindable var store: SettingsStore

    let applyServerRestart: () -> Void
    let close: () -> Void
    var back: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Form {
                    serviceSection
                    bannerSection
                    notificationsSection
                    appearanceSection
                }
                .formStyle(.grouped)
                .padding(AppTheme.Spacing.s)
            }
        }
        .frame(minWidth: 360, minHeight: 420)
        .onKeyPress(.escape) { close(); return .handled }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.s + 2) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                        .frame(width: AppTheme.Layout.closeButtonSizeLarge, height: AppTheme.Layout.closeButtonSizeLarge)
                }
                .buttonStyle(.plain)
                .background(AppTheme.Colors.buttonFill)
                .clipShape(Circle())
                .help(L10n.back)
                .accessibilityLabel(L10n.back)
            }

            Image(systemName: "gearshape.fill")
                .font(AppTheme.Fonts.iconLarge)
                .foregroundStyle(Color.accentColor)
                .frame(width: AppTheme.Layout.iconSize, height: AppTheme.Layout.iconSize)
                .accessibilityHidden(true)

            Text(L10n.settings)
                .font(AppTheme.Fonts.panelTitle)
                .foregroundStyle(AppTheme.Colors.primaryText)

            Spacer()

            CloseButton(action: close, size: AppTheme.Layout.closeButtonSizeLarge)
        }
        .padding(AppTheme.Spacing.l + 2)
    }

    // MARK: - 服务

    @ViewBuilder
    private var serviceSection: some View {
        Section(L10n.settingsService) {
            HStack {
                Text(L10n.port)
                Spacer()
                TextField("", value: $store.apiPort, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }

            HStack {
                Text(L10n.token)
                Spacer()
                SecureField("", text: $store.apiToken)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 140)
                if !store.authEnabled {
                    Text(L10n.noAuthRequired)
                        .font(AppTheme.Fonts.timestamp)
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                }
            }

            if store.needsServerRestart {
                HStack(spacing: AppTheme.Spacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.Colors.warning)
                    Text(L10n.serverRestartNotice)
                        .font(AppTheme.Fonts.cardBody)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                    Spacer()
                    Button(L10n.applyNow, action: applyServerRestart)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Banner

    @ViewBuilder
    private var bannerSection: some View {
        Section(L10n.settingsBanner) {
            Toggle(L10n.enableBanner, isOn: $store.bannerEnabled)

            HStack {
                Text(L10n.maxVisibleCount)
                Spacer()
                Stepper(value: $store.maxVisibleBanners, in: 1...10, step: 1) {
                    Text("\(store.maxVisibleBanners)")
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
            }

            Picker(L10n.position, selection: $store.bannerPosition) {
                ForEach(BannerPosition.allCases, id: \.self) { pos in
                    Text(pos.displayName).tag(pos)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - 通知

    @ViewBuilder
    private var notificationsSection: some View {
        Section(L10n.settingsNotifications) {
            HStack {
                Text(L10n.defaultTimeout)
                Spacer()
                Stepper(value: $store.defaultTimeout, in: 0...300, step: 1) {
                    Text("\(Int(store.defaultTimeout)) \(L10n.seconds)")
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
            }

            HStack {
                Text(L10n.historyLimit)
                Spacer()
                Stepper(value: $store.maxHistoryItems, in: 10...500, step: 10) {
                    Text("\(store.maxHistoryItems)")
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
            }
        }
    }

    // MARK: - 外观

    @ViewBuilder
    private var appearanceSection: some View {
        Section(L10n.settingsAppearance) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack {
                    Text(L10n.width)
                    Spacer()
                    Text("\(Int(store.bannerWidth)) px")
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
                Slider(value: $store.bannerWidth, in: 320...460, step: 10)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack {
                    Text(L10n.cornerRadius)
                    Spacer()
                    Text("\(Int(store.cornerRadius)) px")
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
                Slider(value: $store.cornerRadius, in: 12...30, step: 1)
            }
        }
    }
}
