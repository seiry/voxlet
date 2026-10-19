import Foundation

struct GeminiUsage: Codable, Equatable {
    var audioInputTokens = 0
    var textInputTokens = 0
    var outputTokens = 0
    /// False when the server sent no usageMetadata and the numbers are estimated from audio length.
    var reported = false

    var totalTokens: Int { audioInputTokens + textInputTokens + outputTokens }
}

struct GeminiLiveResult {
    var text: String
    var usage: GeminiUsage
    var audioSeconds: Double
    var finishReason: String
}

struct VoxletError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One push-to-talk utterance over the Gemini Live WebSocket. Callbacks arrive on the main queue.
final class GeminiLiveSession: NSObject, URLSessionWebSocketDelegate {
    static let finishIdleGrace: TimeInterval = 1.5
    static let turnEndGrace: TimeInterval = 0.6
    static let finishHardCap: TimeInterval = 10
    private static let maxPendingBytes = 1_024_000
    private static let bytesPerSecond = 32_000.0

    var onSetupComplete: (() -> Void)?
    var onTranscript: ((String) -> Void)?
    /// A failure while still recording, before finish() was called.
    var onFailure: ((Error) -> Void)?
    /// Raw usageMetadata objects, for the self-test log.
    var onRawUsage: (([String: Any]) -> Void)?

    private let config: GeminiLiveConfig
    private let queue = DispatchQueue(label: "voxlet.gemini-live")
    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?

    private var isSetupComplete = false
    private var isClosed = false
    private var pending = Data()
    private var sentBytes = 0
    private var committed: [String] = []
    private var interim = ""
    private var usage = GeminiUsage()

    private var finishRequested = false
    private var didSendStreamEnd = false
    private var finishCompletion: ((Result<GeminiLiveResult, Error>) -> Void)?
    private var idleTimer: DispatchWorkItem?
    private var capTimer: DispatchWorkItem?

    init(config: GeminiLiveConfig) {
        self.config = config
    }

    func start() throws {
        if let problem = config.validationError { throw VoxletError(problem) }
        guard let url = config.url else { throw VoxletError(L10n.t("The endpoint URL is invalid.")) }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        let task = session.webSocketTask(with: request)
        urlSession = session
        self.task = task
        task.resume()
        send(config.setupPayload())
        receive()
    }

    func sendAudio(_ pcm: Data) {
        queue.async { [self] in
            guard !isClosed, !didSendStreamEnd else { return }
            if isSetupComplete {
                sendChunk(pcm)
            } else if pending.count + pcm.count <= Self.maxPendingBytes {
                pending.append(pcm)
            }
        }
    }

    func finish(completion: @escaping (Result<GeminiLiveResult, Error>) -> Void) {
        queue.async { [self] in
            finishCompletion = completion
            finishRequested = true
            if isClosed {
                complete(reason: "closed-before-finish")
                return
            }
            scheduleCap()
            if isSetupComplete { sendStreamEnd() }
        }
    }

    func cancel() {
        queue.async { [self] in
            finishCompletion = nil
            onTranscript = nil
            onFailure = nil
            teardown()
        }
    }

    // MARK: - Protocol

