import AppKit
import SwiftUI

/// `Voxlet --render-previews <dir>` draws every settings page and the overlay states into PNGs offscreen,
/// so the UI can be checked even when the screen is locked.
enum PreviewRenderer {
    static func run(arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--render-previews"), arguments.count > index + 1 else { return 2 }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            for tab in SettingsTab.allCases {
                let navigation = SettingsNavigation()
                navigation.tab = tab
                render(
                    SettingsRootView(navigation: navigation),
                    size: NSSize(width: 820, height: 560),
                    appearance: appearance,
                    background: SettingsStyle.windowBackgroundNSColor,
                    to: directory.appendingPathComponent("settings-\(tab.rawValue)-\(suffix).png")
                )
            }
            // Taller renders show the parts of long pages that sit below the fold.
            for tab in [SettingsTab.general, .model] {
                let navigation = SettingsNavigation()
                navigation.tab = tab
                render(
                    SettingsRootView(navigation: navigation),
                    size: NSSize(width: 820, height: 1100),
                    appearance: appearance,
                    background: SettingsStyle.windowBackgroundNSColor,
                    to: directory.appendingPathComponent("settings-\(tab.rawValue)-full-\(suffix).png")
                )
            }
        }

        for (name, phase, text) in [
            ("overlay-recording", OverlayModel.Phase.recording, "板爷，明天下午三点我们开会讨论 Voxlet 的发布计划"),
            ("overlay-recording-compact", .recording, ""),
            ("overlay-processing", .processing, "After that, please send the pricing summary to the team."),
        ] {
            let model = OverlayModel()
            model.phase = phase
            model.transcript = text
            render(
                OverlayView(model: model, previewLevels: phase == .recording ? previewBars : nil),
                size: NSSize(width: 360, height: 140),
                appearance: .aqua,
                background: NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.72, alpha: 1),
                to: directory.appendingPathComponent("\(name).png")
            )
        }

        let controller = SettingsWindowController()
        controller.show(tab: .general)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        if let frame = NSApp.windows.first(where: { $0.contentViewController is NSHostingController<SettingsRootView> })?.frame {
            print("settings window frame after show: \(frame)")
        }
        return 0
    }

    /// A plausible voiced vowel: strong low bands, falling toward the top, mirrored like the live view.
    private static let previewBars = WaveformModel.mirrored([0.72, 0.95, 0.8, 0.58, 0.46, 0.3, 0.2, 0.1])

    private static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, background: NSColor, to url: URL) {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = background
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI finish its first layout and entrance animations.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        let canvas = NSImage(size: size, flipped: false) { rect in
            background.setFill()
            rect.fill()
            image.draw(in: rect)
            return true
        }
        guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
        print(url.path)
    }
}
