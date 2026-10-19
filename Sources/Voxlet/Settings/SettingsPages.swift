import Combine
import ServiceManagement
import SwiftUI

// MARK: - General

struct GeneralSettingsPage: View {
    @AppStorage(Prefs.inputDeviceUID) private var inputDeviceUID = ""
    @AppStorage(Prefs.interactionSounds) private var interactionSounds = true
    @AppStorage(Prefs.recognitionLanguage) private var recognitionLanguage = RecognitionLanguage.auto.rawValue
    @AppStorage(Prefs.showRealtimeText) private var showRealtimeText = true
    @AppStorage(Prefs.keepResultInClipboard) private var keepResultInClipboard = false
    @AppStorage(Prefs.showInDock) private var showInDock = false
    @AppStorage(Prefs.interfaceLanguage) private var interfaceLanguage = InterfaceLanguage.system.rawValue
    @AppStorage(Prefs.overlayOpacity) private var overlayOpacity = 82.0
    @AppStorage(Prefs.overlayCornerRadius) private var overlayCornerRadius = 24.0
    @AppStorage(Prefs.overlayEdgeDistance) private var overlayEdgeDistance = 30.0
    @AppStorage(Prefs.overlayPosition) private var overlayPosition = OverlayPosition.bottom.rawValue

    @State private var devices = AudioDevices.inputDevices()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: L10n.t("Audio")) {
                SettingsRow(title: L10n.t("Microphone")) {
                    Picker("", selection: $inputDeviceUID) {
                        Text(L10n.t("System Default")).tag("")
                        ForEach(devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
                SettingsDivider()
                SettingsRow(title: L10n.t("Interaction Sounds"), caption: L10n.t("Play a short sound when dictation starts and stops.")) {
                    Toggle("", isOn: $interactionSounds).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: L10n.t("Recognition")) {
                SettingsRow(
                    title: L10n.t("Speech Recognition Language"),
                    caption: L10n.t("Auto detect also handles Chinese and English mixed in one sentence.")
                ) {
                    Picker("", selection: $recognitionLanguage) {
                        ForEach(RecognitionLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }

            SettingsCard(title: L10n.t("Floating Window Style")) {
                SettingsRow(title: L10n.t("Show Realtime Text"), caption: L10n.t("Show the live transcript under the waveform.")) {
                    Toggle("", isOn: $showRealtimeText).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                sliderRow(L10n.t("Opacity"), value: $overlayOpacity, range: 0...100, suffix: "%")
                sliderRow(L10n.t("Corner Radius"), value: $overlayCornerRadius, range: 0...40, suffix: "pt")
                sliderRow(L10n.t("Edge Distance"), value: $overlayEdgeDistance, range: 0...120, suffix: "pt")
                SettingsDivider()
                SettingsRow(title: L10n.t("Position")) {
                    SettingsSegmented(
                        options: [
                            (OverlayPosition.bottom.rawValue, L10n.t("Bottom")),
                            (OverlayPosition.top.rawValue, L10n.t("Top")),
                        ],
                        selection: $overlayPosition
                    )
                }
            }

            SettingsCard(title: L10n.t("App Behavior")) {
                SettingsRow(
                    title: L10n.t("Also Copy Result to Clipboard"),
                    caption: L10n.t("Keep the transcript on the clipboard instead of restoring what was there.")
                ) {
                    Toggle("", isOn: $keepResultInClipboard).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(title: L10n.t("Launch at Login"), caption: launchAtLoginError) {
                    Toggle("", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(title: L10n.t("Show in Dock")) {
                    Toggle("", isOn: $showInDock).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(title: L10n.t("Interface Language")) {
                    Picker("", selection: $interfaceLanguage) {
                        ForEach(InterfaceLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }
        }
        .onAppear { devices = AudioDevices.inputDevices() }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        SettingsRow(title: title) {
            HStack(spacing: 10) {
                // No `step:`; on macOS it draws a tick mark per step.
                Slider(value: value, in: range).frame(width: 200)
                Text("\(Int(value.wrappedValue.rounded())) \(suffix)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Model

struct ModelSettingsPage: View {
    @AppStorage(Prefs.provider) private var provider = GeminiProvider.agentPlatform.rawValue
    @AppStorage(Prefs.vertexProject) private var project = ""
    @AppStorage(Prefs.vertexLocation) private var location = GeminiLiveConfig.defaultLocation
    @AppStorage(Prefs.model) private var model = GeminiLiveConfig.defaultModel
    @AppStorage(Prefs.endpointOverride) private var endpointOverride = ""

    @State private var apiKey = Keychain.apiKey ?? ""
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle
        case running
        case passed(String)
        case failed(String)
    }

    private var isAgentPlatform: Bool { provider == GeminiProvider.agentPlatform.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSegmented(
                options: GeminiProvider.allCases.map { ($0.rawValue, $0.displayName) },
                selection: $provider
            )

            SettingsCard(
                title: L10n.t("Credentials"),
                subtitle: isAgentPlatform
                    ? L10n.t("An Agent Platform API key from Google Cloud. Billed monthly with your Cloud account.")
                    : L10n.t("A Gemini API key from Google AI Studio. Needs a positive prepaid balance.")
            ) {
                fieldBlock(L10n.t("API Key")) {
                    SettingsTextField(placeholder: "AQ.…", text: $apiKey, secure: true)
                        .onChange(of: apiKey) { Keychain.setAPIKey(apiKey) }
                }
                if isAgentPlatform {
                    HStack(alignment: .top, spacing: 12) {
                        fieldBlock(L10n.t("Project ID or Number")) {
                            SettingsTextField(placeholder: "my-project-123456", text: $project)
                        }
                        fieldBlock(L10n.t("Location")) {
                            SettingsTextField(placeholder: GeminiLiveConfig.defaultLocation, text: $location, width: 160)
                        }
                    }
                }
            }

            SettingsCard(title: L10n.t("Model")) {
                fieldBlock(L10n.t("Model")) {
                    SettingsTextField(placeholder: GeminiLiveConfig.defaultModel, text: $model)
                }
                fieldBlock(L10n.t("Endpoint (Optional)")) {
                    SettingsTextField(
                        placeholder: isAgentPlatform ? GeminiLiveConfig.agentPlatformEndpoint : GeminiLiveConfig.aiStudioEndpoint,
                        text: $endpointOverride
                    )
                }
                Text(L10n.t("Gemini realtime transcription over the Live WebSocket. Voice input only."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button(L10n.t("Test")) { runTest() }
                        .buttonStyle(SettingsCompactButtonStyle())
                        .disabled(testState == .running)
                    if testState == .running {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                testResult
            }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle, .running:
            EmptyView()
        case .passed(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            content()
        }
    }

    private func runTest() {
        testState = .running
        ConnectionTest.run(config: Prefs.liveConfig()) { result in
            switch result {
            case .success(let milliseconds):
                testState = .passed(L10n.format("Connected. Session ready in %d ms.", milliseconds))
            case .failure(let error):
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

/// Opens a session, waits for setupComplete, and reports the server's close reason on failure.
enum ConnectionTest {
    static func run(config: GeminiLiveConfig, completion: @escaping (Result<Int, Error>) -> Void) {
        let session = GeminiLiveSession(config: config)
        let started = Date()
        var finished = false
        let finish: (Result<Int, Error>) -> Void = { result in
            guard !finished else { return }
            finished = true
            session.cancel()
            completion(result)
        }
        session.onSetupComplete = { finish(.success(Int(Date().timeIntervalSince(started) * 1000))) }
        session.onFailure = { finish(.failure($0)) }
        do {
            try session.start()
        } catch {
            finish(.failure(error))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            finish(.failure(VoxletError(L10n.t("Timed out waiting for the server."))))
        }
    }
}

// MARK: - Permissions

struct PermissionsSettingsPage: View {
    @State private var granted: [PermissionKind: Bool] = [:]
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: L10n.t("Required Permissions")) {
                ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 { SettingsDivider() }
                    row(kind)
                }
            }
            Text(L10n.t("Voxlet is signed ad hoc, so macOS may ask again after each rebuild. Remove the old entry in System Settings and grant it again if the switch looks on but the status stays off."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func row(_ kind: PermissionKind) -> some View {
        let isOn = granted[kind] ?? false
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(kind.title).font(.system(size: 13, weight: .medium))
                    StatusBadge(text: isOn ? L10n.t("Granted") : L10n.t("Not Granted"), tint: isOn ? .green : .red)
                }
                Text(kind.caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isOn {
                Button(L10n.t("Request")) {
                    Permissions.request(kind) { _ in refresh() }
                }
                .buttonStyle(SettingsCompactButtonStyle(prominent: true))
            }
            Button(L10n.t("Open Settings")) { Permissions.openSettings(kind) }
                .buttonStyle(SettingsCompactButtonStyle())
        }
    }

    private func refresh() {
        var next: [PermissionKind: Bool] = [:]
        for kind in PermissionKind.allCases { next[kind] = Permissions.isGranted(kind) }
        if next[.accessibility] == true { HotkeyManager.shared.install() }
        granted = next
    }
}

// MARK: - About

struct AboutSettingsPage: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Voxlet") {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.format("Version %@", version)).font(.system(size: 13, weight: .medium))
                        Text(L10n.t("Push-to-talk dictation with Gemini 3.5 Transcribe Live."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            SettingsCard(title: L10n.t("Acknowledgements")) {
                Text(L10n.t("The interface, hotkey rules, and Gemini Live protocol handling are adapted from Voxt, licensed under Apache-2.0."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("github.com/sgl-project/sglang-omni/tree/main/Voxt", destination: URL(string: "https://github.com/sgl-project/sglang-omni/tree/main/Voxt")!)
                    .font(.system(size: 12))
            }
        }
    }
}
