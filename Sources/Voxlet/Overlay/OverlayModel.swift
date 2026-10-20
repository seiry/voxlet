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
/// 16 bars with the lowest band in the middle. Bars are stepped by the screen's CADisplayLink, the macOS
/// counterpart of requestAnimationFrame, so they run at 120 Hz on ProMotion displays. Easing uses the real
/// frame interval, rising in about 85 ms and settling in about 200 ms at any refresh rate.
final class WaveformModel: NSObject, ObservableObject {
    static let barCount = 16
    private static let riseTimeConstant: Float = 0.085
    private static let fallTimeConstant: Float = 0.2
    private static let silenceFloor: Float = 0.03

    @Published private(set) var bars = [Float](repeating: 0, count: barCount)

    /// Held between audio chunks: the mic delivers ~47 chunks/s, fewer than the screen draws frames, and
    /// dropping the target to zero on frames without new data made the bars stutter.
    private var targets = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var smoothed = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    func ingest(_ bands: [Float]) {
        for (index, value) in bands.prefix(targets.count).enumerated() {
            targets[index] = max(0, min(value, 1))
        }
    }

    func setActive(_ active: Bool) {
        if active {
            guard displayLink == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            let link = screen.displayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            displayLink?.invalidate()
            displayLink = nil
            lastTimestamp = nil
            bars = [Float](repeating: 0, count: Self.barCount)
            targets = targets.map { _ in 0 }
            smoothed = smoothed.map { _ in 0 }
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        // Clamp the gap so a stall (window server busy, screen asleep) eases in rather than jumping.
        let elapsed = Float(min(max(link.timestamp - (lastTimestamp ?? link.timestamp - 1.0 / 120), 0), 0.05))
        lastTimestamp = link.timestamp
        let rise = 1 - exp(-elapsed / Self.riseTimeConstant)
        let fall = 1 - exp(-elapsed / Self.fallTimeConstant)
        for band in smoothed.indices {
            let target = targets[band] < Self.silenceFloor ? 0 : targets[band]
            smoothed[band] += (target - smoothed[band]) * (target > smoothed[band] ? rise : fall)
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
