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
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.2/MetalWhisper.xcframework.zip",
            checksum: "bd97f361237cd52b7f3192448321f2795d5b5200a231c62af78b387143de6828"
        ),
        .binaryTarget(
            name: "CTranslate2",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.2/CTranslate2.xcframework.zip",
            checksum: "13139b5099f87a59ff0792fe5ef555d1e1ab39e1cabe29fe04f8172fa1991a2c"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.2/OnnxRuntime.xcframework.zip",
            checksum: "152b1f663f9c4c5caa9900f1550bbb0e3758c29f328dc7c52c999b5e347f60e1"
        ),
    ]
)
