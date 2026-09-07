import SwiftUI

/// First-run guide: three steps, skippable, reopenable from Settings → 关于.
///
/// The app is inert until something calls it, so the guide's one job is to make
/// the first "something" happen inside ten seconds - a real push the user can
/// see, a snippet they can copy, and a preset that tunes the attention level.
struct OnboardingView: View {
    var onDismiss: () -> Void
    @Bindable private var settings: AppSettings = .shared
    @State private var step = 0
    @State private var testFeedback: String?

    /// The levels come from `AttentionPreset` (AppSettings.swift): onboarding
    /// and Settings -> 通知 offer the same three choices, writing the same
    /// underlying settings, so neither can drift from the other.
    typealias Preset = AttentionPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("欢迎使用 NotchNotify")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()

            }
            .padding(.bottom, 4)

            Text("把脚本、CI 和 Agent 的消息推进刘海。三步即可用起来。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 14)

            switch step {
            case 0: tryStep
            case 1: connectStep
            default: presetStep
            }

            Divider().padding(.vertical, 14)

            HStack {
                Button("稍后设置") { finish(preset: nil) }
                    .buttonStyle(.borderless)
                    .help("可从设置 → 关于重新打开引导")
                ProgressView(value: Double(step + 1), total: 3)
                    .frame(maxWidth: 120)
                Spacer()
                if step > 0 {
                    Button("上一步") { step -= 1 }.buttonStyle(.borderless)
                }
                Button(step == 2 ? "开始使用" : "继续") { advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("首次运行引导")
    }

    private func advance() {
        if step == 2 {
            finish(preset: selectedPreset)
        } else {
            step += 1
        }
    }

    private func finish(preset: Preset?) {
        preset?.apply(to: settings)
        settings.onboardingPreset = preset?.rawValue
        settings.onboardingCompleted = true
        onDismiss()
    }

    // MARK: - Step 1: see one

    private var tryStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader("第 1 步 · 看一眼效果", "发一条真实的通知，亲眼看看它长什么样。")
            Button {
                let outcome = NotificationManager.shared.push(NotchNotification(
                    title: "试一试", bodyMarkdown: "这是引导发送的测试通知", urgency: .normal, timeout: 10
                ))
                switch outcome {
                case .displayed:
                    testFeedback = "测试通知已发送，请查看屏幕顶部；全屏时请先退出全屏。"
                case .queued:
                    testFeedback = "有紧急消息正在占屏；测试通知已存入历史（未读），可打开历史信息查看。"
                case .withheld:
                    testFeedback = "测试通知已保存；静默或离开状态下不会弹出，可在历史信息中查看。"
                }
            } label: {
                Label("发送一条测试通知", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if let testFeedback {
                Text(testFeedback)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("查看历史信息") {
                    NotificationCenter.default.post(name: .openHistoryWindow, object: nil)
                }
                .buttonStyle(.borderless)
            }
            Text("通知出现在屏幕顶部。点击摘要栏打开消息中心；在设置允许时，鼠标靠近也可展开。拖动卡片顶部上滑可收起当前消息，消息仍保留在历史中。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 2: wire it up

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader("第 2 步 · 接入你的脚本", "复制到终端试试，或粘进任何语言的项目。")
            CodeSnippetView(code: "open 'notch-notify://push?title=构建完成&body=全部通过'")
            Text("完整协议（紧急度、分组、动作按钮、回执）见 README。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 3: pick a level

    @State private var selectedPreset: Preset = .balanced

    private var presetStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader("第 3 步 · 选一个档位", "随时可以在设置里改。")
            ForEach(Preset.allCases, id: \.rawValue) { preset in
                Button {
                    selectedPreset = preset
                } label: {
                    HStack {
                        Image(systemName: selectedPreset == preset ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedPreset == preset ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title).font(.system(.body, design: .rounded).weight(.medium))
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(selectedPreset == preset ? Color.accentColor.opacity(0.1) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// A copyable code line. The copy button exists because a snippet you cannot
/// copy in one click is a picture of code, not code.
struct CodeSnippetView: View {
    let code: String
    var subtitle: String? = nil
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(copied ? "已复制" : "复制")
            .accessibilityLabel(copied ? "已复制" : "复制代码")
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
