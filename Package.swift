// swift-tools-version: 6.0
import PackageDescription

// One package, four targets:
//   MeetingCore     pure Swift — models, prompts, Markdown, provider protocols. Shared by every client and the hub.
//   MeetingEngine   the processing stack — on-device transcription (FluidAudio, Apple platforms), summarizers.
//   MeetingRecorder the macOS app (capture + client).
//   meetinghub      the self-hosted server that does the processing and holds the data.
let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MeetingCore", targets: ["MeetingCore"]),
        .library(name: "MeetingEngine", targets: ["MeetingEngine"]),
        .executable(name: "MeetingRecorder", targets: ["MeetingRecorder"]),
        .executable(name: "meetinghub", targets: ["MeetingHub"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "MeetingCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MeetingEngine",
            dependencies: [
                "MeetingCore",
                .product(name: "FluidAudio", package: "FluidAudio", condition: .when(platforms: [.macOS])),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MeetingRecorder",
            dependencies: ["MeetingCore", "MeetingEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MeetingHub",
            dependencies: [
                "MeetingCore",
                "MeetingEngine",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
