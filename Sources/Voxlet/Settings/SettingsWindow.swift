import AppKit
import Combine
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case model
    case permissions
    case hotkey
    case usage
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.t("General")
        case .model: return L10n.t("Model")
        case .permissions: return L10n.t("Permissions")
        case .hotkey: return L10n.t("Hotkey")
        case .usage: return L10n.t("Usage")
        case .about: return L10n.t("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .model: return "cpu"
        case .permissions: return "lock.shield"
        case .hotkey: return "keyboard"
        case .usage: return "chart.bar.xaxis"
        case .about: return "info.circle"
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// The 820×560 settings window from Voxt's MenuWindowCoordinator: transparent titlebar, no toolbar.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let navigation = SettingsNavigation()

    func show(tab: SettingsTab? = nil) {
        if let tab { navigation.tab = tab }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = SettingsStyle.windowBackgroundNSColor
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsRootView(navigation: navigation))
        window.setContentSize(NSSize(width: 820, height: 560))
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Menu-bar only unless the user asked for a Dock icon, as in Voxt's AppBehaviorController.
        if !Prefs.bool(Prefs.showInDock) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var navigation: SettingsNavigation
    @AppStorage(Prefs.interfaceLanguage) private var interfaceLanguage = InterfaceLanguage.system.rawValue
    @State private var permissionsMissing = !Permissions.allGranted

    private let permissionTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            SettingsSidebar(selection: $navigation.tab, permissionsMissing: permissionsMissing)
                .frame(width: 172)

            VStack(alignment: .leading, spacing: 0) {
                Text(navigation.tab.title)
                    .font(.system(size: 22, weight: .bold))
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 14)
                ScrollView {
                    page
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: SettingsStyle.panelRadius, style: .continuous)
                    .fill(SettingsStyle.windowBackground)
            )
        }
        .padding(10)
        .frame(minWidth: 820, minHeight: 560)
        .background(SettingsStyle.windowBackground.ignoresSafeArea())
        .id(interfaceLanguage)
        .onReceive(permissionTimer) { _ in permissionsMissing = !Permissions.allGranted }
    }

    @ViewBuilder
    private var page: some View {
        switch navigation.tab {
        case .general: GeneralSettingsPage()
        case .model: ModelSettingsPage()
        case .permissions: PermissionsSettingsPage()
        case .hotkey: HotkeySettingsPage()
        case .usage: UsageSettingsPage()
        case .about: AboutSettingsPage()
        }
    }
}

/// Voxt's sidebar: 36 pt items with an 18 pt icon slot and a rounded fill when active or hovered.
struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    let permissionsMissing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer().frame(height: 34)
            ForEach(SettingsTab.allCases) { tab in
                SidebarItem(tab: tab, isSelected: selection == tab) { selection = tab }
            }
            Spacer()
            if permissionsMissing {
                Button { selection = .permissions } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(L10n.t("Permissions Disabled"))
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous)
                            .fill(Color.red.opacity(0.10))
                    )
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                AppBadge()
                Spacer()
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

private struct SidebarItem: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(tab.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.primary.opacity(0.94))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected || isHovering ? SettingsStyle.sidebarItemFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The small "Voxt" pill at the bottom of Voxt's sidebar.
struct AppBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor))
            Text("Voxlet").font(.system(size: 13, weight: .semibold))
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous)
                .fill(SettingsStyle.sidebarItemFill)
        )
    }
}
