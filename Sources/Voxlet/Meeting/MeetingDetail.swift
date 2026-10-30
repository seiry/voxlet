import AppKit
import SwiftUI

/// The finished meeting: rename speakers, read the notes beside the offline transcript, copy or reveal the files.
final class MeetingDetailModel: ObservableObject {
    @Published var record: MeetingRecord
    @Published var regenerating = false
    @Published var status: String?
    let folder: URL

    init(record: MeetingRecord, folder: URL) {
        self.record = record
        self.folder = folder
    }

    func rename(_ label: String, to name: String) {
        let trimmed = name.trimmed
        guard !trimmed.isEmpty, record.speakers[label] != trimmed else { return }
        let old = record.name(for: label)
        record.speakers[label] = trimmed
        // Notes written before the rename still carry the old name.
        record.notes.viewpoints = record.notes.viewpoints.map { .init(speaker: $0.speaker == old ? trimmed : $0.speaker, text: $0.text) }
        record.notes.todos = record.notes.todos.map { .init(text: $0.text, owner: $0.owner == old ? trimmed : $0.owner) }
        save()
    }

    func regenerateNotes() {
        let gateway = MeetingGateway.current
        guard gateway.isConfigured, !regenerating else { return }
        regenerating = true
        var named = record
        named.segments = record.segments.map { segment in
            var copy = segment
            copy.speaker = record.name(for: segment.speaker)
            return copy
        }
        Task { [weak self] in
            let result = try? await gateway.generateJSON(MeetingPrompts.writeUp(record: named), as: MeetingPrompts.WriteUp.self)
            await MainActor.run {
                guard let self else { return }
                self.regenerating = false
                if let notes = result?.notes, !notes.isEmpty {
                    self.record.notes = notes
                    self.save()
                    self.status = L10n.t("Notes regenerated.")
                } else {
                    self.status = L10n.t("The notes could not be regenerated. Try again in a moment.")
                }
            }
        }
    }

    func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.notesMarkdown, forType: .string)
        status = L10n.t("Notes copied as Markdown.")
    }

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("notes.md")])
    }

    private func save() {
        do {
            try MeetingStore.save(record, in: folder)
        } catch {
            status = error.localizedDescription
        }
    }
}

final class MeetingDetailWindowController: NSObject, NSWindowDelegate {
    private var windows: [NSWindow] = []

    func show(record: MeetingRecord, folder: URL, on screen: NSScreen?) {
        let model = MeetingDetailModel(record: record, folder: folder)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = record.title
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: MeetingDetailView(model: model))
        window.setContentSize(NSSize(width: 860, height: 600))
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - 430, y: visible.midY - 300))
        }
        windows.append(window)
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        windows.removeAll { $0 === notification.object as? NSWindow }
        if windows.isEmpty, !Prefs.bool(Prefs.showInDock), !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) && !windows.contains($0) }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct MeetingDetailView: View {
    @ObservedObject var model: MeetingDetailModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            speakers
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.t("Notes")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        if model.record.notes.isEmpty {
                            Text(L10n.t("No notes yet.")).foregroundStyle(.secondary)
                        }
                        NotesSections(notes: model.record.notes, starred: model.record.starredLines.map(\.text))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 260, maxWidth: .infinity)
                Divider()
                transcript
                    .frame(minWidth: 320, maxWidth: .infinity)
                    .layoutPriority(1)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.record.title).font(.system(size: 15, weight: .semibold))
            Text("\(MeetingRecord.dayFormatter.string(from: model.record.startedAt)) · \(MeetingFormat.duration(model.record.duration))")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            if let error = model.record.offlineError {
                Label(L10n.t("Showing the live transcript"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5)).foregroundStyle(.orange).help(error)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 10)
    }

    private var speakers: some View {
        HStack(spacing: 14) {
            Text(L10n.t("Speakers")).font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(Array(model.record.speakerOrder.enumerated()), id: \.element) { index, label in
                SpeakerField(label: label, color: color(for: label, index: index), name: model.record.name(for: label)) { name in
                    model.rename(label, to: name)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func color(for label: String, index: Int) -> Color {
        label == "me" ? MeetingColors.me : MeetingColors.speakers[index % MeetingColors.speakers.count]
    }

    private var transcript: some View {
        let order = model.record.speakerOrder
        let starred = model.record.starredLines
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                Text(model.record.segments.isEmpty ? L10n.t("Live transcript") : L10n.t("Full transcript, transcribed again after the meeting"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(model.record.displaySegments) { segment in
                    let index = order.firstIndex(of: segment.speaker) ?? 0
                    let marked = starred.contains { segment.start < $0.end + 1 && segment.end > $0.start - 1 }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.record.clock(segment.start))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                            .frame(width: 58, alignment: .leading)
                        Text(segment.speaker == "them" ? L10n.t("Them") : model.record.name(for: segment.speaker))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(segment.speaker == "them" ? MeetingColors.them : color(for: segment.speaker, index: index))
                            .frame(width: 70, alignment: .leading)
                            .lineLimit(1)
                        Text(segment.text)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .padding(.horizontal, marked ? 6 : 0)
                            .background(marked ? MeetingColors.star.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let status = model.status {
                Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.regenerating { ProgressView().controlSize(.small) }
            Button(L10n.t("Regenerate Notes")) { model.regenerateNotes() }.disabled(model.regenerating)
            Button(L10n.t("Show in Finder")) { model.reveal() }
            Button(L10n.t("Copy Markdown")) { model.copyMarkdown() }.keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct SpeakerField: View {
    let label: String
    let color: Color
    let name: String
    let commit: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .onSubmit { commit(text) }
                .help(label == "me" ? L10n.t("Your name in the notes") : L10n.t("Rename this speaker everywhere"))
        }
        .onAppear { text = name }
        .onChange(of: name) { text = name }
    }
}
