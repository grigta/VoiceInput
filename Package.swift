// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "vendor/whisper.cpp"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceInput",
            dependencies: [
                .product(name: "whisper", package: "whisper.cpp"),
            ],
            path: "Sources/VoiceInput"
        ),
    ]
)
