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
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/v0.2.2/MetalWhisper.xcframework.zip",
            checksum: "d766475f687e3c4401324bb0a57577bda1b1e8b95cac697a965897b76af9a8ca"
        ),
        .binaryTarget(
            name: "CTranslate2",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/v0.2.2/CTranslate2.xcframework.zip",
            checksum: "994a1dc5757dcd2e28bb35689cf79ca289aab6e3f853f743b52b4934344e76ae"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/v0.2.2/OnnxRuntime.xcframework.zip",
            checksum: "308e065de2acb878c201857182c1ac0c7782028b6847dc241268ff4bcd4114d1"
        ),
    ]
)
