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
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.0/MetalWhisper.xcframework.zip",
            checksum: "9098e89579df93af88a00804ed5059bea79be2f3c0761c567ddb84355e3dd859"
        ),
        .binaryTarget(
            name: "CTranslate2",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.0/CTranslate2.xcframework.zip",
            checksum: "ad4a7b25727bef1cae48d88e8593fda80db8b2022eff88198824e1aa4638005e"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.0/OnnxRuntime.xcframework.zip",
            checksum: "b506d30bef10795de1280d3ae7b3eeb24d26e0038a5987a353d9b0e4bcc61cf2"
        ),
    ]
)
