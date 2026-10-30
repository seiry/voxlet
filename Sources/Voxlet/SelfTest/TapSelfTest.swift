import Foundation

/// `Voxlet --tap-selftest (--pid <pid> | --bundle <id>) --seconds <n> --out <report.json>` taps one app for a
/// while and reports what arrived. Launch it with `open -n` so the System Audio Recording grant is Voxlet's.
enum TapSelfTest {
    static func run(arguments: [String]) -> Int32 {
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
        }
        let seconds = Double(value("--seconds") ?? "5") ?? 5
        var report: [String: Any] = ["startedAt": ISO8601DateFormatter().string(from: Date())]
        var exitCode: Int32 = 1
        if #available(macOS 14.2, *) {
            let target: BrowserAudioTap.Target
            if let pid = value("--pid").flatMap(Int32.init) {
                target = .pids([pid])
                report["target"] = "pid \(pid)"
            } else {
                let id = value("--bundle") ?? "org.mozilla.firefoxdeveloperedition"
                target = .bundleIDs([id])
                report["target"] = id
            }
            let tap = BrowserAudioTap()
            let lock = NSLock()
            var frames = 0
            var peak: Float = 0
            var sumSquares = 0.0
            var callbacks = 0
            let started = Date()
            var firstCallbackMs: Int?
            tap.onSamples = { buffer in
                lock.lock()
                callbacks += 1
                if firstCallbackMs == nil { firstCallbackMs = Int(Date().timeIntervalSince(started) * 1000) }
                frames += buffer.count
                for sample in buffer {
                    peak = max(peak, abs(sample))
                    sumSquares += Double(sample * sample)
                }
                lock.unlock()
            }
            // --vpio runs the meeting microphone with voice processing in this same process, as a meeting does.
            let mic = MeetingMicrophone()
            var micFrames = 0
            mic.onSamples = { buffer in
                lock.lock()
                micFrames += buffer.count
                lock.unlock()
            }
            do {
                if arguments.contains("--vpio") { try mic.start(voiceProcessing: true) }
                try tap.start(target)
                RunLoop.main.run(until: Date().addingTimeInterval(seconds))
                tap.stop()
                mic.stop()
                report["micSeconds"] = Double(micFrames) / MeetingMicrophone.sampleRate
                lock.lock()
                let rms = frames > 0 ? sqrt(sumSquares / Double(frames)) : 0
                report["sampleRate"] = tap.sampleRate
                report["tapFormat"] = tap.formatDescription
                report["firstDelivery"] = tap.firstDelivery ?? "none"
                report["callbacks"] = callbacks
                report["seconds"] = Double(frames) / tap.sampleRate
                report["peak"] = Double(peak)
                report["rmsDBFS"] = 20 * log10(rms + 1e-9)
                report["firstCallbackMs"] = firstCallbackMs ?? -1
                lock.unlock()
                exitCode = peak > 0.001 ? 0 : 3
            } catch {
                report["error"] = error.localizedDescription
            }
        } else {
            report["error"] = "needs macOS 14.2"
        }
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        if let out = value("--out") {
            try? data.write(to: URL(fileURLWithPath: out))
        } else {
            FileHandle.standardOutput.write(data)
        }
        return exitCode
    }
}
