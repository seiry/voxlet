import AppKit
import SwiftUI

/// Sample meeting content for `--render-previews`, taken from the end-to-end meeting.
enum MeetingPreviews {
    static let lines: [MeetingLine] = {
        let rows: [(MeetingSide, String, Double, Double, Bool)] = [
            (.them, "大家好，今天我们过一下 Voxlet 会议模式的进度，先说说上周的 release。", 0.4, 8.4, false),
            (.them, "Last week we shipped version 0.3. It mostly fixed the hotkey issues, and the crash rate is now below 1%.", 8.6, 16.3, false),
            (.me, "我补充一下，耳机模式我已经测过了，没有问题。", 16.6, 22.1, false),
            (.them, "好的，那 Gemini Live 的 10 分钟限制现在是怎么处理的？", 22.3, 28.2, false),
            (.them, "At the ninth minute we open a new WebSocket connection, overlap the two for two seconds, then remove duplicates.", 28.5, 35.8, true),
            (.me, "我觉得先测 Apple 的 voice processing，不行再换。", 44.1, 48.8, false),
        ]
        return rows.map { MeetingLine(side: $0.0, text: $0.1, start: $0.2, end: $0.3, starred: $0.4) }
    }()

    static let notes: MeetingNotes = {
        var n = MeetingNotes()
        n.topics = ["Voxlet 会议模式进度", "Gemini Live 十分钟会话上限", "外放时的回声消除"]
        n.decisions = ["第九分钟预建新连接，重叠两秒后去重", "先测系统自带回声消除，不行再换 WebRTC AEC3"]
        n.todos = [.init(text: "周五前交付会议模式第一版", owner: "Seiry")]
        n.viewpoints = [.init(speaker: "Shelley", text: "0.3 版修了快捷键问题，崩溃率降到 1% 以下"), .init(speaker: "我", text: "耳机模式已测试通过")]
        return n
    }()

    static var record: MeetingRecord {
        var r = MeetingRecord(title: "Voxlet 周会", startedAt: Date(timeIntervalSince1970: 1_793_340_000), duration: 2_841)
        r.lines = lines
        r.notes = notes
        r.segments = [
            .init(speaker: "c0-spk:0", text: "大家好，今天我们过一下 Voxlet 会议模式的进度，先说说上周的 release。", start: 0.4, end: 7.6),
            .init(speaker: "c0-spk:1", text: "Last week we shipped version 0.3. It mostly fixed the hotkey issues.", start: 8.4, end: 15.6),
            .init(speaker: "me", text: "我补充一下，耳机模式我已经测过了，没有问题。", start: 16.4, end: 21.3),
            .init(speaker: "c0-spk:0", text: "好的。那 Gemini Live 的十分钟限制，现在是怎么处理的？", start: 22.1, end: 27.5),
            .init(speaker: "c0-spk:1", text: "At the ninth minute we open a new WebSocket connection, overlap the two for two seconds.", start: 28.3, end: 35.1),
            .init(speaker: "me", text: "对，这个方案我同意。", start: 29.3, end: 31.5),
            .init(speaker: "me", text: "我觉得先测 Apple 的 voice processing，不行再换。", start: 43.9, end: 48.1),
        ]
        r.speakers = ["c0-spk:0": "王浩", "c0-spk:1": "Shelley", "me": "Seiry"]
        return r
    }

    static func render(into directory: URL, using render: (AnyView, NSSize, NSAppearance.Name, NSColor, URL) -> Void) {
        // The panel state persists per user; put back whatever the user had.
        let defaults = UserDefaults.standard
        let savedTab = defaults.object(forKey: Prefs.meetingPanelTab)
        let savedCollapsed = defaults.object(forKey: Prefs.meetingPanelCollapsed)
        defer {
            defaults.set(savedTab, forKey: Prefs.meetingPanelTab)
            defaults.set(savedCollapsed, forKey: Prefs.meetingPanelCollapsed)
        }
        let wallpaper = NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.72, alpha: 1)
        let interim: (MeetingSide, String) = (.them, "Sure, but first we need to check whether it")
        let states: [(String, MeetingPanelState.Tab, Bool, MeetingController.State)] = [
            ("live", .live, false, .recording), ("notes", .notes, false, .recording), ("ask", .ask, false, .recording),
            ("collapsed", .live, true, .recording), ("finishing", .live, false, .finishing(step: 1)),
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            for (name, tab, collapsed, state) in states {
                let meeting = MeetingController()
                meeting.loadPreview(state: state, lines: lines, interim: interim, notes: notes, elapsed: 1_423,
                                    questions: tab == .ask ? [("截止时间是哪天？", "周五之前交付会议模式第一版，由你负责（14:23 王浩提出）。")] : [])
                let ui = MeetingPanelState()
                ui.tab = tab
                ui.collapsed = collapsed
                let size = collapsed ? MeetingPanelController.collapsedSize : MeetingPanelController.expandedSize
                render(AnyView(MeetingPanelView(meeting: meeting, ui: ui)), size, appearance, wallpaper,
                       directory.appendingPathComponent("meeting-panel-\(name)-\(suffix).png"))
            }
            render(AnyView(MeetingDetailView(model: MeetingDetailModel(record: record, folder: URL(fileURLWithPath: NSHomeDirectory() + "/Meetings/2026-10-30 1400 Voxlet 周会")))),
                   NSSize(width: 860, height: 600), appearance, NSColor.windowBackgroundColor,
                   directory.appendingPathComponent("meeting-detail-\(suffix).png"))
        }
    }
}
