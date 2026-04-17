// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetalWhisper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MetalWhisper",
            targets: ["MetalWhisper", "CTranslate2", "OnnxRuntime"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "MetalWhisper",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.2.1/MetalWhisper.xcframework.zip",
            checksum: "d1615f2c47769756f178516ca1df4ad239dfa0e078d75d7d8cba068a8dc64591"
        ),
        .binaryTarget(
            name: "CTranslate2",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.2.1/CTranslate2.xcframework.zip",
            checksum: "da27870dfcfee559a8ed266ab6bdd4f4b793ad247d87eece304197aa554d9582"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.2.1/OnnxRuntime.xcframework.zip",
            checksum: "35330b28087ff005501b365b832a5d1c980491744422153d8abeb3cb5d0ee3e7"
        ),
    ]
)
