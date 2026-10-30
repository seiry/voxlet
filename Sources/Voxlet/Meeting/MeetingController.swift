import AppKit
import Combine

/// One meeting at a time: both sides recorded to disk, one mixed Live stream labelled "me"/"them" by level,
/// running notes from the gateway model, then an offline pass with speaker names. Observed by the panel on main.
final class MeetingController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case paused
        case finishing(step: Int)
    }

    struct QA: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
    }

    static let finishSteps = [
        "Transcribing again offline", "Telling speakers apart", "Writing the notes", "Saving to the meetings folder",
    ]

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lines: [MeetingLine] = []
    @Published private(set) var interim = ""
    @Published private(set) var interimSide = MeetingSide.them
    @Published private(set) var notes = MeetingNotes()
    @Published private(set) var notesUpdatedAt: TimeInterval?
    @Published private(set) var notesVersion = 0
    @Published private(set) var questions: [QA] = []
    @Published private(set) var voiceProcessing = false
    @Published private(set) var browserHeard = false
    @Published private(set) var notice: String?
    @Published private(set) var title = ""
    @Published private(set) var folder: URL?

    /// Called on main with the finished record (folder, record) or an error.
    var onFinished: ((URL, MeetingRecord) -> Void)?
    var onError: ((String) -> Void)?

    var isActive: Bool { state != .idle }

    private let pipeline = DispatchQueue(label: "voxlet.meeting-pipeline", qos: .userInitiated)
    private var mic: MeetingAudioSource?
    private var browser: MeetingAudioSource?
    private var micTrack: MeetingTrack?
    private var browserTrack: MeetingTrack?
    private var mixer: MeetingMixer?
    private var live: MeetingLiveTranscriber?
    /// The last meeting's Live turn and session events, for the self-test report.
    private(set) var lastLiveTrace: [String] = []
    private var ticker: Timer?
    private var startedAt = Date()
    private var notesCursor = 0
    private var notesTask: Task<Void, Never>?
    private var lastNotesAt: TimeInterval = 0
    private var lastBrowserAudio = Date.distantPast
    private var paused = false

    var notesInterval: TimeInterval {
        Double(ProcessInfo.processInfo.environment["VOXLET_MEETING_NOTES_INTERVAL"] ?? "") ?? 150
    }

    // MARK: - Lifecycle

    /// Starts with the real microphone and browser tap.
    func start() {
        guard state == .idle else { return }
        guard Permissions.isGranted(.microphone) else {
            Permissions.request(.microphone)
            onError?(L10n.t("Microphone access is needed. Grant it, then try again."))
            return
        }
        guard #available(macOS 26.0, *) else {
            onError?(L10n.t("Meeting mode needs macOS 26 or later."))
            return
        }
        let useVoiceProcessing: Bool
        switch Prefs.string(Prefs.meetingEchoCancellation) {
        case "on": useVoiceProcessing = true
        case "off": useVoiceProcessing = false
        default: useVoiceProcessing = !OutputRoute.isHeadphones
        }
        let browsers = Prefs.meetingBrowserBundleIDs
        do {
            try start(mic: MicrophoneSource(voiceProcessing: useVoiceProcessing), browser: BrowserSource(bundleIDs: browsers),
                      title: MeetingTitle.guess(bundleIDs: browsers), voiceProcessing: useVoiceProcessing)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    /// The seam the self-test uses to feed files instead of devices.
    func start(mic: MeetingAudioSource, browser: MeetingAudioSource, title: String, voiceProcessing: Bool,
               rolloverAfter: TimeInterval? = nil) throws {
        let config = Prefs.liveConfig()
        if let problem = config.validationError { throw VoxletError(problem) }
        startedAt = Date()
        let folder = try MeetingStore.newFolder(title: title, date: startedAt)
        let micTrack = try MeetingTrack(side: .me, url: folder.appendingPathComponent("audio/mic.m4a"), sampleRate: mic.sampleRate, queue: pipeline)
        let mixer = MeetingMixer(queue: pipeline)
        let live = MeetingLiveTranscriber(config: config)
        if let rolloverAfter {
            live.rolloverAfter = rolloverAfter
            live.forceAfter = rolloverAfter + 45
        }
        live.onInterim = { [weak self] side, text in
            self?.interimSide = side
            self?.interim = text
        }
        live.onTurn = { [weak self] turn in
            self?.lines.append(MeetingLine(side: turn.side, text: turn.text, start: turn.start, end: turn.end))
        }
        live.onNotice = { [weak self] message in self?.notice = message }
        micTrack.onPCM16 = { [weak mixer] pcm in mixer?.push(pcm, side: .me) }
        mixer.onChunk = { [weak live] pcm, time, me, them in live?.send(pcm, at: time, me: me, them: them) }
        mic.onSamples = { [weak self, weak micTrack] samples in
            guard self?.paused == false else { return }
            micTrack?.append(samples)
        }

        try mic.start()
        do {
            try live.start()
        } catch {
            mic.stop()
            throw error
        }
        // The browser side is optional: without System Audio Recording the meeting still runs on the mic.
        var browserTrack: MeetingTrack?
        do {
            try browser.start()
            let track = try MeetingTrack(side: .them, url: folder.appendingPathComponent("audio/browser.m4a"),
                                         sampleRate: browser.sampleRate, queue: pipeline)
            track.onPCM16 = { [weak mixer] pcm in mixer?.push(pcm, side: .them) }
            browser.onSamples = { [weak self, weak track] samples in
                guard self?.paused == false else { return }
                track?.append(samples)
                self?.lastBrowserAudio = Date()
            }
            browserTrack = track
        } catch {
            notice = L10n.format("Browser audio is not being recorded: %@", error.localizedDescription)
        }
        mixer.start()

        self.mic = mic
        self.browser = browser
        self.micTrack = micTrack
        self.browserTrack = browserTrack
        self.mixer = mixer
        self.live = live
        self.folder = folder
        self.title = title
        self.voiceProcessing = voiceProcessing
        lines = []
        interim = ""
        notes = MeetingNotes()
        notesUpdatedAt = nil
        notesVersion = 0
        notesCursor = 0
        lastNotesAt = 0
        questions = []
        elapsed = 0
        paused = false
        state = .recording
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func togglePause() {
        switch state {
        case .recording:
            paused = true
            pipeline.async { self.mixer?.isPaused = true }
            state = .paused
        case .paused:
            paused = false
            pipeline.async { self.mixer?.isPaused = false }
            state = .recording
        default:
            break
        }
    }

    /// Marks the latest finished line; while someone is mid-sentence, the line about to finish.
    func star() {
        guard isActive, !lines.isEmpty else { return }
        lines[lines.count - 1].starred = true
    }

    func ask(_ question: String) {
        let q = question.trimmed
        guard !q.isEmpty else { return }
        let entry = QA(question: q)
        questions.append(entry)
        let prompt = MeetingPrompts.answer(question: q, lines: lines, startedAt: startedAt)
        Task { [weak self] in
            let answer: String
            do {
                answer = try await MeetingGateway.current.generate(prompt, json: false).trimmed
            } catch {
                answer = L10n.format("Could not answer: %@", error.localizedDescription)
            }
            await MainActor.run {
                guard let self, let index = self.questions.firstIndex(where: { $0.id == entry.id }) else { return }
                self.questions[index].answer = answer
            }
        }
    }

    func end() {
        guard state == .recording || state == .paused else { return }
        ticker?.invalidate()
        ticker = nil
        notesTask?.cancel()
        paused = true
        mic?.stop()
        browser?.stop()
        state = .finishing(step: 0)
        let live = self.live
        // Let the pipeline flush what the devices delivered last, then end the Live stream.
        pipeline.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.mixer?.stop()
            self.micTrack?.close()
            self.browserTrack?.close()
            DispatchQueue.main.async {
                guard let live else { return self.finalize() }
                live.finish { [weak self] in self?.finalize() }
            }
        }
    }

    // MARK: - Live

    private func tick() {
        guard state == .recording || state == .paused else { return }
        pipeline.async { [weak self] in
            guard let self, let mixer = self.mixer else { return }
            let now = mixer.now
            DispatchQueue.main.async { self.elapsed = now }
        }
        browserHeard = Date().timeIntervalSince(lastBrowserAudio) < 3
        if notesTask == nil, elapsed - lastNotesAt >= notesInterval, lines.count > notesCursor {
            refreshNotes()
        }
    }

    private func refreshNotes() {
        let gateway = MeetingGateway.current
        guard gateway.isConfigured else { return }
        let fresh = Array(lines[notesCursor...])
        let previous = notes
        let cursor = lines.count
        lastNotesAt = elapsed
        notesTask = Task { [weak self] in
            let updated = try? await gateway.generateJSON(MeetingPrompts.runningNotes(previous: previous, newLines: fresh), as: MeetingNotes.self)
            await MainActor.run {
                guard let self else { return }
                self.notesTask = nil
                guard let updated, !updated.isEmpty else { return }
                self.notes = updated
                self.notesCursor = cursor
                self.notesUpdatedAt = self.elapsed
                self.notesVersion += 1
                self.saveLiveRecord()
            }
        }
    }

    private var liveRecord: MeetingRecord {
        var record = MeetingRecord(title: title, startedAt: startedAt, duration: elapsed)
        record.lines = lines
        record.notes = notes
        record.liveSessions = live?.sessionsOpened ?? 0
        record.speakers = ["me": L10n.t("Me")]
        return record
    }

    /// The live transcript on disk as it grows, so a crash still leaves a record behind.
    private func saveLiveRecord() {
        guard let folder else { return }
        try? MeetingStore.save(liveRecord, in: folder)
    }

    // MARK: - Finish

    private func finalize() {
        guard let folder else { return reset() }
        lastLiveTrace = live?.traceSnapshot ?? []
        if let usage = live?.usage {
            UsageStore.shared.add(UsageRecord(date: Date(), audioSeconds: elapsed, usage: usage,
                                              characters: lines.reduce(0) { $0 + $1.text.count }))
        }
        var record = liveRecord
        saveLiveRecord()
        let micURL = micTrack?.url
        let browserURL = browserTrack?.url
        let gateway = MeetingGateway.current
        Task { [weak self] in
            let offline = MeetingOfflineTranscriber.current
            do {
                func run(_ url: URL?, label: String?, diarize: Bool) async throws -> [MeetingSegment] {
                    guard let url else { return [] }
                    return try await offline.transcribe(url, label: label, diarize: diarize)
                }
                async let mine = run(micURL, label: "me", diarize: false)
                async let theirs = run(browserURL, label: nil, diarize: true)
                let (a, b) = try await (mine, theirs)
                await MainActor.run { self?.state = .finishing(step: 1) }
                record.segments = (a + b).sorted { $0.start < $1.start }
            } catch {
                record.offlineError = error.localizedDescription
            }
            await MainActor.run { self?.state = .finishing(step: 2) }
            if !record.segments.isEmpty, gateway.isConfigured,
               let writeUp = try? await gateway.generateJSON(MeetingPrompts.writeUp(record: record), as: MeetingPrompts.WriteUp.self) {
                if let notes = writeUp.notes, !notes.isEmpty { record.notes = notes }
                for (label, name) in writeUp.speakers ?? [:] where label != "me" && !name.trimmed.isEmpty {
                    record.speakers[label] = name.trimmed
                }
                if let title = writeUp.title?.trimmed, !title.isEmpty, record.title == L10n.t("Meeting") { record.title = title }
            }
            var unnamed = 0
            for label in record.speakerOrder where record.speakers[label] == nil {
                unnamed += 1
                record.speakers[label] = L10n.format("Speaker %d", unnamed)
            }
            await MainActor.run { self?.state = .finishing(step: 3) }
            try? MeetingStore.save(record, in: folder)
            await MainActor.run {
                guard let self else { return }
                self.onFinished?(folder, record)
                self.reset()
            }
        }
    }

    private func reset() {
        mic = nil
        browser = nil
        micTrack = nil
        browserTrack = nil
        mixer = nil
        live = nil
        state = .idle
        notice = nil
    }
}

