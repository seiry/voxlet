import AVFoundation
import Foundation

enum MeetingSide: String, Codable {
    case me
    case them
}

/// Where one side of the meeting comes from: the microphone, the browser tap, or a file in the self-test.
protocol MeetingAudioSource: AnyObject {
    var sampleRate: Double { get }
    /// Mono float samples, on any thread.
    var onSamples: ((UnsafeBufferPointer<Float>) -> Void)? { get set }
    func start() throws
    func stop()
}

final class MicrophoneSource: MeetingAudioSource {
    let microphone = MeetingMicrophone()
    let voiceProcessing: Bool
    var sampleRate: Double { MeetingMicrophone.sampleRate }
    var onSamples: ((UnsafeBufferPointer<Float>) -> Void)? {
        get { microphone.onSamples }
        set { microphone.onSamples = newValue }
    }

    init(voiceProcessing: Bool) { self.voiceProcessing = voiceProcessing }
    func start() throws { try microphone.start(voiceProcessing: voiceProcessing) }
    func stop() { microphone.stop() }
}

@available(macOS 14.2, *)
final class BrowserSource: MeetingAudioSource {
    let tap = BrowserAudioTap()
    let bundleIDs: [String]
    var sampleRate: Double { tap.sampleRate }
    var onSamples: ((UnsafeBufferPointer<Float>) -> Void)? {
        get { tap.onSamples }
        set { tap.onSamples = newValue }
    }

    init(bundleIDs: [String]) { self.bundleIDs = bundleIDs }
    func start() throws { try tap.start(.bundleIDs(bundleIDs)) }
    func stop() { tap.stop() }
}

/// Plays a file into the pipeline in real time (or `speed` times faster), for the headless self-test.
final class FileSource: MeetingAudioSource {
    private let samples: [Float]
    private let speed: Double
    private var timer: DispatchSourceTimer?
    private var position = 0
    let sampleRate: Double
    var onSamples: ((UnsafeBufferPointer<Float>) -> Void)?
    var onFinished: (() -> Void)?

    init(url: URL, speed: Double = 1) throws {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw VoxletError("Cannot read \(url.lastPathComponent)") }
        try file.read(into: input)
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 48_000 / file.processingFormat.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw VoxletError("buffer") }
        var fed = false
        converter.convert(to: output, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        sampleRate = 48_000
        self.speed = speed
    }

    func start() throws {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "voxlet.file-source"))
        let block = Int(sampleRate * 0.02)
        timer.schedule(deadline: .now(), repeating: 0.02 / speed)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let end = min(self.samples.count, self.position + block)
            if self.position >= end {
                self.timer?.cancel()
                self.onFinished?()
                return
            }
            self.samples[self.position..<end].withUnsafeBufferPointer { self.onSamples?($0) }
            self.position = end
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// One side of the meeting on disk as AAC, plus its 16 kHz s16le copy for the live mix.
final class MeetingTrack {
    let side: MeetingSide
    let url: URL
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private let converter: PCM16Converter
    private(set) var seconds: Double = 0
    var onPCM16: ((Data) -> Void)?

    init(side: MeetingSide, url: URL, sampleRate: Double, queue: DispatchQueue) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = PCM16Converter(inputFormat: format)
        else { throw VoxletError("Unsupported sample rate \(sampleRate)") }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.side = side
        self.url = url
        self.format = format
        self.converter = converter
        self.queue = queue
    }

    /// Copies off the audio thread first; everything else happens on the pipeline queue.
    func append(_ samples: UnsafeBufferPointer<Float>) {
        let copy = Array(samples)
        queue.async { [self] in
            guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(copy.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(copy.count)
            copy.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: copy.count) }
            try? file.write(from: buffer)
            seconds += Double(copy.count) / format.sampleRate
            if let pcm = converter.convert(buffer) { onPCM16?(pcm) }
        }
    }

    /// Call on the pipeline queue, after the last append was queued there.
    func close() {
        dispatchPrecondition(condition: .onQueue(queue))
        if #available(macOS 15.0, *) { file?.close() }
        file = nil
    }
}

/// Lines up both sides every 100 ms and mixes them into the one stream Gemini hears, passing each side's level
/// along so turns can be cut by who is talking. Runs on the pipeline queue.
final class MeetingMixer {
    static let chunkSeconds = 0.1
    static let chunkSamples = 1_600

    /// The mixed chunk, the meeting time at its end, and each side's level in dBFS.
    var onChunk: ((Data, TimeInterval, Float, Float) -> Void)?
    private var fifo: [MeetingSide: [Int16]] = [.me: [], .them: []]
    private var timer: DispatchSourceTimer?
    private let queue: DispatchQueue
    private(set) var chunkIndex = 0
    var isPaused = false

    init(queue: DispatchQueue) { self.queue = queue }

    var now: TimeInterval { Double(chunkIndex) * Self.chunkSeconds }

    func push(_ pcm: Data, side: MeetingSide) {
        guard !isPaused else { return }
        pcm.withUnsafeBytes { raw in fifo[side, default: []].append(contentsOf: raw.bindMemory(to: Int16.self)) }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.chunkSeconds, repeating: Self.chunkSeconds, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// The microphone always delivers, so it is the clock; the tap delivers nothing while the browser is silent.
    private func tick() {
        guard !isPaused else { return }
        while fifo[.me]!.count >= Self.chunkSamples { emitChunk() }
        // Clock drift between the two devices: keep the browser side at most 500 ms ahead.
        if fifo[.them]!.count > 8_000 { fifo[.them]!.removeFirst(fifo[.them]!.count - 3_200) }
    }

    private func emitChunk() {
        let me = take(.me)
        let them = take(.them)
        var mixed = [Int16](repeating: 0, count: Self.chunkSamples)
        for i in 0..<Self.chunkSamples {
            mixed[i] = Int16(clamping: Int32(me[i]) + Int32(them[i]))
        }
        chunkIndex += 1
        let data = mixed.withUnsafeBufferPointer { Data(buffer: $0) }
        onChunk?(data, now, Self.dbfs(me), Self.dbfs(them))
    }

    private func take(_ side: MeetingSide) -> [Int16] {
        var buffer = fifo[side]!
        let n = min(Self.chunkSamples, buffer.count)
        var out = Array(buffer.prefix(n))
        buffer.removeFirst(n)
        fifo[side] = buffer
        if out.count < Self.chunkSamples { out += [Int16](repeating: 0, count: Self.chunkSamples - out.count) }
        return out
    }

    private static func dbfs(_ samples: [Int16]) -> Float {
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = sqrt(sum / Double(max(samples.count, 1))) / 32_768
        return Float(20 * log10(rms + 1e-9))
    }
}
