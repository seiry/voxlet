import AVFoundation
import Foundation

/// `Voxlet --selftest <audio> [--out result.json]` streams a file through the same converter and Live session the
/// app uses, then writes a JSON report. Config comes from VOXLET_API_KEY / _PROVIDER / _PROJECT / _LOCATION / _MODEL.
enum SelfTest {
    static func run(arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--selftest"), arguments.count > index + 1 else {
            FileHandle.standardError.write(Data("usage: Voxlet --selftest <audio> [--out result.json]\n".utf8))
            return 2
        }
        let audioPath = arguments[index + 1]
        let outPath = arguments.firstIndex(of: "--out").flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
        let env = ProcessInfo.processInfo.environment
        let style = TranscriptionStyle(rawValue: env["VOXLET_STYLE"] ?? "") ?? .current

        let config = GeminiLiveConfig(
            provider: GeminiProvider(rawValue: env["VOXLET_PROVIDER"] ?? "") ?? .agentPlatform,
            apiKey: env["VOXLET_API_KEY"] ?? "",
            model: env["VOXLET_MODEL"] ?? GeminiLiveConfig.defaultModel,
            project: env["VOXLET_PROJECT"] ?? "",
            location: env["VOXLET_LOCATION"] ?? GeminiLiveConfig.defaultLocation,
            endpointOverride: env["VOXLET_ENDPOINT"] ?? "",
            languageCodes: RecognitionLanguage.codes(for: env["VOXLET_LANGUAGES"] ?? ""),
            // VOXLET_VOCABULARY (comma separated, may be empty) overrides the vocabulary file for repeatable runs.
            vocabulary: env["VOXLET_VOCABULARY"].map { $0.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty } }
                ?? VocabularyStore.shared.terms,
            mode: style.geminiMode
        )

        var report: [String: Any] = [
            "audioFile": audioPath,
            "provider": config.provider.rawValue,
            "endpoint": config.endpoint,
            "model": config.qualifiedModel,
            "vocabulary": config.vocabulary,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        var rawUsage: [[String: Any]] = []
        var interimCount = 0
        let started = Date()
        var setupAt: Date?
        var exitCode: Int32 = 1

        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
            let format = file.processingFormat
            report["sourceFormat"] = "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch"
            guard let converter = PCM16Converter(inputFormat: format) else { throw VoxletError("no converter") }

            let session = GeminiLiveSession(config: config)
            session.onSetupComplete = { setupAt = Date() }
            session.onTranscript = { _ in interimCount += 1 }
            session.onRawUsage = { rawUsage.append($0) }
            var runtimeError: Error?
            session.onFailure = { runtimeError = $0 }
            try session.start()

            // 1024-frame chunks like the mic tap delivers them, at real time unless VOXLET_SPEED says otherwise.
            let chunkFrames: AVAudioFrameCount = 1024
            let speed = max(Double(env["VOXLET_SPEED"] ?? "") ?? 1, 0.1)
            report["streamSpeed"] = speed
            let pace = Double(chunkFrames) / format.sampleRate / speed
            // The overlay's meter and spectrum over the same chunks, one entry per 100 ms window (peak, 0-9):
            // meterTrace is overall loudness, spectrumTrace is the 8 voice bands from low to high.
            var meter = AudioLevelMeter()
            let spectrum = SpectrumAnalyzer()
            var meterTrace = ""
            var spectrumTrace: [String] = []
            var windowPeak: Float = 0
            var bandPeaks = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
            var windowBytes = 0
            while file.framePosition < file.length, runtimeError == nil {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
                try file.read(into: buffer, frameCount: chunkFrames)
                if let pcm = converter.convert(buffer) {
                    session.sendAudio(pcm)
                    let loudness = meter.level(for: pcm)
                    let bands = spectrum.analyze(pcm, loudness: loudness)
                    windowPeak = max(windowPeak, loudness)
                    bandPeaks = zip(bandPeaks, bands).map { max($0, $1) }
                    windowBytes += pcm.count
                    if windowBytes >= 3200 {
                        meterTrace += String(min(9, Int(windowPeak * 10)))
                        spectrumTrace.append(bandPeaks.map { String(min(9, Int($0 * 10))) }.joined())
                        windowPeak = 0
                        bandPeaks = bandPeaks.map { _ in 0 }
                        windowBytes = 0
                    }
                }
                RunLoop.main.run(until: Date().addingTimeInterval(pace))
            }
            report["meterTrace"] = meterTrace
            report["spectrumTrace"] = spectrumTrace.joined(separator: " ")
            report["meterNoiseFloorDb"] = (meter.floorDb * 10).rounded() / 10
            if let runtimeError { throw runtimeError }

            let finishStarted = Date()
            var outcome: Result<GeminiLiveResult, Error>?
            session.finish { outcome = $0 }
            while outcome == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

            switch outcome! {
            case .success(let result):
                report["transcriptRaw"] = result.text
                report["transcript"] = style.apply(to: result.text)
                report["style"] = style.rawValue
                report["finishReason"] = result.finishReason
                report["finishLatencyMs"] = Int(Date().timeIntervalSince(finishStarted) * 1000)
                report["audioSeconds"] = (result.audioSeconds * 100).rounded() / 100
                report["usage"] = [
                    "audioInputTokens": result.usage.audioInputTokens,
                    "textInputTokens": result.usage.textInputTokens,
                    "outputTokens": result.usage.outputTokens,
                    "reportedByServer": result.usage.reported,
                ]
                report["estimatedCostUSD"] = Pricing.cost(of: result.usage)
                report["priceAudioInputPerMillion"] = Pricing.audioInputPerMillion
                report["priceTextOutputPerMillion"] = Pricing.textOutputPerMillion
                exitCode = result.text.isEmpty ? 1 : 0
            case .failure(let error):
                report["error"] = error.localizedDescription
            }
        } catch {
            report["error"] = error.localizedDescription
        }

        report["setupLatencyMs"] = setupAt.map { Int($0.timeIntervalSince(started) * 1000) } ?? NSNull()
        report["transcriptUpdates"] = interimCount
        report["rawUsageMessages"] = rawUsage
        report["passed"] = exitCode == 0

        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if let outPath { try? data.write(to: URL(fileURLWithPath: outPath)) }
        return exitCode
    }
}
