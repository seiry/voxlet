import AudioToolbox
import AVFoundation
import CoreAudio

/// The meeting microphone as 48 kHz mono float. On speakers it runs Apple's voice processing unit, which on the
/// MacBook removes everything the speakers play, from any app (probe/meeting-aec/REPORT.md); on headphones it is a
/// plain capture, so the meeting is not ducked and other apps keep an unprocessed mic.
final class MeetingMicrophone {
    static let sampleRate = 48_000.0

    /// Called on the audio thread.
    var onSamples: ((UnsafeBufferPointer<Float>) -> Void)?
    private(set) var isVoiceProcessing = false

    private var unit: AudioUnit?
    private var scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    deinit { scratch.deallocate() }

    func start(voiceProcessing: Bool) throws {
        stop()
        if voiceProcessing {
            try startVoiceProcessing()
        } else {
            try startPlain()
        }
        isVoiceProcessing = voiceProcessing
    }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    // MARK: - Voice processing

    /// AVAudioEngine's voice processing turns the MacBook input into 9 channels and fails with -10875;
    /// the raw unit at 48 kHz mono works (stephenturner/trailmix#4).
    private func startVoiceProcessing() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw VoxletError(L10n.t("Echo cancellation is not available on this Mac."))
        }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "create")
        guard let unit = created else { throw VoxletError(L10n.t("Echo cancellation is not available on this Mac.")) }
        self.unit = unit

        var one: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "enable input")
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, formatSize), "mic format")
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, formatSize), "play format")
        var silence = AURenderCallbackStruct(inputProc: renderSilence, inputProcRefCon: nil)
        let callbackSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &silence, callbackSize), "render")
        var capture = AURenderCallbackStruct(inputProc: captureMicrophone, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &capture, callbackSize), "capture")
        // The minimum still lowers other apps by about 6 dB; it is the least the unit allows.
        var ducking = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
        AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
                             &ducking, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
        try check(AudioUnitInitialize(unit), "initialize")
        try check(AudioOutputUnitStart(unit), "start")
    }

    fileprivate func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, time: UnsafePointer<AudioTimeStamp>,
                            bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit else { return noErr }
        let count = min(Int(frames), 16_384)
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: UnsafeMutableRawPointer(scratch)
        ))
        let status = AudioUnitRender(unit, flags, time, bus, UInt32(count), &list)
        if status == noErr { onSamples?(UnsafeBufferPointer(start: scratch, count: count)) }
        return status
    }

    // MARK: - Plain capture

    private func startPlain() throws {
        engine.reset()
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        let channels = input.outputFormat(forBus: 0).channelCount
        guard hardware.sampleRate > 0, channels > 0,
              let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate,
                                            channels: channels, interleaved: false),
              let target = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: tapFormat, to: target)
        else { throw VoxletError(L10n.t("No usable microphone input was found.")) }
        converter.downmix = true
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / tapFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard out.frameLength > 0, let data = out.floatChannelData else { return }
            self.onSamples?(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoxletError(L10n.format("Could not start the microphone: %@", error.localizedDescription))
        }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw VoxletError(L10n.format("Echo cancellation failed to start (%@: %d).", what, Int(status))) }
    }
}

private let renderSilence: AURenderCallback = { _, _, _, _, frames, data in
    if let data {
        for buffer in UnsafeMutableAudioBufferListPointer(data) {
            if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
        }
    }
    return noErr
}

private let captureMicrophone: AURenderCallback = { refCon, flags, time, bus, frames, _ in
    Unmanaged<MeetingMicrophone>.fromOpaque(refCon).takeUnretainedValue().render(flags: flags, time: time, bus: bus, frames: frames)
}

/// Whether the current output is something worn, where no echo reaches the mic.
enum OutputRoute {
    static var isHeadphones: Bool {
        guard let device = defaultOutputDevice() else { return false }
        let transport: UInt32 = property(device, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        if transport == kAudioDeviceTransportTypeBuiltIn {
            let source: UInt32 = property(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput) ?? 0
            return source == fourCC("hdpn")
        }
        return false
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
