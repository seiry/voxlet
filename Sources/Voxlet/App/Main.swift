import AppKit

@main
enum VoxletMain {
    static func main() {
        Prefs.registerDefaults()
        let arguments = CommandLine.arguments
        if arguments.contains("--selftest") {
            exit(SelfTest.run(arguments: arguments))
        }
        if arguments.contains("--tap-selftest") {
            exit(TapSelfTest.run(arguments: arguments))
        }
        if arguments.contains("--render-previews") {
            exit(PreviewRenderer.run(arguments: arguments))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
