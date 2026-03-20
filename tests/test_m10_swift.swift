// tests/test_m10_swift.swift -- Swift integration tests for M10 (Swift bridging).
//
// Verifies that MetalWhisper.framework is importable from Swift and that the
// public API (MWTranscriber, MWTranscriptionOptions, segmentHandler, stop flag)
// works correctly through the Obj-C/Swift bridge.
//
// Build:
//   swiftc -F build -framework MetalWhisper \
//     -Xlinker -rpath -Xlinker build \
//     tests/test_m10_swift.swift -o build/test_m10_swift
//
// Run:
//   build/test_m10_swift <turbo_model_path> <data_dir>

import Foundation
import MetalWhisper

// -- Test counters & reporting ------------------------------------------------

var gPassCount = 0
var gFailCount = 0

func reportResult(_ name: String, passed: Bool, detail: String? = nil) {
    if passed {
        print("  PASS: \(name)")
        gPassCount += 1
    } else {
        let msg = detail ?? "(no detail)"
        print("  FAIL: \(name) -- \(msg)")
        gFailCount += 1
    }
}

/// Assert helper. Returns true if condition holds, false (and reports FAIL) otherwise.
@discardableResult
func assertTrue(_ name: String, _ condition: Bool, _ message: String) -> Bool {
    if !condition {
        reportResult(name, passed: false, detail: message)
        return false
    }
    return true
}

// -- Paths (set in main) ------------------------------------------------------

var gModelPath = ""
var gDataDir = ""

// -- Tests --------------------------------------------------------------------

func test_m10_swift_basic(transcriber: MWTranscriber) {
    let name = "m10_swift_basic"

    let audioPath = (gDataDir as NSString).appendingPathComponent("jfk.flac")
    let url = URL(fileURLWithPath: audioPath)

    guard FileManager.default.fileExists(atPath: audioPath) else {
        reportResult(name, passed: false, detail: "jfk.flac not found at \(audioPath)")
        return
    }

    do {
        var info: MWTranscriptionInfo?
        let segments = try transcriber.transcribeURL(
            url,
            language: nil,
            task: "transcribe",
            typedOptions: nil,
            segmentHandler: nil,
            info: &info
        )

        guard assertTrue(name, segments.count > 0, "expected non-empty segments") else { return }

        // Concatenate all segment texts
        let fullText = segments.map { $0.text }.joined()
        let lower = fullText.lowercased()

        print("    Text: \(fullText)")

        guard assertTrue(name, lower.contains("country"),
                         "text should contain 'country', got: \(fullText)") else { return }
        guard assertTrue(name, lower.contains("americans"),
                         "text should contain 'americans', got: \(fullText)") else { return }

        // Verify info is populated
        if let info = info {
            print("    Language: \(info.language) (\(String(format: "%.0f%%", info.languageProbability * 100)))")
            guard assertTrue(name, info.language == "en",
                             "expected language 'en', got '\(info.language)'") else { return }
        }

        reportResult(name, passed: true)
    } catch {
        reportResult(name, passed: false, detail: "transcribeURL threw: \(error.localizedDescription)")
    }
}

func test_m10_swift_streaming(transcriber: MWTranscriber) {
    let name = "m10_swift_streaming"

    let audioPath = (gDataDir as NSString).appendingPathComponent("jfk.flac")
    let url = URL(fileURLWithPath: audioPath)

    guard FileManager.default.fileExists(atPath: audioPath) else {
        reportResult(name, passed: false, detail: "jfk.flac not found at \(audioPath)")
        return
    }

    do {
        var callbackSegments: [MWTranscriptionSegment] = []

        let segments = try transcriber.transcribeURL(
            url,
            language: nil,
            task: "transcribe",
            typedOptions: nil,
            segmentHandler: { segment, _ in
                callbackSegments.append(segment)
            },
            info: nil
        )

        guard assertTrue(name, callbackSegments.count > 0,
                         "segmentHandler should be called at least once") else { return }

        print("    Callback count: \(callbackSegments.count), Return count: \(segments.count)")

        guard assertTrue(name, callbackSegments.count == segments.count,
                         "callback count \(callbackSegments.count) != return count \(segments.count)") else { return }

        // Verify the collected segments match the returned segments (same text)
        for i in 0..<segments.count {
            let returnedText = segments[i].text
            let callbackText = callbackSegments[i].text
            guard assertTrue(name, returnedText == callbackText,
                             "segment \(i) text mismatch: returned '\(returnedText)' vs callback '\(callbackText)'") else { return }
        }

        reportResult(name, passed: true)
    } catch {
        reportResult(name, passed: false, detail: "transcribeURL threw: \(error.localizedDescription)")
    }
}

