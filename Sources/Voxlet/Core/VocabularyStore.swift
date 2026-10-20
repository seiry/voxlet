import Foundation

/// Custom vocabulary for Gemini, kept in a plain text file (one term per line, `#` starts a comment) so it can be
/// edited in any editor as well as in Settings. Edits from the app touch only the affected lines, and edits made
/// elsewhere are picked up by watching the folder.
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()
    /// Upper bound for a term typed in Settings or the file.
    static let maxTermLength = 100
    /// Voxt's caps for a selection to count as a term rather than text to dictate over.
    static let maxSelectionWords = 5
    static let maxSelectionCJKRun = 10
    /// Voxt caps the list at the same size; it is not a documented Gemini limit.
    static let maxTermsSent = 1000

    enum AddResult: Equatable {
        case added(String)
        case duplicate(String)
        case invalid
    }

    @Published private(set) var terms: [String] = []

    let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voxlet/vocabulary.txt")

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?

    private init() {
        ensureFile()
        reload()
        watchFolder()
    }

    static func normalized(_ raw: String) -> String? {
        let term = raw.trimmed
        guard !term.isEmpty, term.count <= maxTermLength, !term.contains(where: \.isNewline),
              term.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        return term
    }

    /// Voxt's dictionary-hotkey rule: at most 5 space-separated words and at most 10 CJK characters in a row,
    /// so selecting a sentence still means "dictate over this", not "add this".
    static func selectionCandidate(_ raw: String) -> String? {
        guard let term = normalized(raw),
              term.split(whereSeparator: \.isWhitespace).count <= maxSelectionWords
        else { return nil }
        var run = 0
        for scalar in term.unicodeScalars {
            run = TranscriptJoiner.isCJK(scalar) ? run + 1 : 0
            if run > maxSelectionCJKRun { return nil }
        }
        return term
    }

    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line in
            let term = line.trimmed
            guard !term.isEmpty, !term.hasPrefix("#"), seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }
    }

    @discardableResult
    func add(_ raw: String) -> AddResult {
        guard let term = Self.normalized(raw) else { return .invalid }
        if terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) { return .duplicate(term) }
        var text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += term + "\n"
        write(text)
        return .added(term)
    }

    func remove(_ term: String) {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let kept = text.components(separatedBy: "\n").filter { $0.trimmed.caseInsensitiveCompare(term) != .orderedSame }
        write(kept.joined(separator: "\n"))
    }

    func reload() {
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let parsed = Self.parse(text)
        if parsed != terms { terms = parsed }
    }

    private func write(_ text: String) {
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        reload()
    }

    private func ensureFile() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: fileURL.path) else { return }
        try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = """
        # Voxlet vocabulary: one term per line, sent to Gemini with every dictation.
        # Names, products and jargon that get misheard belong here. Lines starting with # are ignored.

        """
        try? header.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Editors usually save by replacing the file, which a watch on the file itself would lose, so watch its folder.
    private func watchFolder() {
        let descriptor = open(fileURL.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.reloadWork?.cancel()
            let work = DispatchWorkItem { self.reload() }
            self.reloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
}
