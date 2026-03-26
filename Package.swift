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
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.1/MetalWhisper.xcframework.zip",
            checksum: "ca85823234d1332a8419d70218489e3c11aea4ab8174c18a2cbff866932b34cc"
        ),
        .binaryTarget(
            name: "CTranslate2",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.1/CTranslate2.xcframework.zip",
            checksum: "cc066d7b7ad08e283754ad1fc58a660cdac1d97011381c0babf2e13de7433ff2"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.1/OnnxRuntime.xcframework.zip",
            checksum: "62b598361b8e456f22ab6ac6406db33754fdb725f533ec27721b553eaa6f8fd8"
        ),
    ]
)