/// The meeting's name from the browser window, e.g. "Meet - Weekly sync"; read through Accessibility.
enum MeetingTitle {
    static func guess(bundleIDs: [String]) -> String {
        guard AXIsProcessTrusted() else { return L10n.t("Meeting") }
        for app in NSWorkspace.shared.runningApplications where bundleIDs.contains(app.bundleIdentifier ?? "") {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows {
                var title: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                      let text = title as? String, let name = meetName(in: text) else { continue }
                return name
            }
        }
        return L10n.t("Meeting")
    }

    /// "Meet - abc-defg-hij — Mozilla Firefox" → "abc-defg-hij"; also "Weekly sync - Google Meet".
    static func meetName(in windowTitle: String) -> String? {
        var t = windowTitle
        for suffix in [" — Mozilla Firefox", " - Mozilla Firefox", " — Firefox Developer Edition", " - Google Chrome", " - Microsoft Edge"] {
            if let r = t.range(of: suffix) { t = String(t[..<r.lowerBound]) }
        }
        if t.hasPrefix("Meet - ") || t.hasPrefix("Meet – ") { return String(t.dropFirst(7)).trimmed.nilIfEmpty }
        if let r = t.range(of: " - Google Meet") { return String(t[..<r.lowerBound]).trimmed.nilIfEmpty }
        return nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension MeetingController {
    /// Sample state for `--render-previews`.
    func loadPreview(state: State, lines: [MeetingLine], interim: (MeetingSide, String)?, notes: MeetingNotes, elapsed: TimeInterval,
                     questions: [(String, String?)] = []) {
        self.state = state
        self.lines = lines
        self.interimSide = interim?.0 ?? .them
        self.interim = interim?.1 ?? ""
        self.notes = notes
        self.notesUpdatedAt = notes.isEmpty ? nil : elapsed - 40
        self.notesVersion = notes.isEmpty ? 0 : 2
        self.elapsed = elapsed
        self.voiceProcessing = true
        self.browserHeard = true
        self.questions = questions.map { QA(question: $0.0, answer: $0.1) }
    }
}
