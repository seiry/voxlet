import Foundation

/// Maps microphone loudness to 0...1 for the overlay bars, measured in dB against an adaptive noise floor:
/// room noise sits under the gate and reads as silence, normal speech reaches most of the bar height.
struct AudioLevelMeter {
    /// Anything within this many dB of the noise floor counts as silence.
    private static let gateAboveFloor: Float = 8
    /// dB above the gate that fill the bar completely.
    private static let dynamicRange: Float = 26
    private static let floorRange: ClosedRange<Float> = -80 ... -35

    /// A typical built-in mic floor in a quiet room; it adapts within a second if the room is louder.
    private(set) var floorDb: Float = -55

    mutating func level(for pcm: Data) -> Float {
        let db = Self.rmsDb(pcm)
        // Follow quieter input quickly and near-floor noise within about a second, but drift up only very
        // slowly while someone is talking, so speech never raises its own gate.
        let rate: Float
        if db < floorDb {
            rate = 0.25
        } else if db < floorDb + 10 {
            rate = 0.03
        } else {
            rate = 0.001
        }
        floorDb = min(max(floorDb + (db - floorDb) * rate, Self.floorRange.lowerBound), Self.floorRange.upperBound)
        let gate = floorDb + Self.gateAboveFloor
        return min(max((db - gate) / Self.dynamicRange, 0), 1)
    }

    static func rmsDb(_ pcm: Data) -> Float {
        let count = pcm.count / 2
        guard count > 0 else { return -120 }
        var sum: Double = 0
        pcm.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) {
                let value = Double(sample) / 32768
                sum += value * value
            }
        }
        return Float(20 * log10(max(sqrt(sum / Double(count)), 1e-6)))
    }
}
