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
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/v0.2.0/MetalWhisper.xcframework.zip",
            checksum: "0432730c6b52bde4f638142080b332753044e12e7484e42cf20f2938349a6a75"
        ),
        .binaryTarget(
            name: "CTranslate2",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/v0.2.0/CTranslate2.xcframework.zip",
            checksum: "d22045c3945de202ee228033c7aadb94383c1e0ba4e5a45a8b61c17e189f2fbc"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/v0.2.0/OnnxRuntime.xcframework.zip",
            checksum: "58da43072dc8b81324e79e9a7c9d944b3d3fb5e3923e16737074c83508144db9"
        ),
    ]
)
