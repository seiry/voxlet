import AVFoundation
import Foundation

/// The text model behind running notes, questions and the final write-up: Gemini's generateContent through the
/// user's new-api gateway. It is never given audio; as an ASR it is blocked by filters and invents speech.
struct MeetingGateway {
    var baseURL: String
    var apiKey: String
    var model: String

    static var current: MeetingGateway {
        let env = ProcessInfo.processInfo.environment
        return MeetingGateway(
            baseURL: env["VOXLET_GATEWAY_URL"] ?? Prefs.string(Prefs.meetingGatewayURL),
            apiKey: env["VOXLET_GATEWAY_KEY"] ?? Keychain.gatewayKey ?? "",
            model: env["VOXLET_NOTES_MODEL"] ?? Prefs.string(Prefs.meetingNotesModel)
        )
    }

    var isConfigured: Bool { !apiKey.trimmed.isEmpty && URL(string: baseURL.trimmed) != nil }

    func generate(_ prompt: String, json: Bool) async throws -> String {
        var base = baseURL.trimmed
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        guard let url = URL(string: "\(base)/v1beta/models/\(model.trimmed):generateContent") else {
            throw VoxletError(L10n.t("The notes gateway URL is invalid."))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey.trimmed, forHTTPHeaderField: "x-goog-api-key")
        var body: [String: Any] = ["contents": [["role": "user", "parts": [["text": prompt]]]]]
        if json { body["generationConfig"] = ["responseMimeType": "application/json"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error = VoxletError(L10n.t("The notes model returned nothing."))
        for attempt in 0..<2 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 2_000_000_000) }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
                    let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
                    lastError = VoxletError(message)
                    continue
                }
                let parts = (((object["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
                let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
                if !text.trimmed.isEmpty { return text }
                if let feedback = object["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
                    lastError = VoxletError(L10n.format("The notes model refused the request (%@).", reason))
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func generateJSON<T: Decodable>(_ prompt: String, as type: T.Type) async throws -> T {
        let text = try await generate(prompt, json: true)
        return try JSONDecoder().decode(T.self, from: Data(Self.stripFences(text).utf8))
    }

    /// responseMimeType is not always honoured; a ```json fence still comes back now and then.
    static func stripFences(_ text: String) -> String {
        var t = text.trimmed
        if t.hasPrefix("```") {
            if let newline = t.firstIndex(of: "\n") { t = String(t[t.index(after: newline)...]) }
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t.trimmed
    }
}

enum MeetingPrompts {
    static let notesSchema = #"{"topics":[string],"decisions":[string],"todos":[{"text":string,"owner":string}],"viewpoints":[{"speaker":string,"text":string}]}"#

    static func runningNotes(previous: MeetingNotes, newLines: [MeetingLine]) -> String {
        let previousJSON = (try? String(data: JSONEncoder().encode(previous), encoding: .utf8)) ?? "{}"
        let lines = newLines.map { "\($0.side == .me ? "我" : "对方"): \($0.text)" }.joined(separator: "\n")
        return """
        You keep running notes for a live meeting. "我" is the user; "对方" is anyone on the other side of the call.
        Merge the new transcript lines into the previous notes and return the full updated notes.
        Keep each list short (at most 8 items), one plain sentence per item, in the language the meeting is held in.
        A to-do needs an owner when the transcript names one ("我" for the user). Do not invent anything.
        Return JSON only, shaped as \(notesSchema).

        Previous notes:
        \(previousJSON)

        New transcript lines:
        \(lines)
        """
    }

    static func answer(question: String, lines: [MeetingLine], startedAt: Date) -> String {
        let f = MeetingRecord.timeFormatter
        let transcript = lines.map { "[\(f.string(from: startedAt.addingTimeInterval($0.start)))] \($0.side == .me ? "我" : "对方"): \($0.text)" }
            .joined(separator: "\n")
        return """
        Answer the user's question about the meeting so far, using only this transcript. "我" is the user.
        At most three sentences, in the language of the question. Mention the time when it helps. If the
        transcript does not say, say so.

        Transcript:
        \(transcript)

        Question: \(question)
        """
    }

    struct WriteUp: Decodable {
        var title: String?
        var speakers: [String: String]?
        var notes: MeetingNotes?
    }

    static func writeUp(record: MeetingRecord) -> String {
        let transcript = record.segments.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
        let labels = record.speakerOrder.filter { $0 != "me" }
        return """
        This is a finished meeting transcript. Speaker "me" is the user. The other labels come from per-chunk
        speaker diarization: the same person can carry different labels in different chunks ("c0-…", "c1-…").
        1. Give each label a display name: the person's real name when the conversation reveals it (someone
           addressed by name, a self-introduction), otherwise "说话人 1", "说话人 2", … Labels that are the same
           person get the same name.
        2. Write a short title for the meeting (at most 12 characters for Chinese, 6 words for English).
        3. Write the meeting notes in the meeting's language, using the display names. At most 8 items per list.
        Return JSON only: {"title":string,"speakers":{label:name},"notes":\(notesSchema)}
        Labels to name: \(labels.joined(separator: ", "))

        Running notes taken during the meeting, for reference:
        \((try? String(data: JSONEncoder().encode(record.notes), encoding: .utf8)) ?? "{}")

        Transcript:
        \(transcript)
        """
    }
}

/// Offline transcription with Vertex gemini-3.5-transcribe: more accurate than the live model, and the only one
/// that can tell speakers apart. Agent Platform only; the request shape was captured from google-genai.
struct MeetingOfflineTranscriber {
    /// 14 minutes, under the 15-minute limit for diarization on Agent Platform. VOXLET_OFFLINE_CHUNK_SECONDS lets
    /// the self-test exercise several chunks with a short meeting.
    static var chunkSeconds: TimeInterval {
        Double(ProcessInfo.processInfo.environment["VOXLET_OFFLINE_CHUNK_SECONDS"] ?? "") ?? 840
    }
    var apiKey: String
    var languageCodes: [String]

    static var current: MeetingOfflineTranscriber {
        let env = ProcessInfo.processInfo.environment
        let configured = RecognitionLanguage.codes(for: Prefs.string(Prefs.recognitionLanguage))
        // Without language codes, diarized output comes back in Traditional Chinese.
        return MeetingOfflineTranscriber(
            apiKey: env["VOXLET_API_KEY"] ?? Keychain.apiKey ?? "",
            languageCodes: configured.isEmpty ? ["zh-CN", "en-US"] : configured
        )
    }

    func transcribe(_ url: URL, label: String?, diarize: Bool) async throws -> [MeetingSegment] {
        let chunks = try AudioChunker.chunks(of: url, seconds: Self.chunkSeconds)
        defer { chunks.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        var segments: [MeetingSegment] = []
        for (index, chunk) in chunks.enumerated() {
            let parts = try await request(Data(contentsOf: chunk.url), diarize: diarize)
            for part in parts {
                let speaker = label ?? "c\(index)-\(part.speaker ?? "spk:0")"
                segments += part.segments(speaker: speaker, offset: chunk.offset).map { segment in
                    var copy = segment
                    copy.text = ChineseScript.normalize(segment.text, languageCodes: languageCodes)
                    return copy
                }
            }
        }
        return segments
    }

    private struct Part {
        var speaker: String?
        var text: String
        var words: [(String, TimeInterval, TimeInterval)]

        /// Splits a speaker's part at pauses longer than a second, so the transcript reads in turns.
        func segments(speaker: String, offset: TimeInterval) -> [MeetingSegment] {
            guard !words.isEmpty else {
                return text.trimmed.isEmpty ? [] : [MeetingSegment(speaker: speaker, text: text.trimmed, start: offset, end: offset)]
            }
            var out: [MeetingSegment] = []
            var current: [(String, TimeInterval, TimeInterval)] = []
            func flush() {
                guard let first = current.first, let last = current.last else { return }
                out.append(MeetingSegment(speaker: speaker, text: Self.join(current.map(\.0)), start: first.1 + offset, end: last.2 + offset))
                current = []
            }
            for word in words {
                if let last = current.last, word.1 - last.2 > 1.0 { flush() }
                current.append(word)
            }
            flush()
            return out
        }

        static func join(_ words: [String]) -> String {
            var out = ""
            for word in words {
                if let a = out.unicodeScalars.last, let b = word.unicodeScalars.first,
                   a.properties.isAlphabetic || CharacterSet.decimalDigits.contains(a),
                   !TranscriptJoiner.isCJK(a), !TranscriptJoiner.isCJK(b), CharacterSet.alphanumerics.contains(b) {
                    out += " "
                }
                out += word
            }
            return out.trimmed
        }
    }

    private func request(_ audio: Data, diarize: Bool) async throws -> [Part] {
        guard !apiKey.trimmed.isEmpty else { throw VoxletError(L10n.t("Enter your Gemini API key in Settings → Model first.")) }
        let url = URL(string: "https://aiplatform.googleapis.com/v1beta1/publishers/google/models/gemini-3.5-transcribe:generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey.trimmed, forHTTPHeaderField: "x-goog-api-key")
        var config: [String: Any] = ["word_timestamp": true, "language_codes": languageCodes]
        if diarize { config["diarization"] = true }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["inlineData": ["mimeType": "audio/mp4", "data": audio.base64EncodedString()]]]]],
            "generationConfig": ["audioTranscriptionConfig": config],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            throw VoxletError(((object["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)")
        }
        let parts = (((object["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        return parts.map { part in
            let t = part["audioTranscription"] as? [String: Any] ?? [:]
            let words = (t["words"] as? [[String: Any]] ?? []).map { w -> (String, TimeInterval, TimeInterval) in
                ((w["word"] as? String) ?? "", Self.seconds(w["startOffset"]), Self.seconds(w["endOffset"]))
            }
            return Part(speaker: t["speakerLabel"] as? String, text: (part["text"] as? String) ?? "", words: words)
        }
    }

    private static func seconds(_ value: Any?) -> TimeInterval {
        guard let s = value as? String else { return 0 }
        return TimeInterval(s.replacingOccurrences(of: "s", with: "")) ?? 0
    }
}

/// Cuts a recording into 16 kHz mono AAC pieces small enough to send inline.
enum AudioChunker {
    struct Chunk {
        let url: URL
        let offset: TimeInterval
    }

    static func chunks(of url: URL, seconds: TimeInterval) throws -> [Chunk] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return [] }
        let source = file.processingFormat
        guard let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: source, to: target)
        else { throw VoxletError("Cannot convert \(url.lastPathComponent)") }
        let framesPerChunk = AVAudioFrameCount(seconds * source.sampleRate)
        var chunks: [Chunk] = []
        var offset: TimeInterval = 0
        while file.framePosition < file.length {
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: framesPerChunk) else { break }
            try file.read(into: input, frameCount: framesPerChunk)
            if input.frameLength == 0 { break }
            let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / source.sampleRate) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }
            converter.reset()
            var fed = false
            converter.convert(to: output, error: nil) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            let chunkURL = FileManager.default.temporaryDirectory.appendingPathComponent("voxlet-chunk-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                           AVEncoderBitRateKey: 32_000]
            do {
                let out = try AVAudioFile(forWriting: chunkURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try out.write(from: output)
                if #available(macOS 15.0, *) { out.close() }
            }
            chunks.append(Chunk(url: chunkURL, offset: offset))
            offset += Double(input.frameLength) / source.sampleRate
        }
        return chunks
    }
}
