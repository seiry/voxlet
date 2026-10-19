import AppKit
import Carbon.HIToolbox

/// Global shortcut routing over a session-level CGEventTap, which needs only Accessibility (as in Voxt).
/// The tap thread decides synchronously whether to swallow a key; the state machine runs on the main thread.
final class HotkeyManager {
    static let shared = HotkeyManager()
    /// Stamped on keystrokes Voxlet posts itself so the tap lets them through untouched.
    static let injectedMarker: Int64 = 0x564F_584C

    private static let longPressDelay: TimeInterval = 0.08
    private static let tapStopGuard: TimeInterval = 0.35
    private static let modifierTapMaxDuration: TimeInterval = 0.6

    struct KeyEvent {
        enum Kind { case keyDown, keyUp, flagsChanged }
        let kind: Kind
        let keyCode: UInt16
        let modifiers: SidedModifiers
        let isRepeat: Bool
    }

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var isRecording: () -> Bool = { false }
    /// While set, key events go to the shortcut recorder instead of the router.
    var captureHandler: ((KeyEvent) -> Void)? {
        didSet { lock.withLock { tapCapturing = captureHandler != nil } }
    }

    private(set) var isTapInstalled = false

    // Read on the tap thread, guarded by `lock`.
    private let lock = NSLock()
    private var tapHotkey = Hotkey.defaultHotkey
    private var tapCapturing = false
    private var tapRecording = false
    private var tapFunctionDown = false
    private var tapSwallowedKeyCodes = Set<UInt16>()

    // Main-thread state machine.
    private var hotkey = Hotkey.defaultHotkey
    private var behavior = HotkeyBehavior.longPress
    private var modifierMatched = false
    private var candidateStartedAt: Date?
    private var candidateCancelled = false
    private var holdStarted = false
    private var pendingStart: DispatchWorkItem?
    private var recordingStartedAt: Date?

    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var retryTimer: Timer?

    private init() {}

    func reloadConfig() {
        let nextHotkey = Hotkey.load()
        let nextBehavior = HotkeyBehavior(rawValue: Prefs.string(Prefs.hotkeyBehavior)) ?? .longPress
        // Unrelated defaults writes land here too; resetting mid-hold would strand a recording.
        guard nextHotkey != hotkey || nextBehavior != behavior else { return }
        hotkey = nextHotkey
        behavior = nextBehavior
        lock.withLock { tapHotkey = nextHotkey }
        resetTransientState()
    }

    func recordingDidChange(_ recording: Bool) {
        lock.withLock { tapRecording = recording }
        recordingStartedAt = recording ? Date() : nil
        if !recording { holdStarted = false }
    }

    // MARK: - Tap installation