    private func sendChunk(_ pcm: Data) {
        sentBytes += pcm.count
        send([
            "realtimeInput": [
                "audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"],
            ],
        ])
    }

    private func sendStreamEnd() {
        guard !didSendStreamEnd else { return }
        didSendStreamEnd = true
        send(["realtimeInput": ["audioStreamEnd": true]])
        resetIdleTimer()
    }

    private func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.isClosed else { return }
                switch result {
                case .failure:
                    // The delegate's didClose carries the server's reason; give it a moment to land first.
                    self.queue.asyncAfter(deadline: .now() + 0.3) { self.handleClose(code: nil, reason: nil) }
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(text)
                    case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receive()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? (error["status"] as? String) ?? "Gemini Live error"
            fail(VoxletError(message))
            return
        }

        if object["setupComplete"] != nil || object["setup_complete"] != nil {
            guard !isSetupComplete else { return }
            isSetupComplete = true
            if !pending.isEmpty {
                sendChunk(pending)
                pending.removeAll()
            }
            DispatchQueue.main.async { self.onSetupComplete?() }
            if finishRequested { sendStreamEnd() }
            return
        }

        if let meta = (object["usageMetadata"] ?? object["usage_metadata"]) as? [String: Any] {
            applyUsage(meta)
        }

        let goingAway = object["goAway"] != nil || object["go_away"] != nil
        var turnEnded = false
        var gotText = false
        if let content = (object["serverContent"] ?? object["server_content"]) as? [String: Any] {
            // Interim text is the running transcript of the current turn; the final replaces it.
            if let final = Self.text(in: content, "inputTranscription", "input_transcription") {
                committed.append(final)
                interim = ""
                gotText = true
                publishTranscript()
            } else if let partial = Self.text(in: content, "interimInputTranscription", "interim_input_transcription") {
                interim = partial
                gotText = true
                publishTranscript()
            }
            let flags = ["turnComplete", "turn_complete", "generationComplete", "generation_complete"]
            turnEnded = flags.contains { (content[$0] as? Bool) == true }
        }

        guard didSendStreamEnd else { return }
        if goingAway {
            complete(reason: "go-away")
        } else if turnEnded {
            // A turn ends on every pause, and an earlier turn can finish after our audioStreamEnd, so give the
            // next turn a moment to show up before treating this as the end.
            resetIdleTimer(after: Self.turnEndGrace, reason: "turn-complete")
        } else if gotText {
            // Usage-only messages trail each turn; they must not stretch the shorter turn-end grace.
            resetIdleTimer()
        }
    }

    private func applyUsage(_ meta: [String: Any]) {
        DispatchQueue.main.async { self.onRawUsage?(meta) }
        var next = GeminiUsage(reported: true)
        for detail in (meta["promptTokensDetails"] as? [[String: Any]]) ?? [] {
            let count = (detail["tokenCount"] as? Int) ?? 0
            if (detail["modality"] as? String) == "AUDIO" {
                next.audioInputTokens += count
            } else {
                next.textInputTokens += count
            }
        }
        if next.audioInputTokens + next.textInputTokens == 0 {
            next.audioInputTokens = (meta["promptTokenCount"] as? Int) ?? 0
        }
        next.outputTokens = (meta["candidatesTokenCount"] as? Int) ?? (meta["responseTokenCount"] as? Int) ?? 0
        // Each message reports one turn, so a session with pauses is the sum of them.
        usage.audioInputTokens += next.audioInputTokens
        usage.textInputTokens += next.textInputTokens
        usage.outputTokens += next.outputTokens
        usage.reported = true
    }

    private func publishTranscript() {
        let merged = mergedText
        DispatchQueue.main.async { self.onTranscript?(merged) }
    }

    private var mergedText: String {
        TranscriptJoiner.join(committed + [interim])
    }

    // MARK: - Finish and close

    private func resetIdleTimer(after delay: TimeInterval = GeminiLiveSession.finishIdleGrace, reason: String = "idle-grace") {
        idleTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.complete(reason: reason) }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleCap() {
        let item = DispatchWorkItem { [weak self] in self?.complete(reason: "hard-cap") }
        capTimer = item
        queue.asyncAfter(deadline: .now() + Self.finishHardCap, execute: item)
    }

    fileprivate func handleClose(code: Int?, reason: String?) {
        guard !isClosed else { return }
        if finishRequested {
            if mergedText.isEmpty, let code, code != 1000 {
                fail(Self.closeError(code: code, reason: reason))
            } else {
                complete(reason: "socket-closed")
            }
        } else {
            fail(Self.closeError(code: code, reason: reason))
        }
    }

    private func complete(reason: String) {
        guard let completion = finishCompletion else {
            teardown()
            return
        }
        finishCompletion = nil
        var finalUsage = usage
        let seconds = Double(sentBytes) / Self.bytesPerSecond
        let text = mergedText
        if !finalUsage.reported {
            finalUsage.audioInputTokens = Int((seconds * 25).rounded())
            finalUsage.outputTokens = TokenEstimate.textTokens(text)
        }
        let result = GeminiLiveResult(text: text, usage: finalUsage, audioSeconds: seconds, finishReason: reason)
        teardown()
        DispatchQueue.main.async { completion(.success(result)) }
    }

    private func fail(_ error: Error) {
        let completion = finishCompletion
        let failure = onFailure
        finishCompletion = nil
        teardown()
        DispatchQueue.main.async {
            if let completion {
                completion(.failure(error))
            } else {
                failure?(error)
            }
        }
    }

    private func teardown() {
        guard !isClosed else { return }
        isClosed = true
        idleTimer?.cancel()
        capTimer?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        urlSession?.finishTasksAndInvalidate()
    }

    private static func closeError(code: Int?, reason: String?) -> VoxletError {
        let detail = reason?.trimmed ?? ""
        if let code, !detail.isEmpty { return VoxletError("\(code): \(detail)") }
        if let code { return VoxletError(L10n.format("Connection closed by server (code %d).", code)) }
        return VoxletError(L10n.t("Connection lost. Check your network or proxy."))
    }

    private static func text(in object: [String: Any], _ camel: String, _ snake: String) -> String? {
        guard let container = (object[camel] ?? object[snake]) as? [String: Any],
              let text = (container["text"] as? String)?.trimmed,
              !text.isEmpty
        else { return nil }
        return text
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let text = reason.map { String(decoding: $0, as: UTF8.self) }
        queue.async { self.handleClose(code: closeCode.rawValue, reason: text) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        queue.asyncAfter(deadline: .now() + 0.3) {
            guard !self.isClosed else { return }
            if self.finishRequested {
                self.handleClose(code: nil, reason: nil)
            } else {
                self.fail(VoxletError(L10n.format("Network error: %@", error.localizedDescription)))
            }
        }
    }
}

enum TokenEstimate {
    /// Rough fallback when the server reports no usage: CJK ~1 token per character, Latin ~4 characters per token.
    static func textTokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if TranscriptJoiner.isCJK(scalar) { cjk += 1 } else { other += 1 }
        }
        return cjk + (other + 3) / 4
    }
}
