import AppKit
import SwiftUI

/// Flat dynamic palette and radii taken from Voxt's SettingsUIStyles; no materials or vibrancy.
enum SettingsStyle {
    static let windowBackground = dynamic(light: 0.98, dark: 0.09)
    static let panelFill = dynamic(light: 1.0, dark: 0.125)
    static let controlFill = dynamic(light: 0.965, dark: 0.20)
    static let sidebarItemFill = dynamic(light: 0.933, dark: 0.22)
    static let sidebarItemPressed = dynamic(light: 0.902, dark: 0.27)
    static let subtleBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.075) : NSColor.black.withAlphaComponent(0.045)
    })

    static var windowBackgroundNSColor: NSColor {
        NSColor(name: nil) { $0.isDark ? NSColor(white: 0.09, alpha: 1) : NSColor(white: 0.98, alpha: 1) }
    }

    static let panelRadius: CGFloat = 16
    static let compactRadius: CGFloat = 12
    static let controlRadius: CGFloat = 10

    private static func dynamic(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(white: dark, alpha: 1) : NSColor(white: light, alpha: 1) })
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// A titled section in a white panel, like Voxt's GeneralSettingsCard.
struct SettingsCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsStyle.panelRadius, style: .continuous)
                .fill(SettingsStyle.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsStyle.panelRadius, style: .continuous)
                .strokeBorder(SettingsStyle.subtleBorder, lineWidth: 1)
        )
    }
}

/// Label and optional caption on the left, control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let caption {
                    Text(caption)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(SettingsStyle.subtleBorder).frame(height: 1)
    }
}

/// Rounded grey text field, the look of the endpoint and key inputs in Voxt's model sheet.
struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var width: CGFloat? = nil

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(width: width, height: 32)
        .background(
            RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous)
                .fill(SettingsStyle.controlFill)
        )
    }
}

struct SettingsCompactButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous)
                    .fill(prominent ? Color.accentColor : SettingsStyle.controlFill)
                    .opacity(configuration.isPressed ? 0.75 : 1)
            )
    }
}

struct StatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
    }
}

/// Segmented control drawn like Voxt's ASR / LLM switch: a grey track with a raised selection.
struct SettingsSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let selected = value == selection
                Button {
                    selection = value
                } label: {
                    Text(label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous)
                .fill(SettingsStyle.controlFill)
        )
    }
}
