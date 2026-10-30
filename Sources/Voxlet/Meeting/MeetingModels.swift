import Foundation

/// A finished turn of the live transcript.
struct MeetingLine: Codable, Identifiable, Equatable {
    var id = UUID()
    var side: MeetingSide
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var starred = false
}

/// A turn of the offline transcript. `speaker` is "me" or a raw diarization label such as "c0-spk:1".
struct MeetingSegment: Codable, Equatable, Identifiable {
    var id: String { "\(speaker)-\(start)" }
    var speaker: String
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

struct MeetingNotes: Codable, Equatable {
    struct Todo: Codable, Equatable, Hashable {
        var text: String
        var owner: String
    }

    struct Viewpoint: Codable, Equatable, Hashable {
        var speaker: String
        var text: String
    }

    var topics: [String] = []
    var decisions: [String] = []
    var todos: [Todo] = []
    var viewpoints: [Viewpoint] = []

    var isEmpty: Bool { topics.isEmpty && decisions.isEmpty && todos.isEmpty && viewpoints.isEmpty }

    init() {}

    /// Tolerates missing keys and a todo without an owner; the model is not always exact.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topics = (try? c.decode([String].self, forKey: .topics)) ?? []
        decisions = (try? c.decode([String].self, forKey: .decisions)) ?? []
        todos = (try? c.decode([Todo].self, forKey: .todos)) ?? []
        viewpoints = (try? c.decode([Viewpoint].self, forKey: .viewpoints)) ?? []
    }
}

extension MeetingNotes.Todo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        owner = (try? c.decode(String.self, forKey: .owner)) ?? ""
    }
}

/// Everything about one meeting, saved as meeting.json next to the audio and the Markdown.
struct MeetingRecord: Codable {
    static let fileName = "meeting.json"

    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var lines: [MeetingLine] = []
    var segments: [MeetingSegment] = []
    /// Raw label → display name. "me" is the user.
    var speakers: [String: String] = [:]
    var notes = MeetingNotes()
    var offlineError: String?
    var liveSessions = 0

    func name(for speaker: String) -> String {
        speakers[speaker] ?? (speaker == "me" ? L10n.t("Me") : speaker)
    }

    /// Labels in order of first appearance, "me" last.
    var speakerOrder: [String] {
        var seen: [String] = []
        for segment in segments where segment.speaker != "me" && !seen.contains(segment.speaker) { seen.append(segment.speaker) }
        return seen + (segments.contains { $0.speaker == "me" } ? ["me"] : [])
    }

    /// The offline transcript when there is one, else the live lines as "me" and "them".
    var displaySegments: [MeetingSegment] {
        if !segments.isEmpty { return segments }
        return lines.map { MeetingSegment(speaker: $0.side == .me ? "me" : "them", text: $0.text, start: $0.start, end: $0.end) }
    }

    func clock(_ offset: TimeInterval) -> String {
        Self.timeFormatter.string(from: startedAt.addingTimeInterval(offset))
    }

    var starredLines: [MeetingLine] { lines.filter(\.starred) }

    var notesMarkdown: String {
        var out = ["# \(title)", "", "\(Self.dayFormatter.string(from: startedAt)) · \(MeetingFormat.duration(duration))"]
        let people = speakerOrder.map(name(for:))
        if !people.isEmpty { out.append(people.joined(separator: "、")) }
        out.append("")
        func section(_ heading: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            out += ["## \(heading)"] + items + [""]
        }
        section(L10n.t("Topics"), notes.topics.map { "- \($0)" })
        section(L10n.t("Decisions"), notes.decisions.map { "- \($0)" })
        section(L10n.t("To-dos"), notes.todos.map { "- [ ] \($0.text)" + ($0.owner.isEmpty ? "" : " @\($0.owner)") })
        section(L10n.t("Viewpoints"), notes.viewpoints.map { "- \($0.speaker)：\($0.text)" })
        section(L10n.t("Marked"), starredLines.map { "- \(clock($0.start)) \($0.text)" })
        return out.joined(separator: "\n")
    }

    var transcriptMarkdown: String {
        var out = ["# \(title)", ""]
        let marked = starredLines.map { ($0.start, $0.end) }
        for segment in displaySegments {
            let star = marked.contains { segment.start < $0.1 + 1 && segment.end > $0.0 - 1 } ? " ★" : ""
            let who = segment.speaker == "them" ? L10n.t("Them") : name(for: segment.speaker)
            out.append("**\(clock(segment.start)) \(who)**\(star)  ")
            out.append(segment.text)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

/// Even with zh-CN requested, both transcribe models now and then answer a Taiwanese-accented speaker in
/// Traditional characters; a Simplified meeting record should read one way throughout.
enum ChineseScript {
    static func normalize(_ text: String, languageCodes: [String]) -> String {
        guard languageCodes.contains(where: { $0.hasPrefix("zh-CN") || $0.hasPrefix("zh-Hans") || $0 == "zh" || $0.hasPrefix("cmn") })
        else { return text }
        return text.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) ?? text
    }
}

enum MeetingFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Where meetings are kept: ~/Meetings by default, one folder per meeting.
enum MeetingStore {
    static var root: URL {
        let raw = Prefs.string(Prefs.meetingFolder).trimmed
        let path = (raw.isEmpty ? "~/Meetings" : raw) as NSString
        return URL(fileURLWithPath: path.expandingTildeInPath, isDirectory: true)
    }

    static func newFolder(title: String, date: Date) throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmed
        var url = root.appendingPathComponent("\(f.string(from: date)) \(safe)", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(f.string(from: date)) \(safe) \(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("audio"), withIntermediateDirectories: true)
        return url
    }

    static func save(_ record: MeetingRecord, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: folder.appendingPathComponent(MeetingRecord.fileName), options: .atomic)
        try record.notesMarkdown.write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try record.transcriptMarkdown.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }

    static func load(from folder: URL) throws -> MeetingRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingRecord.self, from: Data(contentsOf: folder.appendingPathComponent(MeetingRecord.fileName)))
    }
}
