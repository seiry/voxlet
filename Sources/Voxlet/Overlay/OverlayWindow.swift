import AppKit
import SwiftUI

/// A non-activating floating panel centred on the main screen, like Voxt's RecordingOverlayWindow.
final class OverlayWindowController {
    let model = OverlayModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var presentGeneration = 0

    func showRecording() {
        cancelHide()
        model.status = ""
        model.transcript = ""
        model.bands = []
        model.phase = .recording
        model.presentationID = UUID()
        present()
    }

    func showProcessing() {
        cancelHide()
        model.phase = .processing
        present()
    }

    func updateTranscript(_ text: String) {
        model.transcript = text
    }

    func updateSpectrum(_ bands: [Float]) {
        model.bands = bands
    }

    /// A one-line status under the bars that clears itself, Voxt's showOverlayStatus with a 2.4 s default.
    func showStatus(_ message: String, hideAfter delay: TimeInterval = 2.4) {
        cancelHide()
        if model.phase == .hidden {
            model.phase = .processing
            model.presentationID = UUID()
        }
        model.status = message
        present()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        cancelHide()
        guard let panel, panel.isVisible else {
            model.phase = .hidden
            return
        }
        let generation = presentGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A new session may have started during the fade; leave its panel alone.
            guard let self, self.presentGeneration == generation else { return }
            panel.orderOut(nil)
            self.model.phase = .hidden
            self.model.status = ""
        })
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func present() {
        presentGeneration += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Frame changes happen outside animations; Voxt notes animated setFrame crashes on macOS 26.
        panel.setFrame(frame(), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: frame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }

    private func frame() -> NSRect {
        let size = NSSize(width: Prefs.bool(Prefs.showRealtimeText) ? 360 : 220, height: 140)
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let inset = CGFloat(min(max(Prefs.double(Prefs.overlayEdgeDistance), 0), 120))
        let x = visible.midX - size.width / 2
        let y = Prefs.string(Prefs.overlayPosition) == OverlayPosition.top.rawValue
            ? visible.maxY - size.height - inset
            : visible.minY + inset
        return NSRect(origin: NSPoint(x: x.rounded(), y: y.rounded()), size: size)
    }
}
