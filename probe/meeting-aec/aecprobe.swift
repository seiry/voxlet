// Plays a far-end track (48 kHz mono) and records the microphone; a near-end track plays through a separate
// afplay process, so it is never part of any echo reference.
//   --vpio 0: AVAudioEngine, no processing (the raw "mic only" capture)
//   --vpio 1: AUVoiceProcessingIO plays the far end itself, so Apple's echo canceller has it as reference
// Usage: aecprobe --far f.wav [--near n.wav] --out mic.wav --vpio 0|1 [--tail 2]
import AudioToolbox
import AVFoundation
import Foundation

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr {
        log("\(what) failed: \(status)")
        exit(3)
    }
}

guard let farPath = arg("--far"), let outPath = arg("--out") else {
    log("usage: aecprobe --far f.wav [--near n.wav] --out mic.wav --vpio 0|1 [--tail 2]")
    exit(2)
}
let nearPath = arg("--near")
let vpio = arg("--vpio") == "1"
let tail = Double(arg("--tail") ?? "2") ?? 2
let rate = 48_000.0

let farFile = try AVAudioFile(forReading: URL(fileURLWithPath: farPath))
let farFormat = farFile.processingFormat
guard farFormat.sampleRate == rate, farFormat.channelCount == 1 else {
    log("far track must be 48 kHz mono, got \(farFormat)")
    exit(2)
}
let farBuffer = AVAudioPCMBuffer(pcmFormat: farFormat, frameCapacity: AVAudioFrameCount(farFile.length))!
try farFile.read(into: farBuffer)
let farCount = Int(farBuffer.frameLength)
func seconds(_ path: String?) -> Double {
    guard let path, let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return 0 }
    return Double(f.length) / f.processingFormat.sampleRate
}
// Recording length covers the longest of the three tracks, not just the far end.
let farSeconds = max(Double(farCount) / rate, seconds(nearPath), seconds(arg("--other")))
let leadIn = 1.0

/// Shared with the real-time callbacks; preallocated so they never allocate.
final class Tape {
    let far: UnsafeMutablePointer<Float>
    let farCount: Int
    var farPos = 0
    var playing = false
    let rec: UnsafeMutablePointer<Float>
    let recCapacity: Int
    var recCount = 0
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    var unit: AudioUnit?

    init(far: UnsafePointer<Float>, farCount: Int, recSeconds: Double) {
        self.far = .allocate(capacity: farCount)
        self.far.update(from: far, count: farCount)
        self.farCount = farCount
        recCapacity = Int(recSeconds * rate)
        rec = .allocate(capacity: recCapacity)
    }
}

let tape = Tape(far: farBuffer.floatChannelData![0], farCount: farCount, recSeconds: leadIn + farSeconds + tail + 2)

/// --near plays the talker: on --near-device through sox (a speaker that is not the Mac's), else afplay.
/// --other plays through afplay on the default output: an app the echo canceller was not handed.
func startNear() -> [Process] {
    var procs: [Process] = []
    if let nearPath {
        let p = Process()
        if let device = arg("--near-device") {
            p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sox")
            p.arguments = ["-q", nearPath, "-t", "coreaudio", device]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            p.arguments = [nearPath]
        }
        try? p.run()
        procs.append(p)
    }
    if let otherPath = arg("--other") {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [otherPath]
        try? p.run()
        procs.append(p)
    }
    return procs
}

func runRaw() throws {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: farFormat)
    let input = engine.inputNode
    let inFormat = input.outputFormat(forBus: 0)
    log("raw input format: \(inFormat)")
    let converter = AVAudioConverter(from: inFormat, to: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!)
    input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
        let ratio = rate / inFormat.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: cap) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        let n = min(Int(out.frameLength), tape.recCapacity - tape.recCount)
        (tape.rec + tape.recCount).update(from: out.floatChannelData![0], count: n)
        tape.recCount += n
    }
    engine.prepare()
    try engine.start()
    Thread.sleep(forTimeInterval: leadIn)
    player.scheduleBuffer(farBuffer, at: nil)
    player.play()
    let near = startNear()
    Thread.sleep(forTimeInterval: farSeconds + tail)
    near.forEach { $0.terminate() }
    input.removeTap(onBus: 0)
    engine.stop()
}

