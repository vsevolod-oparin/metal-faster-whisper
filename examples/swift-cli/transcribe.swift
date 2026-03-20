#!/usr/bin/env swift
// transcribe.swift — Minimal MetalWhisper example in pure Swift
//
// Build (after running ./scripts/build_framework.sh):
//   swiftc -F ../../build -framework MetalWhisper \
//     -Xlinker -rpath -Xlinker ../../build \
//     -Xlinker -rpath -Xlinker ../../third_party/ctranslate2-mps/lib \
//     -Xlinker -rpath -Xlinker ../../third_party/onnxruntime-osx-arm64-1.21.0/lib \
//     transcribe.swift -o transcribe
//
// Run:
//   ./transcribe --model turbo audio.mp3
//   ./transcribe --model /path/to/model audio.wav --words
//   ./transcribe --model tiny audio.flac --language ru --task translate

import Foundation
import MetalWhisper

// ── Argument parsing ─────────────────────────────────────────────────────

var modelPath: String?
var audioFiles: [String] = []
var language: String? = nil
var task = "transcribe"
var wordTimestamps = false

var i = 1
while i < CommandLine.arguments.count {
    let arg = CommandLine.arguments[i]
    switch arg {
    case "--model":
        i += 1; modelPath = CommandLine.arguments[i]
    case "--language":
        i += 1; language = CommandLine.arguments[i]
    case "--task":
        i += 1; task = CommandLine.arguments[i]
    case "--words":
        wordTimestamps = true
    case "--help", "-h":
        print("""
        Usage: transcribe [OPTIONS] <audio_file> [audio_file2 ...]

        Options:
          --model <path|alias>   Model path or alias (tiny, base, turbo, etc.)
          --language <code>      Language code (default: auto-detect)
          --task <task>          transcribe (default) or translate
          --words                Show word-level timestamps
          --help                 Show this help
        """)
        exit(0)
    default:
        audioFiles.append(arg)
    }
    i += 1
}

guard let model = modelPath else {
    fputs("Error: --model is required\n", stderr)
    exit(1)
}
guard !audioFiles.isEmpty else {
    fputs("Error: No audio files specified\n", stderr)
    exit(1)
}

// ── Resolve model (supports aliases like "tiny", "turbo") ────────────────

let manager = MWModelManager.shared()
let resolvedPath: String
do {
    resolvedPath = try manager.resolveModel(model, progress: { bytes, total, name in
        if total > 0 {
            let pct = Double(bytes) / Double(total) * 100
            fputs(String(format: "\rDownloading %@: %.0f%%", name, pct), stderr)
        }
    })
    fputs("\n", stderr)
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

// ── Load model ───────────────────────────────────────────────────────────

let transcriber: MWTranscriber
do {
    transcriber = try MWTranscriber(modelPath: resolvedPath)
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

// ── Configure options ────────────────────────────────────────────────────

let opts = MWTranscriptionOptions.defaults()
opts.wordTimestamps = wordTimestamps

// ── Transcribe each file ─────────────────────────────────────────────────

for audioFile in audioFiles {
    let url = URL(fileURLWithPath: audioFile)

    do {
        var info: MWTranscriptionInfo?
        let segments = try transcriber.transcribeURL(
            url,
            language: language,
            task: task,
            typedOptions: opts,
            segmentHandler: nil,
            info: &info
        )

        if let info = info {
            fputs("[\(info.language) \(String(format: "%.0f%%", info.languageProbability * 100))] \(audioFile) (\(String(format: "%.1f", info.duration))s)\n", stderr)
        }

        for seg in segments {
            let start = formatTime(seg.start)
            let end = formatTime(seg.end)
            print("[\(start) → \(end)] \(seg.text)")

            if wordTimestamps, let words = seg.words {
                for w in words {
                    let ws = formatTime(w.start)
                    let conf = String(format: "%3.0f%%", w.probability * 100)
                    print("  \(ws) \(conf) \(w.word)")
                }
            }
        }
    } catch {
        fputs("Error transcribing \(audioFile): \(error.localizedDescription)\n", stderr)
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────

func formatTime(_ seconds: Float) -> String {
    let s = max(0, seconds)
    let m = Int(s) / 60
    let sec = Int(s) % 60
    let ms = Int((s - Float(Int(s))) * 100)
    return String(format: "%02d:%02d.%02d", m, sec, ms)
}