func test_m10_swift_cancel(transcriber: MWTranscriber) {
    let name = "m10_swift_cancel"

    // Use physicsworks.wav (203s) -- a long audio file
    let audioPath = (gDataDir as NSString).appendingPathComponent("physicsworks.wav")
    let url = URL(fileURLWithPath: audioPath)

    guard FileManager.default.fileExists(atPath: audioPath) else {
        reportResult(name, passed: false, detail: "physicsworks.wav not found at \(audioPath)")
        return
    }

    // First, transcribe without stop to get the full segment count for comparison.
    let fullSegmentCount: Int
    do {
        let fullSegments = try transcriber.transcribeURL(
            url,
            language: "en",
            task: "transcribe",
            typedOptions: nil,
            segmentHandler: nil,
            info: nil
        )
        fullSegmentCount = fullSegments.count
        print("    Full transcription segments: \(fullSegmentCount)")
    } catch {
        reportResult(name, passed: false, detail: "full transcription failed: \(error.localizedDescription)")
        return
    }

    // Now transcribe with early stop after first callback.
    do {
        var callbackCount = 0

        let segments = try transcriber.transcribeURL(
            url,
            language: "en",
            task: "transcribe",
            typedOptions: nil,
            segmentHandler: { segment, stop in
                callbackCount += 1
                // Stop after first segment callback
                stop.pointee = true
            },
            info: nil
        )

        print("    Cancelled segments: \(segments.count), Callbacks: \(callbackCount)")

        // The stop flag is set after the first callback. The implementation adds
        // all segments from the current ~30s chunk before calling handlers, so the
        // returned array includes all segments from the first chunk. But subsequent
        // chunks are skipped entirely.
        guard assertTrue(name, callbackCount == 1,
                         "expected exactly 1 callback before stop, got \(callbackCount)") else { return }

        // The cancelled run must produce strictly fewer segments than the full run.
        // A 203s file has ~7 chunks; stopping after the first chunk's segments
        // should yield far fewer segments than the full transcription.
        guard assertTrue(name, segments.count < fullSegmentCount,
                         "expected fewer segments than full (\(fullSegmentCount)), got \(segments.count)") else { return }

        // Verify we got some text (transcription before stop was honoured)
        let fullText = segments.map { $0.text }.joined()
        guard assertTrue(name, fullText.count > 0,
                         "should have some text before cancellation") else { return }

        print("    Cancelled text: \(fullText.prefix(100))...")

        reportResult(name, passed: true)
    } catch {
        reportResult(name, passed: false, detail: "transcribeURL threw: \(error.localizedDescription)")
    }
}

// -- Main ---------------------------------------------------------------------

func main() {
    // Unbuffered stdout for immediate PASS/FAIL visibility
    setbuf(stdout, nil)

    let args = CommandLine.arguments
    if args.count < 3 {
        fputs("Usage: test_m10_swift <turbo_model_path> <data_dir>\n", stderr)
        exit(1)
    }

    gModelPath = args[1]
    gDataDir = args[2]

    print("=== M10 Swift Integration Tests ===")
    print("Model: \(gModelPath)")
    print("Data:  \(gDataDir)")
    print()

    // Load model
    print("Loading turbo model...")
    let transcriber: MWTranscriber
    do {
        transcriber = try MWTranscriber(modelPath: gModelPath)
    } catch {
        fputs("FATAL: Failed to load model: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    print("Model loaded.\n")

    // Run tests
    test_m10_swift_basic(transcriber: transcriber)
    test_m10_swift_streaming(transcriber: transcriber)
    test_m10_swift_cancel(transcriber: transcriber)

    // Summary
    print("\n=== M10 Results: \(gPassCount) passed, \(gFailCount) failed ===")
    exit(gFailCount > 0 ? 1 : 0)
}

main()
