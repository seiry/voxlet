import AudioToolbox
import CoreAudio
import Foundation

/// What the given apps play, through a private Core Audio process tap inside a private aggregate device.
/// Tap setup follows Voxt's MeetingSystemAudioCapture (Apache-2.0), narrowed to chosen apps instead of "all but us".
@available(macOS 14.2, *)
final class BrowserAudioTap {
    enum Target {
        /// Survives the app quitting and relaunching (macOS 26).
        case bundleIDs([String])
        case pids([pid_t])
    }

    /// Mono float samples at `sampleRate`, on the tap's own queue.
    var onSamples: ((UnsafeBufferPointer<Float>) -> Void)?
    private(set) var sampleRate: Double = 48_000

    private let queue = DispatchQueue(label: "voxlet.browser-tap", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var channels = 1

    func start(_ target: Target) throws {
        stop()
        let description = CATapDescription()
        description.name = "Voxlet meeting tap"
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = true
        description.isExclusive = false
        description.muteBehavior = .unmuted
        switch target {
        case .bundleIDs(let ids):
            guard #available(macOS 26.0, *) else { throw VoxletError(L10n.t("Meeting mode needs macOS 26 or later.")) }
            description.bundleIDs = ids
            description.isProcessRestoreEnabled = true
        case .pids(let pids):
            description.processes = pids.compactMap(Self.processObject(for:))
            if description.processes.isEmpty { throw VoxletError("No audio process for \(pids)") }
        }

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create tap")
        tapID = tap

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Voxlet meeting tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create aggregate device")
            aggregateID = device
            let format = try Self.tapFormat(tap)
            sampleRate = format.mSampleRate
            channels = max(1, Int(format.mChannelsPerFrame))

            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
                self?.deliver(input)
            }, "create IO proc")
            procID = proc
            try check(AudioDeviceStart(device, proc), "start tap")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
    }

    private func deliver(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        if channels == 1 || buffers.count > 1 {
            onSamples?(UnsafeBufferPointer(start: samples, count: count))
        } else {
            // An interleaved multichannel tap: keep the first channel.
            let frames = count / channels
            var mono = [Float](repeating: 0, count: frames)
            for i in 0..<frames { mono[i] = samples[i * channels] }
            mono.withUnsafeBufferPointer { onSamples?($0) }
        }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw VoxletError(L10n.format("Browser audio capture failed (%@: %d).", what, Int(status))) }
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { throw VoxletError(L10n.t("No audio output device was found.")) }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        guard withUnsafeMutablePointer(to: &uid, { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }) == noErr
        else { throw VoxletError(L10n.t("No audio output device was found.")) }
        return uid as String
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr, format.mSampleRate > 0
        else { throw VoxletError(L10n.t("The browser audio format could not be read.")) }
        return format
    }
}
