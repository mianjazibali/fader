// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fader",
    platforms: [
        // 14.2 is the floor for the AudioObjectID-per-process API
        // (kAudioHardwarePropertyProcessObjectList et al.).
        .macOS("14.2")
    ],
    products: [
        .executable(name: "Fader", targets: ["Fader"])
    ],
    targets: [
        .executableTarget(
            name: "Fader",
            path: "Sources/Fader",
            exclude: [
                "Resources/Info.plist",
                "Resources/Fader.entitlements"
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
