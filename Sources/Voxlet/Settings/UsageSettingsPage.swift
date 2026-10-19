import SwiftUI

struct UsageSettingsPage: View {
    @ObservedObject private var store = UsageStore.shared
    @AppStorage(Prefs.priceAudioInputPerMillion) private var audioPrice = Pricing.defaultAudioInputPerMillion
    @AppStorage(Prefs.priceTextOutputPerMillion) private var outputPrice = Pricing.defaultTextOutputPerMillion
    @State private var confirmingReset = false

    var body: some View {
        // Read the prices so the tiles recompute when they change.
        let _ = (audioPrice, outputPrice)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                tile(L10n.t("Today"), store.summary(since: store.startOfToday))
                tile(L10n.t("This Month"), store.summary(since: store.startOfMonth))
                tile(L10n.t("All Time"), store.summary())
            }

            SettingsCard(
                title: L10n.t("Prices (USD per 1M tokens)"),
                subtitle: L10n.t("Defaults are the Gemini API list prices for gemini-3.5-transcribe-live. Agent Platform prices were not verified; check your Cloud billing.")
            ) {
                SettingsRow(title: L10n.t("Audio Input"), caption: L10n.t("Gemini counts 25 audio tokens per second.")) {
                    priceField($audioPrice)
                }
                SettingsDivider()
                SettingsRow(title: L10n.t("Text Output")) {
                    priceField($outputPrice)
                }
                HStack {
                    Spacer()
                    Button(L10n.t("Restore Defaults")) {
                        audioPrice = Pricing.defaultAudioInputPerMillion
                        outputPrice = Pricing.defaultTextOutputPerMillion
                    }
                    .buttonStyle(SettingsCompactButtonStyle())
                }
            }

            SettingsCard(title: L10n.t("Recent Sessions")) {
                if store.records.isEmpty {
                    Text(L10n.t("No dictation yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    recentList
                    HStack {
                        Text(L10n.t("Token counts come from the server's usageMetadata; “Estimated” rows had none and use audio length."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(L10n.t("Reset Usage")) { confirmingReset = true }
                            .buttonStyle(SettingsCompactButtonStyle())
                    }
                }
            }
        }
        .alert(L10n.t("Reset all usage records?"), isPresented: $confirmingReset) {
            Button(L10n.t("Reset Usage"), role: .destructive) { store.reset() }
            Button(L10n.t("Cancel"), role: .cancel) {}
        }
    }

    private func tile(_ title: String, _ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(Pricing.formatted(summary.cost))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(L10n.format("%d sessions · %@ · %@ tokens", summary.sessions, Self.duration(summary.audioSeconds), Self.compact(summary.tokens)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsStyle.panelRadius, style: .continuous)
                .fill(SettingsStyle.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsStyle.panelRadius, style: .continuous)
                .strokeBorder(SettingsStyle.subtleBorder, lineWidth: 1)
        )
    }

    private var recentList: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.records.suffix(20).reversed().enumerated()), id: \.element.id) { index, record in
                if index > 0 { SettingsDivider() }
                HStack(spacing: 12) {
                    Text(record.date, format: .dateTime.month().day().hour().minute())
                        .font(.system(size: 12))
                        .frame(width: 110, alignment: .leading)
                    Text(Self.duration(record.audioSeconds))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 60, alignment: .trailing)
                    Text("\(record.usage.audioInputTokens) / \(record.usage.outputTokens)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    if !record.usage.reported {
                        StatusBadge(text: L10n.t("Estimated"), tint: .orange)
                    }
                    Spacer()
                    Text(Pricing.formatted(Pricing.cost(of: record.usage)))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .padding(.vertical, 7)
            }
        }
    }

    private func priceField(_ value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text("$").foregroundStyle(.secondary)
            TextField("", value: value, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous)
                .fill(SettingsStyle.controlFill)
        )
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        if minutes < 60 { return String(format: "%dm%02ds", minutes, Int(seconds) % 60) }
        return String(format: "%dh%02dm", minutes / 60, minutes % 60)
    }

    static func compact(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }
}
