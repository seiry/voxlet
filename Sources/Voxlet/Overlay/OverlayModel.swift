import SwiftUI

final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case recording
        case processing
    }

    @Published var phase: Phase = .hidden
    /// Latest voice bands from SpectrumAnalyzer, low to high.
    @Published var bands: [Float] = []
    @Published var transcript = ""
    @Published var status = ""
    /// Bumped on every show so the card replays its entrance animation.
    @Published var presentationID = UUID()
}

/// A live spectrum in the style of the Dynamic Island music visualiser: the voice bands are mirrored across
/// 16 bars with the lowest band in the middle, and each bar eases toward its band's peak since the last frame.
final class WaveformModel: ObservableObject {
    static let barCount = 16
    private static let framesPerSecond = 30.0
    private static let riseSmoothing: Float = 0.55
    private static let fallSmoothing: Float = 0.22
    private static let silenceFloor: Float = 0.03

    @Published private(set) var bars = [Float](repeating: 0, count: barCount)

    private var peaks = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var smoothed = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var timer: Timer?

    func ingest(_ bands: [Float]) {
        for (index, value) in bands.prefix(peaks.count).enumerated() {
            peaks[index] = max(peaks[index], max(0, min(value, 1)))
        }
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
            peaks = peaks.map { _ in 0 }
            smoothed = smoothed.map { _ in 0 }
        }
    }

    private func advance() {
        for band in smoothed.indices {
            let target = peaks[band] < Self.silenceFloor ? 0 : peaks[band]
            let factor = target > smoothed[band] ? Self.riseSmoothing : Self.fallSmoothing
            smoothed[band] += (target - smoothed[band]) * factor
            peaks[band] = 0
        }
        bars = Self.mirrored(smoothed)
    }

    /// Band 0 lands on the two centre bars and the highest band on the outer edges.
    static func mirrored(_ bands: [Float]) -> [Float] {
        let centre = Double(barCount - 1) / 2
        return (0..<barCount).map { bar in
            let band = Int(abs(Double(bar) - centre))
            return bands.indices.contains(band) ? bands[band] : 0
        }
    }

    static func barHeight(_ level: Float, min minHeight: CGFloat = 3.2, max maxHeight: CGFloat = 22) -> CGFloat {
        minHeight + (maxHeight - minHeight) * CGFloat(Swift.max(0, Swift.min(level, 1)))
    }

    static func glowOpacity(_ level: Float) -> Double {
        Swift.min(0.24, 0.04 + Swift.max(0, Double(level) - 0.05) * 0.26)
    }
}
