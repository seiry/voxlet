import Foundation

/// `Voxlet --meeting-selftest --mic me.wav --browser them.wav --report out.json [--rollover 25]` runs a whole
/// meeting from two files through the same pipeline as a real one: mix, Live with rollover, labels, running notes,
/// offline pass, write-up, files. Pass `-meetingFolder <dir>` so it writes outside ~/Meetings.
enum MeetingSelfTest {
    static func run(arguments: [String]) -> Int32 {
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
        }
        guard let reportPath = value("--report") else {
            FileHandle.standardError.write(Data("usage: Voxlet --meeting-selftest (--mic f --browser f | --devices --browser-bundle id --seconds n) --report out.json\n".utf8))
            return 2
        }
        if arguments.contains("--devices") {
            return runOnDevices(bundle: value("--browser-bundle") ?? "com.apple.QuickTimePlayerX",
                                seconds: Double(value("--seconds") ?? "75") ?? 75, reportPath: reportPath)
        }
        guard let micPath = value("--mic"), let browserPath = value("--browser") else { return 2 }
        let rollover = value("--rollover").flatMap(Double.init)
        var report: [String: Any] = ["startedAt": ISO8601DateFormatter().string(from: Date())]
        let controller = MeetingController()
        var done = false
        var notesVersions = 0
        var notesDuringMeeting: MeetingNotes?

        do {
            let mic = try FileSource(url: URL(fileURLWithPath: micPath))
            let browser = try FileSource(url: URL(fileURLWithPath: browserPath))
            var finishedSources = 0
            let sourceDone = {
                DispatchQueue.main.async {
                    finishedSources += 1
                    // Both files ran out: give the last words a moment, then end the meeting as the user would.
                    if finishedSources == 2 {
                        notesVersions = controller.notesVersion
                        notesDuringMeeting = controller.notes
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { controller.end() }
                    }
                }
            }
            mic.onFinished = sourceDone
            browser.onFinished = sourceDone
            controller.onFinished = { folder, record in
                report["folder"] = folder.path
                report["record"] = recordJSON(record)
                report["liveTrace"] = controller.lastLiveTrace
                done = true
            }
            controller.onError = { message in
                report["error"] = message
                done = true
            }
            try controller.start(mic: mic, browser: browser, title: "E2E 会议", voiceProcessing: false, rolloverAfter: rollover)
            report["sessionsAtStart"] = 1
        } catch {
            report["error"] = error.localizedDescription
            done = true
        }

        let deadline = Date().addingTimeInterval(900)
        while !done, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        report["notesVersionsDuringMeeting"] = notesVersions
        report["notesDuringMeeting"] = notesDuringMeeting.map(encodable) ?? [:]
        report["timedOut"] = !done
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? data.write(to: URL(fileURLWithPath: reportPath))
        return report["error"] == nil && done ? 0 : 1
    }

    /// The real microphone (echo cancellation on speakers) and a tap of `bundle`, for `seconds`. Launch through
    /// `open -n` so the microphone and System Audio Recording grants are the app's.
    private static func runOnDevices(bundle: String, seconds: Double, reportPath: String) -> Int32 {
        var report: [String: Any] = ["startedAt": ISO8601DateFormatter().string(from: Date()), "browserBundle": bundle]
        let controller = MeetingController()
        var done = false
        controller.onFinished = { folder, record in
            report["folder"] = folder.path
            report["record"] = encodable(record)
            report["liveTrace"] = controller.lastLiveTrace
            done = true
        }
        controller.onError = { message in
            report["error"] = message
            done = true
        }
        if #available(macOS 26.0, *) {
            let voiceProcessing = !OutputRoute.isHeadphones
            report["voiceProcessing"] = voiceProcessing
            do {
                try controller.start(mic: MicrophoneSource(voiceProcessing: voiceProcessing), browser: BrowserSource(bundleIDs: [bundle]),
                                     title: "设备会议", voiceProcessing: voiceProcessing, rolloverAfter: 25)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    report["notesVersionsDuringMeeting"] = controller.notesVersion
                    report["browserHeardAtEnd"] = controller.browserHeard
                    controller.end()
                }
            } catch {
                report["error"] = error.localizedDescription
                done = true
            }
        } else {
            report["error"] = "needs macOS 26"
            done = true
        }
        let deadline = Date().addingTimeInterval(seconds + 600)
        while !done, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        report["timedOut"] = !done
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? data.write(to: URL(fileURLWithPath: reportPath))
        return report["error"] == nil && done ? 0 : 1
    }

    private static func recordJSON(_ record: MeetingRecord) -> Any {
        encodable(record)
    }

    private static func encodable<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }
}
