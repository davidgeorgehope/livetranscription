// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Cue",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Cue",
            path: "Sources/Cue",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Security")
            ]
        )
    ]
)
