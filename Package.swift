// swift-tools-version: 5.9
// Package.swift — SPM manifest for MetalWhisper
//
// MetalWhisper is distributed as pre-built xcframeworks because the source
// is Obj-C++ with C++ dependencies (CTranslate2, ONNX Runtime) that SPM
// cannot compile directly.
//
// Setup:
//   1. Run: ./scripts/setup_dependencies.sh     (downloads CT2, ORT, VAD model)
//   2. Run: mkdir -p build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make
//   3. Run: ./scripts/build_xcframeworks.sh      (creates .xcframework bundles)
//   4. Now you can use this package:
//        .package(path: "/path/to/metal-faster-whisper")
//
// Or for binary distribution, host the xcframeworks as release artifacts and
// use .binaryTarget(url:checksum:) instead of .binaryTarget(path:).

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
        // Pre-built xcframeworks (local paths — for binary distribution,
        // replace with .binaryTarget(url:checksum:) pointing to release assets).
        .binaryTarget(
            name: "MetalWhisper",
            path: "build/xcframeworks/MetalWhisper.xcframework"
        ),
        .binaryTarget(
            name: "CTranslate2",
            path: "build/xcframeworks/CTranslate2.xcframework"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            path: "build/xcframeworks/OnnxRuntime.xcframework"
        ),
    ]
)
