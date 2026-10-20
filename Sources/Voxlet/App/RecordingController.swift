import AppKit

/// Owns one dictation at a time: mic → Gemini Live → paste, with the overlay reflecting each step.
final class RecordingController: ObservableObject {
    enum State {
        case idle
        case recording
        case finishing
    }

    /// Voxt waits this long after the key is released so the last syllable reaches the tap.
    private static let stopDrainDelay: TimeInterval = 0.18
    private static let errorStatusDuration: TimeInterval = 4

    @Published private(set) var state: State = .idle

    let overlay = OverlayWindowController()
    private let capture = AudioCapture()
    private var session: GeminiLiveSession?
    private var targetApp: NSRunningApplication?

    var isRecording: Bool { state == .recording }

    func toggle() {
        switch state {
        case .idle: start()
        case .recording: stop()
        case .finishing: break
        }
    }

    func start() {
        guard state == .idle else { return }
        let config = Prefs.liveConfig()
        if let problem = config.validationError {
            overlay.showStatus(problem, hideAfter: Self.errorStatusDuration)
            return
        }
        guard Permissions.isGranted(.microphone) else {
            overlay.showStatus(L10n.t("Microphone access is needed. Grant it, then try again."), hideAfter: Self.errorStatusDuration)
            Permissions.request(.microphone)
            return
        }

        targetApp = NSWorkspace.shared.frontmostApplication
        let session = GeminiLiveSession(config: config)
        session.onTranscript = { [weak self] text in self?.overlay.updateTranscript(text) }
        session.onFailure = { [weak self] error in self?.handleRuntimeFailure(error) }
        capture.onPCM = { [weak session] pcm in session?.sendAudio(pcm) }
        capture.onLevel = { [weak self] level in self?.overlay.updateLevel(level) }

        do {
            try session.start()
            try capture.start(deviceUID: Prefs.string(Prefs.inputDeviceUID))
        } catch {
            session.cancel()
            capture.stop()
            overlay.showStatus(error.localizedDescription, hideAfter: Self.errorStatusDuration)
            return
        }

        self.session = session
        setState(.recording)
        overlay.showRecording()
        Sounds.play()
    }

    func stop() {
        guard state == .recording, let session else { return }
        setState(.finishing)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopDrainDelay) { [weak self] in
            guard let self else { return }
            self.capture.stop()
            self.overlay.showProcessing()
            Sounds.play()
            session.finish { [weak self] result in self?.handleFinish(result) }
        }
    }

    func cancel() {
        guard state != .idle else { return }
        capture.stop()
        session?.cancel()
        session = nil
        setState(.idle)
        overlay.hide()
    }

    private func handleFinish(_ result: Result<GeminiLiveResult, Error>) {
        session = nil
        setState(.idle)
        switch result {
        case .success(let output):
            UsageStore.shared.add(UsageRecord(
                date: Date(),
                audioSeconds: output.audioSeconds,
                usage: output.usage,
                characters: output.text.count
            ))
            guard !output.text.isEmpty else {
                overlay.showStatus(L10n.t("No speech recognized."))
                return
            }
            overlay.hide()
            if TextInserter.insert(output.text, target: targetApp) == .copiedOnly {
                overlay.showStatus(L10n.t("Copied to clipboard. Grant Accessibility to paste automatically."), hideAfter: Self.errorStatusDuration)
            }
        case .failure(let error):
            overlay.showStatus(error.localizedDescription, hideAfter: Self.errorStatusDuration)
        }
    }

    private func handleRuntimeFailure(_ error: Error) {
        guard state != .idle else { return }
        capture.stop()
        session = nil
        setState(.idle)
        overlay.showStatus(error.localizedDescription, hideAfter: Self.errorStatusDuration)
    }

    private func setState(_ next: State) {
        state = next
        HotkeyManager.shared.recordingDidChange(next == .recording)
    }
}

enum Sounds {
    /// The same soft cue for start and stop.
    static func play() {
        guard Prefs.bool(Prefs.interactionSounds) else { return }
        NSSound(named: NSSound.Name("Pop"))?.play()
    }
}
