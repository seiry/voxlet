import Foundation

/// A meeting-long Gemini Live transcript of the mixed audio, with turns cut on our side. We know from the two
/// tracks who is talking, so Gemini's own activity detection is off and every turn opens and closes when the
/// speaking side changes: each final then belongs to exactly one side. Left to itself, Gemini merged several
/// speakers into one turn and dropped whole sentences (scripts/meeting-e2e.sh, 2026-10-30).
/// A Live session lasts at most 10 minutes; past `rolloverAfter` the next gap between turns hands the stream to a
/// fresh session. Callbacks arrive on the main queue.
final class MeetingLiveTranscriber {
    struct Turn {
        let side: MeetingSide
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    var onInterim: ((MeetingSide, String) -> Void)?
    var onTurn: ((Turn) -> Void)?
    var onNotice: ((String) -> Void)?

    var rolloverAfter: TimeInterval = 540
    /// Past this a session is replaced even mid-turn, before the server cuts it at 600 s.
    var forceAfter: TimeInterval = 585
    private(set) var sessionsOpened = 0
    private(set) var usage = GeminiUsage()

    private let config: GeminiLiveConfig
    private let queue = DispatchQueue(label: "voxlet.meeting-live")
    private var current: LiveConnection?
    private var draining: [LiveConnection] = []
    private var segmenter = TurnSegmenter()
    private var preroll: [Data] = []
    private var now: TimeInterval = 0
    private var reconnects: [Date] = []
    private var finishing = false
    /// Turn and session events with meeting times, for the self-test report.
    private var trace: [String] = []

    var traceSnapshot: [String] { queue.sync { trace } }

    private func log(_ event: String) {
        trace.append(String(format: "%6.1f %@", now, event))
    }

    init(config: GeminiLiveConfig) {
        var config = config
        // SMART can drop whole clauses; a meeting record wants every sentence.
        config.mode = "VERBATIM"
        // With no language given, Chinese sometimes comes back in Traditional characters.
        if config.languageCodes.isEmpty { config.languageCodes = ["zh-CN", "en-US"] }
        self.config = config
    }

    func start() throws {
        if let problem = config.validationError { throw VoxletError(problem) }
        queue.sync { open(at: 0) }
    }

    /// One 100 ms chunk of the mixed audio, with each side's level in dBFS.
    func send(_ pcm: Data, at time: TimeInterval, me: Float, them: Float) {
        queue.async { [self] in
            now = time
            guard !finishing else { return }
            preroll.append(pcm)
            if preroll.count > TurnSegmenter.prerollChunks { preroll.removeFirst() }

            if segmenter.side == nil, let connection = current, time - connection.openedAt >= rolloverAfter {
                rollover(at: time)
            } else if let connection = current, time - connection.openedAt >= forceAfter {
                if let side = segmenter.side { connection.endTurn(at: time); segmenter.restart(side) }
                rollover(at: time)
                if let side = segmenter.side { current?.beginTurn(side, at: time - 0.1) }
            }

            for event in segmenter.feed(me: me, them: them, at: time) {
                switch event {
                case .begin(let side):
                    let start = time - Double(preroll.count) * MeetingMixer.chunkSeconds
                    log("begin \(side.rawValue)")
                    current?.beginTurn(side, at: max(0, start))
                    preroll.forEach { current?.sendAudio($0) }
                    preroll.removeAll()
                case .end:
                    log("end")
                    current?.endTurn(at: time)
                }
            }
            if segmenter.side != nil, preroll.isEmpty == false {
                preroll.forEach { current?.sendAudio($0) }
                preroll.removeAll()
            }
        }
    }

    /// Closes the open turn and calls back once every session has delivered its last final.
    func finish(completion: @escaping () -> Void) {
        queue.async { [self] in
            finishing = true
            log("finish, open turn: \(segmenter.side?.rawValue ?? "none")")
            if segmenter.side != nil { current?.endTurn(at: now) }
            if let current { draining.append(current) }
            current = nil
            draining.forEach { $0.drain() }
            waitForDrain(deadline: Date().addingTimeInterval(15), completion: completion)
        }
    }

    func cancel() {
        queue.async { [self] in
            finishing = true
            current?.close()
            draining.forEach { $0.close() }
            current = nil
            draining = []
        }
    }

    private func waitForDrain(deadline: Date, completion: @escaping () -> Void) {
        draining.removeAll { $0.isClosed }
        if draining.isEmpty || Date() > deadline {
            draining.forEach { $0.close() }
            draining = []
            DispatchQueue.main.async(execute: completion)
            return
        }
        queue.asyncAfter(deadline: .now() + 0.25) { self.waitForDrain(deadline: deadline, completion: completion) }
    }

    private func rollover(at time: TimeInterval) {
        if let old = current {
            old.drain()
            draining.append(old)
        }
        draining.removeAll { $0.isClosed }
        open(at: time)
    }

