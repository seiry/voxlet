import Foundation

/// Defaults are the Gemini API list prices for gemini-3.5-transcribe-live (ai.google.dev/gemini-api/docs/pricing,
/// read 2026-10-20). Agent Platform pricing was not verified, so both are editable in Settings → Usage.
enum Pricing {
    static let defaultAudioInputPerMillion = 3.50
    static let defaultTextOutputPerMillion = 21.00

    static var audioInputPerMillion: Double { Prefs.double(Prefs.priceAudioInputPerMillion) }
    static var textOutputPerMillion: Double { Prefs.double(Prefs.priceTextOutputPerMillion) }

    static func cost(of usage: GeminiUsage) -> Double {
        // Text prompt tokens are negligible for transcription and are billed like audio here.
        Double(usage.audioInputTokens + usage.textInputTokens) * audioInputPerMillion / 1_000_000
            + Double(usage.outputTokens) * textOutputPerMillion / 1_000_000
    }

    static func formatted(_ dollars: Double) -> String {
        if dollars == 0 { return "$0" }
        if dollars < 0.01 { return String(format: "$%.4f", dollars) }
        return String(format: "$%.2f", dollars)
    }
}

struct UsageRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var audioSeconds: Double
    var usage: GeminiUsage
    var characters: Int
}

struct UsageSummary {
    var sessions = 0
    var audioSeconds = 0.0
    var tokens = 0
    var cost = 0.0

    mutating func add(_ record: UsageRecord) {
        sessions += 1
        audioSeconds += record.audioSeconds
        tokens += record.usage.totalTokens
        cost += Pricing.cost(of: record.usage)
    }
}

/// Per-session token counts, persisted as JSON. Costs are computed at read time from the current prices.
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var records: [UsageRecord] = []

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Voxlet", isDirectory: true).appendingPathComponent("usage.json")
    }()

    private init() {
        load()
    }

    func add(_ record: UsageRecord) {
        records.append(record)
        save()
    }

    func reset() {
        records.removeAll()
        save()
    }

    func summary(since start: Date? = nil) -> UsageSummary {
        var summary = UsageSummary()
        for record in records where start.map({ record.date >= $0 }) ?? true {
            summary.add(record)
        }
        return summary
    }

    var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }

    var startOfMonth: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? startOfToday
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([UsageRecord].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
