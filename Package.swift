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
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.5/MetalWhisper.xcframework.zip",
            checksum: "56f3ef63bb0d7111b5cf06d07d5cce51407df07390ffeef06b3d37a93731a9f2"
        ),
        .binaryTarget(
            name: "CTranslate2",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.5/CTranslate2.xcframework.zip",
            checksum: "0bb44c957eea5151aefe5823c0fe6ba722e904fd2e4613454fdd5010c620df85"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.5/OnnxRuntime.xcframework.zip",
            checksum: "c0f0c57d0782a6dbac3b0065b70f28940c37188604217bffe0114a14851d68a0"
        ),
    ]
)
