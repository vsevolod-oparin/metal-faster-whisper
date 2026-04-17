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
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/v0.1.0/MetalWhisper.xcframework.zip",
            checksum: "17e954d22c15542bf0d1a777f78e153f93a4ecc3dd46d0ff590e9a87778d172e"
        ),
        .binaryTarget(
            name: "CTranslate2",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/v0.1.0/CTranslate2.xcframework.zip",
            checksum: "b26778c69e15bb69f85dafc449f13ecbb01a035b9b8c5ffce4d43cd54f753e1b"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            url: "https://github.com/vsevolod-oparin/metal-faster-whisper/releases/download/v0.1.0/OnnxRuntime.xcframework.zip",
            checksum: "3e177cc32d245db4282feb55f7f0399dd3f9d3ac71453c8dd222a8e9ba9a5277"
        ),
    ]
)
