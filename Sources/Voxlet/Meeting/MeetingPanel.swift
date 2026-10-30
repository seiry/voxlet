import AppKit
import SwiftUI

/// A non-activating panel that can still take typing for the question field.
private final class MeetingNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The floating meeting panel. It never shows in screen sharing, and it reopens where it was left: the screen is
/// remembered by display ID and the spot as a fraction of that screen, so it follows a second monitor around.
final class MeetingPanelController: NSObject, NSWindowDelegate {
    static let expandedSize = NSSize(width: 330, height: 470)
    static let collapsedSize = NSSize(width: 300, height: 58)

    let meeting: MeetingController
    let ui = MeetingPanelState()
    private var panel: NSPanel?

    init(meeting: MeetingController) {
        self.meeting = meeting
        super.init()
        ui.onCollapseChange = { [weak self] in self?.applySize() }
    }

    var screen: NSScreen? { panel?.screen }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        applySize(restore: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = MeetingNSPanel(
            contentRect: NSRect(origin: .zero, size: Self.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: MeetingPanelView(meeting: meeting, ui: ui))
        return panel
    }

    /// Resizes around the top-left corner, so collapsing does not make the panel jump.
    private func applySize(restore: Bool = false) {
        guard let panel else { return }
        let size = ui.collapsed ? Self.collapsedSize : Self.expandedSize
        if restore {
            panel.setFrame(NSRect(origin: savedOrigin(for: size), size: size), display: true)
        } else {
            let top = panel.frame.maxY
            panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
            clampToScreen()
            savePosition()
        }
    }

    func windowDidMove(_ notification: Notification) {
        savePosition()
    }

    // MARK: - Position memory

    private struct Placement: Codable {
        var display: UInt32
        var x: Double
        var y: Double
    }

    private func savePosition() {
        guard let panel, let screen = panel.screen, let id = Self.displayID(screen) else { return }
        let visible = screen.visibleFrame
        let x = (panel.frame.minX - visible.minX) / max(1, visible.width - panel.frame.width)
        let y = (visible.maxY - panel.frame.maxY) / max(1, visible.height - panel.frame.height)
        let placement = Placement(display: id, x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        if let data = try? JSONEncoder().encode(placement) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: Prefs.meetingPanelFrame)
        }
    }

    /// The saved spot on the saved display; when that display is gone, the main screen's top right.
    private func savedOrigin(for size: NSSize) -> NSPoint {
        let saved = Prefs.string(Prefs.meetingPanelFrame).data(using: .utf8).flatMap { try? JSONDecoder().decode(Placement.self, from: $0) }
        let screen = saved.flatMap { placement in NSScreen.screens.first { Self.displayID($0) == placement.display } }
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screen != nil ? saved!.x : 1
        let y = screen != nil ? saved!.y : 0.04
        return NSPoint(
            x: (visible.minX + (visible.width - size.width) * x).rounded(),
            y: (visible.maxY - size.height - (visible.height - size.height) * y).rounded()
        )
    }

    private func clampToScreen() {
        guard let panel, let visible = panel.screen?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// View state that outlives a meeting: the chosen tab and whether the panel is collapsed.
final class MeetingPanelState: ObservableObject {
    enum Tab: String, CaseIterable {
        case live, notes, ask
    }

    @Published var tab: Tab = Tab(rawValue: Prefs.string(Prefs.meetingPanelTab)) ?? .live {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Prefs.meetingPanelTab) }
    }
    @Published var collapsed = Prefs.bool(Prefs.meetingPanelCollapsed) {
        didSet {
            UserDefaults.standard.set(collapsed, forKey: Prefs.meetingPanelCollapsed)
            onCollapseChange?()
        }
    }
    @Published var notesSeen = 0
    @Published var question = ""
    var onCollapseChange: (() -> Void)?
}

enum MeetingColors {
    static let me = Color(nsColor: .systemBlue)
    static let them = Color(nsColor: .systemGreen)
    static let record = Color(nsColor: .systemRed)
    static let star = Color(nsColor: .systemOrange)
    static let speakers: [Color] = [Color(nsColor: .systemOrange), Color(nsColor: .systemPurple), Color(nsColor: .systemTeal),
                                     Color(nsColor: .systemPink), Color(nsColor: .systemBrown)]
}

