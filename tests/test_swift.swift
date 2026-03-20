// Quick test: verify MetalWhisper is importable from Swift via module map
// Build: swiftc -I ../src -L . -lMetalWhisper -import-objc-header ../src/MetalWhisper.h test_swift.swift -o test_swift
// Run: ./test_swift /path/to/model /path/to/audio.flac

import Foundation

// Command line args
guard CommandLine.arguments.count >= 3 else {
    print("Usage: test_swift <model_path> <audio_path>")
    exit(1)
}

let modelPath = CommandLine.arguments[1]
let audioPath = CommandLine.arguments[2]

print("=== Swift Integration Test ===")
print("Model: \(modelPath)")
print("Audio: \(audioPath)")

// Load model
do {
    let transcriber = try MWTranscriber(modelPath: modelPath)
    print("Model loaded: multilingual=\(transcriber.isMultilingual), mels=\(transcriber.nMels)")

    // Create options
    let opts = MWTranscriptionOptions.defaults()
    opts.wordTimestamps = true
    print("Options: beam=\(opts.beamSize), temps=\(opts.temperatures)")

    // Transcribe
    let url = URL(fileURLWithPath: audioPath)
    var info: MWTranscriptionInfo?
    let segments = try transcriber.transcribeURL(
        url,
        language: nil,
        task: "transcribe",
        typedOptions: opts,
        segmentHandler: { segment, stop in
            print("  [streaming] \(segment.text)")
        },
        info: &info
    )

    print("\nResult: \(segments.count) segments")
    if let info = info {
        print("Language: \(info.language) (\(info.languageProbability))")
        print("Duration: \(info.duration)s")
    }

    for seg in segments {
        let start = String(format: "%.2f", seg.start)
        let end = String(format: "%.2f", seg.end)
        print("[\(start)-\(end)] \(seg.text)")

        if let words = seg.words {
            for word in words {
                let ws = String(format: "%.2f", word.start)
                let we = String(format: "%.2f", word.end)
                let prob = String(format: "%.0f%%", word.probability * 100)
                print("  [\(ws)-\(we)] \(prob) \(word.word)")
            }
        }
    }

    print("\n=== Swift Test PASSED ===")

} catch {
    print("ERROR: \(error.localizedDescription)")
    exit(1)
}
