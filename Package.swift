// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Dictator",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Parakeet TDT as CoreML on the Neural Engine. The only engine on macOS 14,
        // because Apple's SpeechTranscriber needs macOS 26. This is the last release
        // whose manifest Swift 5.10 can read.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.8.2")
    ],
    targets: [
        // Both macOS and Windows run the vectors in shared/dictionary-test-vectors.json.
        .target(
            name: "DictatorDictionary",
            path: "Sources/DictatorDictionary"
        ),
        .executableTarget(
            name: "Dictator",
            dependencies: [
                "DictatorDictionary",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Dictator"
        ),
        .testTarget(
            name: "DictatorDictionaryTests",
            dependencies: ["DictatorDictionary"],
            path: "Tests/DictatorDictionaryTests",
            resources: [.copy("dictionary-test-vectors.json")]
        ),
    ]
)
