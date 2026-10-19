// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Voxlet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Voxlet",
            path: "Sources/Voxlet",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
