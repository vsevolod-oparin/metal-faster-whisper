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
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.3/MetalWhisper.xcframework.zip",
            checksum: "85956620df54b70c3d9f9c157c4941d64424b4fb3b8409820328081a3285b499"
        ),
        .binaryTarget(
            name: "CTranslate2",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.3/CTranslate2.xcframework.zip",
            checksum: "8d2ca0e8e6a7de211bd8206aba2064834267358fcc6d69a2ead74a56d82e8907"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.3/OnnxRuntime.xcframework.zip",
            checksum: "c16ddd3eb8d8e61b0a14dd31cc72352525f72ff4e8d76d1c2c25ca389ab1f77e"
        ),
    ]
)
