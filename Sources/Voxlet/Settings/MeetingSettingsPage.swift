import AppKit
import SwiftUI

struct MeetingSettingsPage: View {
    @AppStorage(Prefs.meetingGatewayURL) private var gatewayURL = "https://ai.sgp1.seiry.eu"
    @AppStorage(Prefs.meetingNotesModel) private var notesModel = "gemini-3.8-flash"
    @AppStorage(Prefs.meetingFolder) private var folder = "~/Meetings"
    @AppStorage(Prefs.meetingBrowsers) private var browsers = Prefs.defaultMeetingBrowsers
    @AppStorage(Prefs.meetingEchoCancellation) private var echo = "auto"
    @State private var gatewayKey = Keychain.gatewayKey ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(
                title: L10n.t("Running Notes"),
                subtitle: L10n.t("A text model writes the notes and answers questions; it never hears the audio. Any Gemini-compatible endpoint works, such as a new-api gateway.")
            ) {
                field(L10n.t("Base URL")) { SettingsTextField(placeholder: "https://ai.sgp1.seiry.eu", text: $gatewayURL) }
                HStack(alignment: .top, spacing: 12) {
                    field(L10n.t("API Key")) {
                        SettingsTextField(placeholder: "sk-…", text: $gatewayKey, secure: true)
                            .onChange(of: gatewayKey) { Keychain.setGatewayKey(gatewayKey) }
                    }
                    field(L10n.t("Model")) { SettingsTextField(placeholder: "gemini-3.8-flash", text: $notesModel, width: 200) }
                }
            }

            SettingsCard(
                title: L10n.t("Recording"),
                subtitle: L10n.t("Each meeting gets a folder with notes.md, transcript.md and both audio tracks.")
            ) {
                field(L10n.t("Meetings Folder")) { SettingsTextField(placeholder: "~/Meetings", text: $folder) }
                field(L10n.t("Echo Cancellation")) {
                    SettingsSegmented(
                        options: [("auto", L10n.t("Off with Headphones")), ("on", L10n.t("Always On")), ("off", L10n.t("Always Off"))],
                        selection: $echo
                    )
                }
                Text(L10n.t("On speakers, echo cancellation keeps the other side out of your microphone. While it runs, other apps play about 6 dB quieter."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }

            SettingsCard(
                title: L10n.t("Browser Audio"),
                subtitle: L10n.t("The other side of the call is recorded from these apps, one bundle ID per line.")
            ) {
                TextEditor(text: $browsers)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 110)
                    .background(RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous).fill(SettingsStyle.controlFill))
                HStack(spacing: 10) {
                    Text(L10n.t("Needs System Audio Recording: macOS asks the first time a meeting starts."))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.t("Open Privacy Settings")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                    }
                    .buttonStyle(SettingsCompactButtonStyle())
                }
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            content()
        }
    }
}