let renderFar: AURenderCallback = { refCon, _, _, _, frames, ioData in
    let tape = Unmanaged<Tape>.fromOpaque(refCon).takeUnretainedValue()
    let out = UnsafeMutableAudioBufferListPointer(ioData!)[0].mData!.assumingMemoryBound(to: Float.self)
    let n = Int(frames)
    for i in 0..<n {
        if tape.playing, tape.farPos < tape.farCount {
            out[i] = tape.far[tape.farPos]
            tape.farPos += 1
        } else {
            out[i] = 0
        }
    }
    return noErr
}

let captureMic: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    let tape = Unmanaged<Tape>.fromOpaque(refCon).takeUnretainedValue()
    let n = Int(frames)
    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
        mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(tape.scratch)))
    let status = AudioUnitRender(tape.unit!, flags, timeStamp, bus, frames, &list)
    if status != noErr { return status }
    let m = min(n, tape.recCapacity - tape.recCount)
    (tape.rec + tape.recCount).update(from: tape.scratch, count: m)
    tape.recCount += m
    return noErr
}

func runVPIO() {
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else { log("no VoiceProcessingIO"); exit(3) }
    var unit: AudioUnit?
    check(AudioComponentInstanceNew(comp, &unit), "instantiate")
    let u = unit!
    tape.unit = u
    var one: UInt32 = 1
    check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "enable input")
    check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, 4), "enable output")
    var asbd = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
        mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, asbdSize), "mic format")
    check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, asbdSize), "play format")
    let ref = Unmanaged.passUnretained(tape).toOpaque()
    var render = AURenderCallbackStruct(inputProc: renderFar, inputProcRefCon: ref)
    let cbSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
    check(AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &render, cbSize), "render cb")
    var capture = AURenderCallbackStruct(inputProc: captureMic, inputProcRefCon: ref)
    check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &capture, cbSize), "input cb")
    // Ducking would lower the afplay near-end track and fake a better result.
    var duck = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
    check(AudioUnitSetProperty(u, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0, &duck,
                               UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)), "ducking")
    if arg("--bypass") == "1" {
        // Keeps the unit (and its ducking) running but skips the processing itself.
        check(AudioUnitSetProperty(u, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global, 0, &one, 4), "bypass")
    }
    check(AudioUnitInitialize(u), "initialize")
    if arg("--duck-after-init") == "1" {
        check(AudioUnitSetProperty(u, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0, &duck,
                                   UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)), "ducking after init")
    }
    check(AudioOutputUnitStart(u), "start")
    log("vpio started")
    Thread.sleep(forTimeInterval: leadIn)
    tape.playing = true
    let near = startNear()
    Thread.sleep(forTimeInterval: farSeconds + tail)
    near.forEach { $0.terminate() }
    AudioOutputUnitStop(u)
    AudioUnitUninitialize(u)
    AudioComponentInstanceDispose(u)
}

if vpio { runVPIO() } else { try runRaw() }

let outFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(max(tape.recCount, 1)))!
outBuffer.frameLength = AVAudioFrameCount(tape.recCount)
outBuffer.floatChannelData![0].update(from: tape.rec, count: tape.recCount)
var peak: Float = 0
for i in 0..<tape.recCount { peak = max(peak, abs(tape.rec[i])) }
let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                               AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
let outFile = try AVAudioFile(forWriting: URL(fileURLWithPath: outPath), settings: settings)
try outFile.write(from: outBuffer)
// Globals never deinit, so without close() the WAV header is never finalized.
outFile.close()
log(String(format: "%@: recorded %.1fs, peak %.3f, far lead-in %.1fs, far frames pulled %d/%d", vpio ? "vpio" : "raw",
           Double(tape.recCount) / rate, peak, leadIn, vpio ? tape.farPos : farCount, farCount))
