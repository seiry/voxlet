import AudioToolbox
import AVFoundation

/// Microphone capture that hands out 16 kHz mono s16le chunks and a level for the overlay.
final class AudioCapture {
    /// Called on the audio thread.
    var onPCM: ((Data) -> Void)?
    /// Called on the main queue.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: PCM16Converter?

    var isRunning: Bool { engine.isRunning }

    func start(deviceUID: String?) throws {
        if engine.isRunning { engine.stop() }
        engine.reset()

        let input = engine.inputNode
        if let deviceUID, !deviceUID.isEmpty, let deviceID = AudioDevices.deviceID(forUID: deviceUID),
           let unit = input.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        // Tap at the hardware rate; a mismatched tap format crashes with "Input HW format and tap format not matching".
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let tapFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: hardware.sampleRate,
                  channels: hardware.channelCount,
                  interleaved: false
              ),
              let converter = PCM16Converter(inputFormat: tapFormat)
        else { throw VoxletError(L10n.t("No usable microphone input was found.")) }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            guard let self, let pcm = self.converter?.convert(buffer) else { return }
            self.onPCM?(pcm)
            let level = PCM16Converter.level(of: pcm)
            DispatchQueue.main.async { self.onLevel?(level) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoxletError(L10n.format("Could not start the microphone: %@", error.localizedDescription))
        }
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
