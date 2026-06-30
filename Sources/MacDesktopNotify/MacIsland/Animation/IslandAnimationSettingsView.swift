import IslandAnimationCore
import SwiftUI

struct IslandAnimationSettingsView: View {
    @ObservedObject var vm: DynamicIslandViewModel
    @State private var path: TransitionPath = .closedToOpened

    private var profileBinding: Binding<IslandAnimationProfile> {
        Binding(
            get: { vm.uiSettings.animations.profiles[path] ?? .default(for: path) },
            set: { newProfile in
                var s = vm.uiSettings.animations
                s.profiles[path] = newProfile
                vm.uiSettings.animations = s
            }
        )
    }

    var body: some View {
        SettingsSection(title: "动画调试") {
            VStack(spacing: 8) {
                Picker("路径", selection: $path) {
                    ForEach(TransitionPath.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.menu)

                SettingsSliderRow(title: "持续时间",
                                  value: Binding(get: { profileBinding.wrappedValue.duration },
                                                 set: { profileBinding.wrappedValue.duration = $0 }),
                                  range: 0.2...0.8, step: 0.01, unit: "s")
                SettingsSliderRow(title: "弹性 bounce",
                                  value: Binding(get: { profileBinding.wrappedValue.bounce },
                                                 set: { profileBinding.wrappedValue.bounce = $0 }),
                                  range: 0.0...0.4, step: 0.01, unit: "")
                SettingsSliderRow(title: "混合 blend(实验性)",
                                  value: Binding(get: { profileBinding.wrappedValue.blendDuration },
                                                 set: { profileBinding.wrappedValue.blendDuration = $0 }),
                                  range: 0.0...0.3, step: 0.01, unit: "")

                curvePicker(title: "尺寸曲线",
                            binding: Binding(get: { profileBinding.wrappedValue.sizeCurve },
                                             set: { profileBinding.wrappedValue.sizeCurve = $0 }))
                curvePicker(title: "底部圆角曲线",
                            binding: Binding(get: { profileBinding.wrappedValue.cornerCurve },
                                             set: { profileBinding.wrappedValue.cornerCurve = $0 }))
                curvePicker(title: "顶部圆角曲线",
                            binding: Binding(get: { profileBinding.wrappedValue.topCornerCurve },
                                             set: { profileBinding.wrappedValue.topCornerCurve = $0 }))
                curvePicker(title: "影子曲线",
                            binding: Binding(get: { profileBinding.wrappedValue.shadowCurve },
                                             set: { profileBinding.wrappedValue.shadowCurve = $0 }))

                SettingsSliderRow(title: "内容延迟",
                                  value: Binding(get: { profileBinding.wrappedValue.contentDelay },
                                                 set: { profileBinding.wrappedValue.contentDelay = $0 }),
                                  range: 0.0...0.3, step: 0.01, unit: "s")
                SettingsSliderRow(title: "内容时长",
                                  value: Binding(get: { profileBinding.wrappedValue.contentDuration },
                                                 set: { profileBinding.wrappedValue.contentDuration = $0 }),
                                  range: 0.05...0.4, step: 0.01, unit: "s")

                previewButton
            }
        }
    }

    private func curvePicker(title: String, binding: Binding<EasingCurve>) -> some View {
        HStack {
            Text(title)
                .font(IslandTheme.Fonts.rowTitle)
                .foregroundStyle(IslandTheme.Colors.primaryText)
            Spacer()
            Picker(title, selection: binding) {
                ForEach(EasingCurve.allCases, id: \.self) { c in
                    Text(c.displayName).tag(c)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .settingsCardStyle()
    }

    private var previewButton: some View {
        Button(action: preview) {
            Label("预览此路径", systemImage: "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(IslandTheme.Colors.buttonFill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("预览 \(path.displayName) 动画")
    }

    private func preview() {
        let pair: (from: IslandStatus, to: IslandStatus)
        switch path {
        case .closedToOpened: pair = (.closed, .opened)
        case .openedToClosed: pair = (.opened, .closed)
        case .closedToPopping: pair = (.closed, .popping)
        case .poppingToClosed: pair = (.popping, .closed)
        case .openedToPopping: pair = (.opened, .popping)
        case .poppingToOpened: pair = (.popping, .opened)
        }
        // 先强制设到 from 态(无动画),再 transition 到 to,看动画效果
        vm.forceSetStatus(pair.from)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            switch pair.to {
            case .opened: vm.notchOpen(.boot)
            case .closed: vm.notchClose()
            case .popping: vm.notchPop(.hover)
            }
        }
    }
}

extension TransitionPath {
    var displayName: String {
        switch self {
        case .closedToOpened: return "closed → opened"
        case .openedToClosed: return "opened → closed"
        case .closedToPopping: return "closed → popping"
        case .poppingToClosed: return "popping → closed"
        case .openedToPopping: return "opened → popping"
        case .poppingToOpened: return "popping → opened"
        }
    }
}

extension EasingCurve {
    var displayName: String { rawValue }
}
