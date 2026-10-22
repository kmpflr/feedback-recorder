// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeedbackRecorder",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "FeedbackCore",
            path: "Sources/FeedbackCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "FeedbackRecorder",
            dependencies: ["FeedbackCore"],
            path: "Sources/FeedbackRecorder",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Speech"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "FeedbackCoreTests",
            dependencies: ["FeedbackCore"],
            path: "Tests/FeedbackCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