    func install() {
        reloadConfig()
        guard tap == nil else { return }
        if !installTap() {
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                if self.installTap() { timer.invalidate() }
            }
        }
    }

    private func installTap() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleTapEvent(type: type, event: event)
            },
            userInfo: refcon
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            self?.tapRunLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "voxlet.hotkey-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        isTapInstalled = true
        return true
    }

    // MARK: - Tap thread

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.injectedMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        var swallow = false
        let keyEvent: KeyEvent

        lock.lock()
        switch type {
        case .flagsChanged:
            // Arrow and F-keys also carry the Fn flag, so Fn state comes only from the Fn key itself.
            if keyCode == UInt16(kVK_Function) {
                tapFunctionDown = event.flags.contains(.maskSecondaryFn)
            }
            keyEvent = KeyEvent(
                kind: .flagsChanged, keyCode: keyCode,
                modifiers: SidedModifiers(cgFlags: event.flags, function: tapFunctionDown), isRepeat: false
            )
        case .keyDown, .keyUp:
            let modifiers = SidedModifiers(cgFlags: event.flags, function: tapFunctionDown)
            keyEvent = KeyEvent(kind: type == .keyDown ? .keyDown : .keyUp, keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat)
            if tapCapturing {
                swallow = true
            } else if type == .keyDown {
                if keyCode == UInt16(kVK_Escape), tapRecording {
                    swallow = true
                } else if let hotkeyCode = tapHotkey.keyCode, hotkeyCode == keyCode,
                          Self.chordMatches(tapHotkey, modifiers) {
                    swallow = true
                    tapSwallowedKeyCodes.insert(keyCode)
                }
            } else if tapSwallowedKeyCodes.remove(keyCode) != nil {
                swallow = true
            }
        default:
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }
        lock.unlock()

        DispatchQueue.main.async { [weak self] in self?.route(keyEvent) }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    private static func chordMatches(_ hotkey: Hotkey, _ modifiers: SidedModifiers) -> Bool {
        let wanted = hotkey.modifiers.unsided
        var actual = modifiers.unsided
        if !wanted.contains(.function) {
            actual.remove(.function)
        }
        return wanted == actual
    }

    // MARK: - Main-thread routing

    private func route(_ event: KeyEvent) {
        if let captureHandler {
            captureHandler(event)
            return
        }
        if event.kind == .keyDown, event.keyCode == UInt16(kVK_Escape), isRecording() {
            cancelPendingStart()
            onCancel?()
            return
        }
        if hotkey.isModifierOnly {
            routeModifierOnly(event)
        } else {
            routeChord(event)
        }
    }

    private func routeModifierOnly(_ event: KeyEvent) {
        switch event.kind {
        case .flagsChanged:
            let matched = event.modifiers == hotkey.modifiers
            // fn → fn+⇧ is a different combo being built, not a release of fn.
            let widened = !matched && event.modifiers.isSuperset(of: hotkey.modifiers)
            if matched && !modifierMatched {
                candidateStartedAt = Date()
                candidateCancelled = false
                if behavior == .longPress { schedulePendingStart() }
                modifierMatched = true
            } else if widened && modifierMatched {
                candidateCancelled = true
                if behavior == .longPress, !holdStarted { cancelPendingStart() }
            } else if !matched && !widened && modifierMatched {
                releaseModifierCandidate()
                modifierMatched = false
            }
        case .keyDown:
            // fn+A must not trigger a bare fn binding.
            guard modifierMatched else { return }
            candidateCancelled = true
            if behavior == .longPress, !holdStarted { cancelPendingStart() }
        case .keyUp:
            break
        }
    }

    private func releaseModifierCandidate() {
        defer { candidateStartedAt = nil }
        switch behavior {
        case .longPress:
            if holdStarted {
                holdStarted = false
                onStop?()
            } else {
                cancelPendingStart()
            }
        case .tap:
            guard !candidateCancelled, let startedAt = candidateStartedAt,
                  Date().timeIntervalSince(startedAt) <= Self.modifierTapMaxDuration
            else { return }
            toggle()
        }
    }

    private func routeChord(_ event: KeyEvent) {
        guard let keyCode = hotkey.keyCode, event.keyCode == keyCode else { return }
        switch event.kind {
        case .keyDown:
            guard !event.isRepeat, Self.chordMatches(hotkey, event.modifiers) else { return }
            switch behavior {
            case .longPress: schedulePendingStart()
            case .tap: toggle()
            }
        case .keyUp:
            guard behavior == .longPress else { return }
            if holdStarted {
                holdStarted = false
                onStop?()
            } else {
                cancelPendingStart()
            }
        case .flagsChanged:
            break
        }
    }

    private func toggle() {
        if isRecording() {
            if let startedAt = recordingStartedAt, Date().timeIntervalSince(startedAt) < Self.tapStopGuard { return }
            onStop?()
        } else {
            onStart?()
        }
    }

    private func schedulePendingStart() {
        cancelPendingStart()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingStart = nil
            guard !self.isRecording() else { return }
            self.holdStarted = true
            self.onStart?()
        }
        pendingStart = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressDelay, execute: item)
    }

    private func cancelPendingStart() {
        pendingStart?.cancel()
        pendingStart = nil
    }

    private func resetTransientState() {
        cancelPendingStart()
        modifierMatched = false
        candidateStartedAt = nil
        candidateCancelled = false
        holdStarted = false
    }
}
