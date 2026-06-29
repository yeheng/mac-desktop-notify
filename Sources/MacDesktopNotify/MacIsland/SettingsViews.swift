import SwiftUI

// MARK: - Card Modifier

struct SettingsCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(IslandTheme.Colors.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(IslandTheme.Colors.cardBorder, lineWidth: 1)
            )
    }
}

extension View {
    func settingsCardStyle() -> some View {
        modifier(SettingsCardModifier())
    }
}

// MARK: - Settings Components

struct SettingsSection<Content: View>: View {
    let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(IslandTheme.Fonts.sectionTitle)
                .foregroundStyle(IslandTheme.Colors.labelText)

            VStack(spacing: 8) {
                content
            }
        }
    }
}

struct SettingsStepperRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(IslandTheme.Fonts.rowTitle)
                    .foregroundStyle(IslandTheme.Colors.primaryText)

                Text(formattedValue)
                    .font(IslandTheme.Fonts.rowValue)
                    .foregroundStyle(IslandTheme.Colors.valueText)
            }

            Spacer(minLength: 10)

            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
        .settingsCardStyle()
    }

    private var formattedValue: String {
        if step < 1 {
            return "\(String(format: "%.1f", value))\(unit)"
        }
        return "\(Int(value.rounded()))\(unit)"
    }
}

struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(IslandTheme.Fonts.rowTitle)
                    .foregroundStyle(IslandTheme.Colors.primaryText)

                Spacer()

                Text(formattedValue)
                    .font(IslandTheme.Fonts.rowValue)
                    .foregroundStyle(IslandTheme.Colors.valueText)
            }

            Slider(value: $value, in: range, step: step)
        }
        .settingsCardStyle()
    }

    private var formattedValue: String {
        if step < 1 {
            return "\(String(format: "%.1f", value))\(unit)"
        }
        return "\(Int(value.rounded()))\(unit)"
    }
}

struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(IslandTheme.Fonts.rowTitle)
                .foregroundStyle(IslandTheme.Colors.primaryText)
        }
        .toggleStyle(.switch)
        .tint(.white)
        .settingsCardStyle()
    }
}

struct SettingsServiceStateRow: View {
    let state: APIServiceState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.statusImageName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state.isRunning ? .green.opacity(0.9) : .orange.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(IslandTheme.Colors.buttonFill)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("服务状态")
                    .font(IslandTheme.Fonts.endpointLabel)
                    .foregroundStyle(IslandTheme.Colors.labelText)
                Text(state.statusText)
                    .font(IslandTheme.Fonts.endpointValue)
                    .foregroundStyle(IslandTheme.Colors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)
        }
        .settingsCardStyle()
        .accessibilityElement(children: .combine)
    }
}

struct SettingsEndpointRow: View {
    let title: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(IslandTheme.Fonts.endpointLabel)
                    .foregroundStyle(IslandTheme.Colors.labelText)
                Text(value)
                    .font(IslandTheme.Fonts.endpointValue)
                    .foregroundStyle(IslandTheme.Colors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)

            Button(action: copyEndpoint) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copied ? .green.opacity(0.9) : IslandTheme.Colors.primaryText.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(copied ? IslandTheme.Colors.buttonActive : IslandTheme.Colors.buttonFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(copied ? "已复制" : "复制\(title)")
            .accessibilityLabel(copied ? "\(title)已复制" : "复制\(title)")
        }
        .settingsCardStyle()
    }

    private func copyEndpoint() {
        NSPasteboard.copy(value)
        withAnimation(.easeInOut(duration: 0.16)) {
            copied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.16)) {
                copied = false
            }
        }
    }
}
