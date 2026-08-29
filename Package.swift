// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingRecorder",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/MeetingRecorder",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
