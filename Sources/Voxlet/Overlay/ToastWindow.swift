import AppKit
import SwiftUI

/// A small 240×52 confirmation card, Voxt's FloatingToastWindow: green check for success, orange for warnings.
final class ToastWindowController {
    enum Kind {
        case success
        case warning

        var symbol: String { self == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill" }
        var color: Color { Color(nsColor: self == .success ? .systemGreen : .systemOrange) }
    }

    private static let size = NSSize(width: 240, height: 52)
    private static let duration: TimeInterval = 1.8

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ message: String, kind: Kind = .success) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: ToastView(message: message, kind: kind))
        panel.setFrame(frame(), display: true)
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: frame(), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func frame() -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let inset = CGFloat(min(max(Prefs.double(Prefs.overlayEdgeDistance), 0), 120))
        let y = Prefs.string(Prefs.overlayPosition) == OverlayPosition.top.rawValue
            ? visible.maxY - Self.size.height - inset
            : visible.minY + inset
        return NSRect(x: (visible.midX - Self.size.width / 2).rounded(), y: y.rounded(), width: Self.size.width, height: Self.size.height)
    }
}

private struct ToastView: View {
    let message: String
    let kind: ToastWindowController.Kind
    @AppStorage(Prefs.overlayOpacity) private var opacity = 82.0
    @AppStorage(Prefs.overlayCornerRadius) private var cornerRadiusSetting = 24.0
    @State private var appeared = false

    private var cornerRadius: CGFloat { CGFloat(min(max(cornerRadiusSetting, 0), 40)) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(kind.color)
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.94))
        }
        .padding(.horizontal, 14)
        .frame(width: 240, height: 52)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.black.opacity(min(max(opacity, 0), 100) / 100))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .scaleEffect(appeared ? 1 : 0.88, anchor: .bottom)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.62, blendDuration: 0.1), value: appeared)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { appeared = true } }
    }
}