struct MeetingPanelView: View {
    @ObservedObject var meeting: MeetingController
    @ObservedObject var ui: MeetingPanelState

    var body: some View {
        VStack(spacing: 0) {
            header
            if ui.collapsed {
                Text(lastLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            } else {
                chips
                if case .finishing(let step) = meeting.state {
                    progress(step)
                } else {
                    tabs
                    Divider()
                    Group {
                        switch ui.tab {
                        case .live: liveTab
                        case .notes: notesTab
                        case .ask: askTab
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    footer
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: ui.tab) { if ui.tab == .notes { ui.notesSeen = meeting.notesVersion } }
    }

    private var lastLine: String {
        if !meeting.interim.isEmpty { return "\(sideName(meeting.interimSide))：\(meeting.interim)" }
        guard let line = meeting.lines.last else { return L10n.t("Waiting for the first sentence") }
        return "\(sideName(line.side))：\(line.text)"
    }

    private func sideName(_ side: MeetingSide) -> String { side == .me ? L10n.t("Me") : L10n.t("Them") }

    // MARK: - Header and chips

    private var header: some View {
        HStack(spacing: 8) {
            RecordingDot(active: meeting.state == .recording)
            Text(stateTitle).font(.system(size: 13, weight: .semibold))
            Text(MeetingFormat.duration(meeting.elapsed))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button { ui.collapsed.toggle() } label: {
                Image(systemName: ui.collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(ui.collapsed ? L10n.t("Expand") : L10n.t("Collapse"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 7)
    }

    private var stateTitle: String {
        switch meeting.state {
        case .idle: return L10n.t("Meeting")
        case .recording: return L10n.t("Recording")
        case .paused: return L10n.t("Paused")
        case .finishing: return L10n.t("Wrapping up")
        }
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Chip(text: L10n.t("Mic"), ok: true)
                Chip(text: L10n.t("Browser audio"), ok: meeting.browserHeard)
                Chip(text: meeting.voiceProcessing ? L10n.t("Echo cancellation on") : L10n.t("Echo cancellation off"), ok: nil)
                Image(systemName: "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(L10n.t("Hidden from screen sharing"))
            }
            if let notice = meeting.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            tabButton(.live, L10n.t("Transcript"))
            tabButton(.notes, L10n.t("Notes"), badge: meeting.notesVersion > ui.notesSeen && ui.tab != .notes)
            tabButton(.ask, L10n.t("Ask"))
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private func tabButton(_ tab: MeetingPanelState.Tab, _ title: String, badge: Bool = false) -> some View {
        Button { ui.tab = tab } label: {
            VStack(spacing: 4) {
                HStack(spacing: 3) {
                    Text(title).font(.system(size: 12.5, weight: ui.tab == tab ? .semibold : .regular))
                    if badge { Circle().fill(MeetingColors.me).frame(width: 6, height: 6) }
                }
                Rectangle().fill(ui.tab == tab ? Color.primary : .clear).frame(height: 2).cornerRadius(1)
            }
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ui.tab == tab ? .primary : .secondary)
    }

    // MARK: - Tabs

    private var liveTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if meeting.lines.isEmpty && meeting.interim.isEmpty {
                        Text(L10n.t("Listening. The first sentence shows up here."))
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    }
                    ForEach(meeting.lines) { line in
                        LineRow(side: line.side, text: line.text, starred: line.starred, interim: false)
                    }
                    if !meeting.interim.isEmpty {
                        LineRow(side: meeting.interimSide, text: meeting.interim, starred: false, interim: true)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: meeting.lines.count) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } }
            .onChange(of: meeting.interim) { proxy.scrollTo("bottom") }
        }
    }

    private var notesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if meeting.notes.isEmpty {
                    Text(L10n.t("A few minutes in, topics, decisions and to-dos show up here."))
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                } else {
                    if let at = meeting.notesUpdatedAt {
                        Text(L10n.format("Updated every 2 to 3 minutes · last at %@", MeetingFormat.duration(at)))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    NotesSections(notes: meeting.notes, starred: meeting.lines.filter(\.starred).map(\.text))
                }
            }
            .padding(12)
        }
    }

    private var askTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    TextField(L10n.t("Ask about the meeting so far"), text: $ui.question)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                    Button(L10n.t("Ask"), action: submit).disabled(ui.question.trimmed.isEmpty)
                }
                HStack(spacing: 5) {
                    ForEach([L10n.t("What is the deadline?"), L10n.t("What did I agree to?"), L10n.t("Sum up so far")], id: \.self) { q in
                        Button(q) { meeting.ask(q) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(meeting.questions.reversed()) { qa in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(qa.question).font(.system(size: 12.5, weight: .semibold))
                        if let answer = qa.answer {
                            Text(answer).font(.system(size: 12.5)).foregroundStyle(.secondary).textSelection(.enabled)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func submit() {
        meeting.ask(ui.question)
        ui.question = ""
    }

    private var footer: some View {
        HStack(spacing: 6) {
            FooterButton(symbol: "star.fill", title: L10n.t("Mark this"), tint: nil) { meeting.star() }
            FooterButton(symbol: meeting.state == .paused ? "play.fill" : "pause.fill",
                         title: meeting.state == .paused ? L10n.t("Resume") : L10n.t("Pause"), tint: nil) { meeting.togglePause() }
            FooterButton(symbol: "stop.fill", title: L10n.t("End"), tint: MeetingColors.record) { meeting.end() }
        }
        .padding(8)
    }

    private func progress(_ step: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(MeetingController.finishSteps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 8) {
                    ZStack {
                        Circle().strokeBorder(index <= step ? Color.primary : Color.secondary.opacity(0.5), lineWidth: 1.5)
                        if index < step { Circle().fill(MeetingColors.them); Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white) }
                    }
                    .frame(width: 14, height: 14)
                    Text(L10n.t(title))
                        .font(.system(size: 12.5, weight: index == step ? .semibold : .regular))
                        .foregroundStyle(index <= step ? .primary : .secondary)
                }
            }
            ProgressView(value: Double(step), total: Double(MeetingController.finishSteps.count))
            Text(L10n.t("Both tracks are saved. This usually takes under a minute."))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct RecordingDot: View {
    let active: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(active ? MeetingColors.record : Color.secondary)
            .frame(width: 8, height: 8)
            .opacity(active && dim ? 0.35 : 1)
            .onAppear {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

private struct Chip: View {
    let text: String
    let ok: Bool?

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
            if let ok {
                Image(systemName: ok ? "checkmark" : "minus").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(ok ? MeetingColors.them : .secondary)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 1.5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

private struct LineRow: View {
    let side: MeetingSide
    let text: String
    let starred: Bool
    let interim: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(side == .me ? L10n.t("Me") : L10n.t("Them"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(side == .me ? MeetingColors.me : MeetingColors.them)
                .frame(width: 30, alignment: .leading)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(interim ? .tertiary : .primary)
                .textSelection(.enabled)
                .padding(.horizontal, side == .me || starred ? 7 : 0)
                .padding(.vertical, side == .me || starred ? 2 : 0)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(starred ? MeetingColors.star.opacity(0.16) : side == .me && !interim ? MeetingColors.me.opacity(0.1) : .clear)
                )
                .overlay(alignment: .leading) {
                    if starred { Rectangle().fill(MeetingColors.star).frame(width: 3) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FooterButton: View {
    let symbol: String
    let title: String
    let tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5))
                Text(title).font(.system(size: 12))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? .primary)
    }
}

struct NotesSections: View {
    let notes: MeetingNotes
    var starred: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section(L10n.t("Topics"), notes.topics.map { AnyView(Text($0)) })
            section(L10n.t("Decisions"), notes.decisions.map { AnyView(Text($0)) })
            section(L10n.t("To-dos"), notes.todos.map { todo in
                AnyView(HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "square").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(todo.text)
                    if !todo.owner.isEmpty { Text("@\(todo.owner)").foregroundStyle(.secondary) }
                })
            })
            section(L10n.t("Viewpoints"), notes.viewpoints.map { AnyView(Text("\($0.speaker)：\($0.text)")) })
            section(L10n.t("Marked"), starred.map { AnyView(Text($0)) })
        }
        .font(.system(size: 12.5))
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [AnyView]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("·").foregroundStyle(.tertiary)
                        items[i]
                    }
                }
            }
        }
    }
}
