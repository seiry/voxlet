import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let recorder = RecordingController()
    let meeting = MeetingController()
    private lazy var meetingPanel = MeetingPanelController(meeting: meeting)
    private let meetingDetail = MeetingDetailWindowController()
    private var statusItem: NSStatusItem?
    private let settingsWindow = SettingsWindowController()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpMeeting()

        let hotkeys = HotkeyManager.shared
        hotkeys.onStart = { [weak self] in self?.recorder.start() }
        hotkeys.onStop = { [weak self] in self?.recorder.stop() }
        hotkeys.onCancel = { [weak self] in self?.recorder.cancel() }
        hotkeys.isRecording = { [weak self] in self?.recorder.isRecording ?? false }
        hotkeys.install()

        recorder.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.updateStatusIcon(state) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { _ in HotkeyManager.shared.reloadConfig() }
            .store(in: &cancellables)

        // `-VoxletOpenSettingsTab <tab>` and `-VoxletPreviewOverlay YES` exist for screenshots.
        let defaults = UserDefaults.standard
        if let tab = defaults.string(forKey: "VoxletOpenSettingsTab").flatMap(SettingsTab.init(rawValue:)) {
            settingsWindow.show(tab: tab)
        } else if !Permissions.allGranted || Keychain.apiKey == nil {
            settingsWindow.show(tab: Permissions.allGranted ? .model : .permissions)
        }
        if defaults.bool(forKey: "VoxletPreviewOverlay") {
            previewOverlay()
        }
    }

    private func previewOverlay() {
        let overlay = recorder.overlay
        overlay.showRecording()
        let text = "板爷，明天下午三点我们开会讨论 Voxlet 的发布计划"
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            tick += 1
            overlay.updateSpectrum((0..<SpectrumAnalyzer.bandCount).map { band in
                Float(max(0, 0.9 - Double(band) * 0.1) * abs(sin(Double(tick) * 0.3 + Double(band))) * Double.random(in: 0.6...1))
            })
            overlay.updateTranscript(String(text.prefix(min(text.count, tick / 3))))
            if tick > 400 { timer.invalidate() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon(.idle)
    }

    private func setUpMeeting() {
        meeting.onError = { [weak self] message in
            self?.recorder.overlay.showStatus(message, hideAfter: 5)
        }
        meeting.onFinished = { [weak self] folder, record in
            guard let self else { return }
            let screen = self.meetingPanel.screen
            self.meetingPanel.hide()
            self.meetingDetail.show(record: record, folder: folder, on: screen)
        }
        meeting.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.meeting.isActive { self.meetingPanel.show() }
                self.updateStatusIcon(self.recorder.state)
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon(_ state: RecordingController.State) {
        let symbol: String
        switch state {
        case .idle: symbol = meeting.isActive ? "record.circle" : "waveform"
        case .recording: symbol = "waveform.badge.mic"
        case .finishing: symbol = "ellipsis.circle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Voxlet")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let cost = NSMenuItem(
            title: L10n.format("Today: %@", Pricing.formatted(UsageStore.shared.summary(since: UsageStore.shared.startOfToday).cost)),
            action: nil,
            keyEquivalent: ""
        )
        cost.isEnabled = false
        menu.addItem(cost)
        menu.addItem(.separator())

        let toggleTitle = recorder.isRecording ? L10n.t("Stop Dictation") : L10n.t("Start Dictation")
        menu.addItem(withTitle: toggleTitle, action: #selector(toggleDictation), keyEquivalent: "").target = self
        menu.addItem(.separator())
        switch meeting.state {
        case .idle:
            menu.addItem(withTitle: L10n.t("Start Meeting Notes"), action: #selector(startMeeting), keyEquivalent: "").target = self
        case .recording, .paused:
            menu.addItem(withTitle: L10n.t("End Meeting Notes"), action: #selector(endMeeting), keyEquivalent: "").target = self
            menu.addItem(withTitle: L10n.t("Show Meeting Panel"), action: #selector(showMeetingPanel), keyEquivalent: "").target = self
        case .finishing:
            let item = NSMenuItem(title: L10n.t("Wrapping up the meeting…"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(withTitle: L10n.t("Open Meetings Folder"), action: #selector(openMeetingsFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(microphoneMenuItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("Quit Voxlet"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private var statusLine: String {
        if !Permissions.allGranted { return L10n.t("Permissions needed") }
        if Keychain.apiKey == nil { return L10n.t("API key needed") }
        let hotkey = Hotkey.load().displayString
        switch recorder.state {
        case .idle: return L10n.format("Ready · %@", hotkey)
        case .recording: return L10n.t("Listening…")
        case .finishing: return L10n.t("Transcribing…")
        }
    }

    private func microphoneMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t("Microphone"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let selected = Prefs.string(Prefs.inputDeviceUID)
        let system = NSMenuItem(title: L10n.t("System Default"), action: #selector(selectMicrophone(_:)), keyEquivalent: "")
        system.target = self
        system.representedObject = ""
        system.state = selected.isEmpty ? .on : .off
        submenu.addItem(system)
        submenu.addItem(.separator())
        for device in AudioDevices.inputDevices() {
            let entry = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = device.uid
            entry.state = device.uid == selected ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func toggleDictation() {
        recorder.toggle()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func startMeeting() {
        if !MeetingGateway.current.isConfigured {
            recorder.overlay.showStatus(L10n.t("No notes key yet: recording without running notes. Add it in Settings → Meeting."), hideAfter: 5)
        }
        meeting.start()
    }

    @objc private func endMeeting() {
        meeting.end()
    }

    @objc private func showMeetingPanel() {
        meetingPanel.show()
    }

    @objc private func openMeetingsFolder() {
        let root = MeetingStore.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String ?? "", forKey: Prefs.inputDeviceUID)
    }
}
