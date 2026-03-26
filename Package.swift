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
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.4/MetalWhisper.xcframework.zip",
            checksum: "81eeed88e255654af564717fa0797ff67a990a7a06b98e2be66fce8a4df2b364"
        ),
        .binaryTarget(
            name: "CTranslate2",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.4/CTranslate2.xcframework.zip",
            checksum: "832a92090e3c5257ea2b6a683228b21e7b03a968bf481f5cd4fc9865faf87908"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/0.1.4/OnnxRuntime.xcframework.zip",
            checksum: "a5bc48e19d5c29012ffd31146f1044534d5a89c39a804107bb3cc1a87657a213"
        ),
    ]
)