    private func open(at time: TimeInterval) {
        sessionsOpened += 1
        log("open session \(sessionsOpened)")
        let connection = LiveConnection(config: config, openedAt: time, queue: queue)
        let number = sessionsOpened
        connection.log = { [weak self] event in self?.log("s\(number) \(event)") }
        connection.onInterim = { [weak self] side, text in DispatchQueue.main.async { self?.onInterim?(side, text) } }
        connection.onTurn = { [weak self] turn in DispatchQueue.main.async { self?.onTurn?(turn) } }
        connection.onUsage = { [weak self] add in
            self?.usage.audioInputTokens += add.audioInputTokens
            self?.usage.textInputTokens += add.textInputTokens
            self?.usage.outputTokens += add.outputTokens
            self?.usage.reported = true
        }
        connection.onClosed = { [weak self, weak connection] reason in
            guard let self, let connection, connection === self.current, !self.finishing else { return }
            self.reconnect(after: reason)
        }
        current = connection
        connection.start()
    }

    /// The server closed the live session (go-away, network): open a new one right away, but stop after five tries
    /// a minute so a bad key or quota does not spin.
    private func reconnect(after reason: String) {
        reconnects = reconnects.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
        guard reconnects.count <= 5 else {
            current = nil
            DispatchQueue.main.async { self.onNotice?(L10n.format("Live transcription stopped: %@", reason)) }
            return
        }
        if let old = current { draining.append(old) }
        open(at: now)
        if let side = segmenter.side { current?.beginTurn(side, at: now) }
        DispatchQueue.main.async { self.onNotice?(L10n.t("Live transcription reconnected.")) }
    }
}

/// Decides from the two sides' levels when a turn starts, ends, and whose it is. A turn stays with whoever started
/// it while the other side talks over them; the offline pass sorts out double talk.
struct TurnSegmenter {
    enum Event {
        case begin(MeetingSide)
        case end
    }

    static let activeDBFS: Float = -45
    static let prerollChunks = 6
    /// 600 ms of silence ends a turn; long monologues are cut so text keeps arriving.
    private static let endQuietChunks = 6
    private static let maxTurnChunks = 300

    private(set) var side: MeetingSide?
    private var run: [MeetingSide: Int] = [.me: 0, .them: 0]
    private var quiet = 0
    private var length = 0

    mutating func restart(_ side: MeetingSide) {
        self.side = side
        quiet = 0
        length = 0
    }

    /// Opening a turn needs more than keeping one going. The processed microphone still spikes past -45 dBFS in
    /// about 5% of 100 ms chunks while only the other side talks (runs of up to 4); each false turn gets no final
    /// and shifts every later final onto the wrong turn. The tap is a clean digital signal.
    private static let beginDBFS: [MeetingSide: Float] = [.me: -40, .them: -45]
    private static let beginChunks: [MeetingSide: Int] = [.me: 4, .them: 2]
    private var beginRun: [MeetingSide: Int] = [.me: 0, .them: 0]

    private func ready(_ side: MeetingSide) -> Bool { beginRun[side]! >= Self.beginChunks[side]! }

    mutating func feed(me: Float, them: Float, at time: TimeInterval) -> [Event] {
        run[.me] = me > Self.activeDBFS ? run[.me]! + 1 : 0
        run[.them] = them > Self.activeDBFS ? run[.them]! + 1 : 0
        beginRun[.me] = me > Self.beginDBFS[.me]! ? beginRun[.me]! + 1 : 0
        beginRun[.them] = them > Self.beginDBFS[.them]! ? beginRun[.them]! + 1 : 0
        guard let current = side else {
            let loud = [MeetingSide.me, .them].filter(ready)
            guard !loud.isEmpty else { return [] }
            let next = loud.count == 2 ? (me >= them ? MeetingSide.me : .them) : loud[0]
            restart(next)
            return [.begin(next)]
        }
        let other: MeetingSide = current == .me ? .them : .me
        quiet = run[current]! == 0 ? quiet + 1 : 0
        length += 1
        if quiet >= 2, ready(other) {
            restart(other)
            return [.end, .begin(other)]
        }
        if quiet >= Self.endQuietChunks {
            side = nil
            return [.end]
        }
        if length >= Self.maxTurnChunks {
            restart(current)
            return [.end, .begin(current)]
        }
        return []
    }
}

/// One Live WebSocket session with client-side turns; runs on the transcriber's queue.
private final class LiveConnection: NSObject, URLSessionWebSocketDelegate {
    private struct OpenTurn {
        let side: MeetingSide
        let start: TimeInterval
        var end: TimeInterval?
        var answered = false
        var completed = false
    }

    var onInterim: ((MeetingSide, String) -> Void)?
    var onTurn: ((MeetingLiveTranscriber.Turn) -> Void)?
    var onUsage: ((GeminiUsage) -> Void)?
    var onClosed: ((String) -> Void)?
    var log: ((String) -> Void)?

    let openedAt: TimeInterval
    private let config: GeminiLiveConfig
    private let queue: DispatchQueue
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var ready = false
    private var outbox: [[String: Any]] = []
    private(set) var isClosed = false
    private var draining = false
    /// Turns sent and not yet completed, oldest first. Each gets one final and one generationComplete, but a
    /// turn's generationComplete can arrive after the next turn's final, so the two are matched separately.
    private var turns: [OpenTurn] = []

