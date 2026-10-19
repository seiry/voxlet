import SwiftUI

final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case recording
        case processing
    }

    @Published var phase: Phase = .hidden
    @Published var level: Float = 0
    @Published var transcript = ""
    @Published var status = ""
    /// Bumped on every show so the card replays its entrance animation.
    @Published var presentationID = UUID()
}

/// Rolling bar history like Voxt's RecentAudioWaveformState: 16 bars over ~0.8 s at 20 fps,
/// fast rise and slow fall so speech reads as motion rather than flicker.
final class WaveformModel: ObservableObject {
    static let barCount = 16
    private static let framesPerSecond = 20.0
    private static let riseSmoothing: Float = 0.82
    private static let fallSmoothing: Float = 0.24
    private static let silenceFloor: Float = 0.01

    @Published private(set) var bars = [Float](repeating: 0, count: barCount)

    private var peakSinceFrame: Float = 0
    private var smoothed: Float = 0
    private var timer: Timer?

    func ingest(_ level: Float) {
        // Voxt lifts quiet input before it reaches the bars.
        let lifted = Float(min(1.0, pow(Double(max(0, min(level, 1))), 0.72) * 1.24))
        peakSinceFrame = max(peakSinceFrame, lifted)
    }

    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
                self?.advance()
            }
        } else {
            timer?.invalidate()
            timer = nil
            bars = [Float](repeating: 0, count: Self.barCount)
            smoothed = 0
            peakSinceFrame = 0
        }
    }

    private func advance() {
        let target = peakSinceFrame < Self.silenceFloor ? 0 : peakSinceFrame
        let factor = target > smoothed ? Self.riseSmoothing : Self.fallSmoothing
        smoothed += (target - smoothed) * factor
        peakSinceFrame = 0
        var next = bars
        next.removeFirst()
        next.append(smoothed)
        bars = next
    }

    static func barHeight(_ level: Float, min minHeight: CGFloat = 3.2, max maxHeight: CGFloat = 22) -> CGFloat {
        let emphasized = CGFloat(Swift.min(1.0, pow(Double(Swift.max(0, Swift.min(level, 1))), 0.9) * 1.02))
        return Swift.max(minHeight, Swift.min(maxHeight, minHeight + (maxHeight - minHeight) * emphasized))
    }

    static func glowOpacity(_ level: Float) -> Double {
        let emphasized = Double(barHeight(level, min: 0, max: 1))
        return Swift.min(0.24, 0.04 + Swift.max(0, emphasized - 0.05) * 0.26)
    }
}
