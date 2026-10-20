import Accelerate
import Foundation

/// Turns 16 kHz mono PCM into a handful of log-spaced voice bands (0...1) for the overlay, like the Dynamic
/// Island music visualiser. Each band learns its own noise floor, so hum in one band does not light it up.
final class SpectrumAnalyzer {
    static let bandCount = 8

    private static let fftSize = 512
    private static let log2n = vDSP_Length(9)
    private static let sampleRate: Float = 16_000
    private static let lowHz: Float = 120
    private static let highHz: Float = 6_000
    /// Voice energy falls with frequency; lift higher bands so they move too.
    private static let tiltPerOctave: Float = 4.5
    private static let gateAboveFloor: Float = 6
    /// The loudest band is tracked as a peak that decays this fast, so bars show the spectrum's shape
    /// rather than all saturating once speech is well above the noise floor.
    private static let peakDecayPerSecond: Float = 6
    /// Never stretch less than this many dB over the bar, or near-silence would be blown up to full height.
    private static let minimumSpan: Float = 18
    /// >1 deepens the valleys between bands so the shape reads at a glance.
    private static let contrast: Float = 1.4

    private let setup: FFTSetup
    private let window: [Float]
    private let bandBins: [Range<Int>]
    private let bandTilt: [Float]
    private var ring = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var floors = [Float](repeating: -60, count: SpectrumAnalyzer.bandCount)
    private var peakAboveFloor: Float = 0

    init() {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.fftSize, isHalfWindow: false)
        let binHz = Self.sampleRate / Float(Self.fftSize)
        let ratio = pow(Self.highHz / Self.lowHz, 1 / Float(Self.bandCount))
        var bins: [Range<Int>] = []
        var tilt: [Float] = []
        for band in 0..<Self.bandCount {
            let low = Self.lowHz * pow(ratio, Float(band))
            let high = low * ratio
            let start = Int((low / binHz).rounded())
            bins.append(start..<max(start + 1, Int((high / binHz).rounded())))
            tilt.append(Self.tiltPerOctave * log2(sqrt(low * high) / Self.lowHz))
        }
        bandBins = bins
        bandTilt = tilt
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Pass `gated: true` when the overall loudness is below the silence gate, which forces all bands to zero
    /// while still letting the per-band floors learn the room.
    func analyze(_ pcm: Data, gated: Bool) -> [Float] {
        let sampleCount = pcm.count / 2
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let count = min(samples.count, Self.fftSize)
            ring.removeFirst(count)
            ring.append(contentsOf: samples.suffix(count).map { Float($0) / 32768 })
        }

        let half = Self.fftSize / 2
        var windowed = vDSP.multiply(ring, window)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeMutableBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }

        var excess = [Float](repeating: 0, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            let bins = bandBins[band].clamped(to: 1..<half)
            let mean = bins.isEmpty ? 0 : power[bins].reduce(0, +) / Float(bins.count)
            let db = 10 * log10(max(mean, 1e-12)) + bandTilt[band]
            // Same floor tracking as AudioLevelMeter: quick to follow quiet input, slow to rise under speech.
            let floor = floors[band]
            let rate: Float = db < floor ? 0.25 : (db < floor + 10 ? 0.03 : 0.001)
            floors[band] = min(max(floor + (db - floor) * rate, -120), 0)
            excess[band] = db - floors[band]
        }

        let decay = Self.peakDecayPerSecond * Float(sampleCount) / Self.sampleRate
        peakAboveFloor = max(excess.max() ?? 0, peakAboveFloor - decay)
        guard !gated else { return [Float](repeating: 0, count: Self.bandCount) }

        let span = max(peakAboveFloor - Self.gateAboveFloor, Self.minimumSpan)
        return excess.map { value in
            let linear = min(max((value - Self.gateAboveFloor) / span, 0), 1)
            return pow(linear, Self.contrast)
        }
    }
}
