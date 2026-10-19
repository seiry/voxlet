import SwiftUI

private struct TranscriptWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The recording card, modelled on Voxt's WaveformView compact card.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    /// Fixed bar levels for offscreen previews, which have no live audio.
    var previewLevels: [Float]? = nil
    @StateObject private var waveform = WaveformModel()
    @AppStorage(Prefs.overlayOpacity) private var opacity = 82.0
    @AppStorage(Prefs.overlayCornerRadius) private var cornerRadiusSetting = 24.0
    @AppStorage(Prefs.showRealtimeText) private var showRealtimeText = true
    @AppStorage(Prefs.overlayPosition) private var positionRaw = OverlayPosition.bottom.rawValue

    @State private var appeared = false
    @State private var textScrollID = UUID()

    private let barWidth: CGFloat = 3.2
    private let barSpacing: CGFloat = 2.5
    private let slotWidth: CGFloat = 94
    private let barAreaHeight: CGFloat = 28

    private var displayText: String {
        let status = model.status.trimmed
        if !status.isEmpty { return status }
        return showRealtimeText ? model.transcript.trimmed : ""
    }

    private var hasText: Bool { !displayText.isEmpty }
    private var cornerRadius: CGFloat { CGFloat(min(max(cornerRadiusSetting, 0), 40)) }
    private var isProcessing: Bool { model.phase == .processing }
    private var anchorTop: Bool { positionRaw == OverlayPosition.top.rawValue }

    var body: some View {
        card
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchorTop ? .top : .bottom)
            .scaleEffect(appeared ? 1 : 0.5, anchor: anchorTop ? .top : .bottom)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.5, blendDuration: 0.1), value: appeared)
            .onChange(of: model.presentationID) { replayEntrance() }
            .onChange(of: model.phase) { updateWaveformActivity() }
            .onChange(of: model.level) { waveform.ingest(model.level) }
            .onAppear {
                updateWaveformActivity()
                replayEntrance()
            }
    }

    private var card: some View {
        VStack(spacing: hasText ? 8 : 0) {
            HStack(spacing: 10) {
                leadingIcon
                    .frame(width: 16, height: 28)
                waveformSlot
            }
            .frame(height: barAreaHeight)
            .animation(.easeInOut(duration: 0.25), value: isProcessing)

            if hasText {
                transcriptLine
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, hasText ? 20 : 14)
        .padding(.vertical, hasText ? 12 : 10)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.black.opacity(min(max(opacity, 0), 100) / 100))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        )
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.spring(response: 0.4, dampingFraction: 0.55, blendDuration: 0.1), value: hasText)
    }

    private var leadingIcon: some View {
        Image(systemName: isProcessing ? "sparkles" : "mic.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .contentTransition(.symbolEffect(.replace))
    }

    @ViewBuilder
    private var waveformSlot: some View {
        let visualWidth = CGFloat(WaveformModel.barCount) * barWidth + CGFloat(WaveformModel.barCount - 1) * barSpacing
        Group {
            if isProcessing {
                ProcessingDots()
                    .transition(.opacity)
            } else {
                HStack(alignment: .center, spacing: barSpacing) {
                    ForEach(0..<WaveformModel.barCount, id: \.self) { index in
                        let level = previewLevels?[index] ?? waveform.bars[index]
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(LinearGradient(
                                colors: [.white.opacity(0.98), .white.opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            .frame(width: barWidth, height: WaveformModel.barHeight(level))
                            .shadow(color: .white.opacity(WaveformModel.glowOpacity(level)), radius: 3)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(width: visualWidth, height: barAreaHeight)
        .frame(width: slotWidth, height: barAreaHeight)
    }

    private var transcriptLine: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    Text(displayText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .id(textScrollID)
                    Spacer().frame(width: 4)
                }
            }
            .frame(maxWidth: 260)
            .mask(
                HStack(spacing: 0) {
                    if displayText.count > 38 {
                        LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 16)
                    }
                    Color.white
                }
            )
            .onChange(of: displayText) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(textScrollID, anchor: .trailing) }
                }
            }
        }
    }

    private func replayEntrance() {
        appeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { appeared = true }
    }

    private func updateWaveformActivity() {
        waveform.setActive(model.phase == .recording)
    }
}

/// Five dots pulsing in sequence, as in Voxt's WaveformProcessingLoaderView.
private struct ProcessingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    let progress = phase(index, context.date)
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.6 + 0.6 * pulse(progress))
                        .opacity(0.35 + 0.65 * pulse(progress))
                }
            }
        }
    }

    private func phase(_ index: Int, _ date: Date) -> Double {
        let cycle = 1.2
        let raw = (date.timeIntervalSinceReferenceDate - Double(index) * 0.12).truncatingRemainder(dividingBy: cycle)
        return (raw < 0 ? raw + cycle : raw) / cycle
    }

    private func pulse(_ progress: Double) -> Double {
        progress < 0.3 ? sin(progress / 0.3 * .pi) : 0
    }
}
