import Accelerate
import Foundation

/// Turns 16 kHz mono PCM into a handful of log-spaced voice bands (0...1) for the overlay, like the Dynamic
/// Island music visualiser. Height comes from the broadband loudness meter and only the shape from the
/// spectrum: a narrow band's floor sits far below the broadband one, so per-band excess made soft sounds tall.
final class SpectrumAnalyzer {
    static let bandCount = 8

    private static let fftSize = 512
    private static let log2n = vDSP_Length(9)
    private static let sampleRate: Float = 16_000
    private static let lowHz: Float = 120
    private static let highHz: Float = 6_000

    /// Applied to the 0...1 loudness: keeps soft sounds low while normal speech still fills most of the bar.
    private static let heightCurve: Float = 1.3
    /// Bands this many dB under the strongest one drop to zero, which is what gives the bars a shape.
    private static let shapeRange: Float = 24
    /// >1 deepens the valleys between bands.
    private static let contrast: Float = 1.8
    /// Per-chunk weight of new band power; the rest is history, which takes the frame-to-frame FFT noise out.
    private static let powerSmoothing: Float = 0.35

    private let setup: FFTSetup
    private let window: [Float]
    private let bandBins: [Range<Int>]
    private var ring = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var bandPower = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var floors = [Float](repeating: -60, count: SpectrumAnalyzer.bandCount)

    init() {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.fftSize, isHalfWindow: false)
        let binHz = Self.sampleRate / Float(Self.fftSize)
        let ratio = pow(Self.highHz / Self.lowHz, 1 / Float(Self.bandCount))
        bandBins = (0..<Self.bandCount).map { band in
            let low = Self.lowHz * pow(ratio, Float(band))
            let start = Int((low / binHz).rounded())
            return start..<max(start + 1, Int((low * ratio / binHz).rounded()))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// `loudness` is AudioLevelMeter's 0...1 reading for the same chunk; at 0 all bands are zero, while the
    /// per-band floors keep learning the room.
    func analyze(_ pcm: Data, loudness: Float) -> [Float] {
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let count = min(samples.count, Self.fftSize)
            ring.removeFirst(count)
            ring.append(contentsOf: samples.suffix(count).map { Float($0) / 32768 })
        }
        let power = powerSpectrum()

        // How far each band sits above its own noise floor, so hum confined to one band never lights it up.
        var excess = [Float](repeating: 0, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            let bins = bandBins[band].clamped(to: 1..<power.count)
            let mean = bins.isEmpty ? 0 : power[bins].reduce(0, +) / Float(bins.count)
            bandPower[band] += (mean - bandPower[band]) * Self.powerSmoothing
            let db = 10 * log10(max(bandPower[band], 1e-12))
            // Same floor tracking as AudioLevelMeter: quick to follow quiet input, slow to rise under speech.
            let floor = floors[band]
            let rate: Float = db < floor ? 0.25 : (db < floor + 10 ? 0.03 : 0.001)
            floors[band] = min(max(floor + (db - floor) * rate, -120), 0)
            excess[band] = db - floors[band]
        }
        guard loudness > 0, let strongest = excess.max() else { return [Float](repeating: 0, count: Self.bandCount) }

        let height = pow(min(loudness, 1), Self.heightCurve)
        let shape = excess.map { value in
            pow(min(max(1 - (strongest - value) / Self.shapeRange, 0), 1), Self.contrast)
        }
        // A light [1 2 1] blur across neighbouring bands keeps the outline from looking jagged.
        return shape.indices.map { band in
            let left = shape[max(band - 1, 0)]
            let right = shape[min(band + 1, shape.count - 1)]
            return height * (left + 2 * shape[band] + right) / 4
        }
    }

    private func powerSpectrum() -> [Float] {
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
        return power
    }
}