    init(config: GeminiLiveConfig, openedAt: TimeInterval, queue: DispatchQueue) {
        self.config = config
        self.openedAt = openedAt
        self.queue = queue
    }

    func start() {
        guard let url = config.url else { return close(reason: "bad url") }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        var payload = config.setupPayload()
        if var setup = payload["setup"] as? [String: Any] {
            setup["realtimeInputConfig"] = ["automaticActivityDetection": ["disabled": true]]
            payload["setup"] = setup
        }
        transmit(payload)
        receive()
    }

    func beginTurn(_ side: MeetingSide, at time: TimeInterval) {
        guard !isClosed, !draining else { return }
        turns.append(OpenTurn(side: side, start: time))
        enqueue(["realtimeInput": ["activityStart": [String: Any]()]])
    }

    func endTurn(at time: TimeInterval) {
        guard !isClosed, let index = turns.lastIndex(where: { $0.end == nil }) else { return }
        turns[index].end = time
        enqueue(["realtimeInput": ["activityEnd": [String: Any]()]])
    }

    func sendAudio(_ pcm: Data) {
        guard !isClosed, !draining else { return }
        enqueue(["realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }

    /// No more turns; close once the open ones are answered, or after 12 s.
    func drain() {
        guard !isClosed, !draining else { return }
        draining = true
        log?("drain, waiting on \(turns.count) turns, \(outbox.count) queued, ready \(ready)")
        if turns.isEmpty && outbox.isEmpty { return close(reason: "drained") }
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in self?.close(reason: "drain timeout") }
    }

    func close(reason: String = "closed") {
        guard !isClosed else { return }
        isClosed = true
        log?("closed: \(reason)")
        task?.cancel(with: .normalClosure, reason: nil)
        session?.finishTasksAndInvalidate()
        onClosed?(reason)
    }

    private func enqueue(_ payload: [String: Any]) {
        if ready { transmit(payload) } else if outbox.count < 600 { outbox.append(payload) }
    }

    private func transmit(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.isClosed else { return }
                switch result {
                case .failure(let error):
                    self.close(reason: error.localizedDescription)
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
            return close(reason: (error["message"] as? String) ?? "Gemini Live error")
        }
        if object["setupComplete"] != nil || object["setup_complete"] != nil {
            guard !ready else { return }
            ready = true
            outbox.forEach(transmit)
            outbox.removeAll()
            return
        }
        if let meta = (object["usageMetadata"] ?? object["usage_metadata"]) as? [String: Any] {
            var usage = GeminiUsage(reported: true)
            for detail in (meta["promptTokensDetails"] as? [[String: Any]]) ?? [] {
                let count = (detail["tokenCount"] as? Int) ?? 0
                if (detail["modality"] as? String) == "AUDIO" { usage.audioInputTokens += count } else { usage.textInputTokens += count }
            }
            usage.outputTokens = (meta["candidatesTokenCount"] as? Int) ?? (meta["responseTokenCount"] as? Int) ?? 0
            onUsage?(usage)
        }
        if object["goAway"] != nil || object["go_away"] != nil {
            if !draining { close(reason: "go-away") }
            return
        }
        guard let content = (object["serverContent"] ?? object["server_content"]) as? [String: Any] else { return }
        if let final = Self.text(in: content, "inputTranscription", "input_transcription") {
            // The oldest turn still waiting for its text, preferring one that has already ended.
            if let index = turns.firstIndex(where: { !$0.answered && $0.end != nil }) ?? turns.firstIndex(where: { !$0.answered }) {
                turns[index].answered = true
                let turn = turns[index]
                log?("final for turn \(index) (\(turn.side.rawValue)): \(final.prefix(16))")
                onTurn?(.init(side: turn.side, text: final, start: turn.start, end: turn.end ?? turn.start))
                onInterim?(turn.side, "")
            }
        } else if let partial = Self.text(in: content, "interimInputTranscription", "interim_input_transcription"),
                  let turn = turns.first(where: { !$0.answered }) {
            onInterim?(turn.side, partial)
        }
        if (content["generationComplete"] as? Bool) == true || (content["generation_complete"] as? Bool) == true {
            log?("complete, \(turns.count) turns open")
            if let index = turns.firstIndex(where: { !$0.completed && $0.end != nil }) { turns[index].completed = true }
            // A completed turn with no text was silence or noise; it must not take the next turn's final.
            turns.removeAll { $0.completed && ($0.answered || $0.end != nil) }
            if draining, turns.isEmpty { close(reason: "drained") }
        }
    }

    private static func text(in object: [String: Any], _ camel: String, _ snake: String) -> String? {
        guard let container = (object[camel] ?? object[snake]) as? [String: Any],
              let text = (container["text"] as? String)?.trimmed, !text.isEmpty
        else { return nil }
        return text
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let detail = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        queue.async { self.close(reason: "\(closeCode.rawValue) \(detail)".trimmed) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        queue.async { self.close(reason: error.localizedDescription) }
    }
}
