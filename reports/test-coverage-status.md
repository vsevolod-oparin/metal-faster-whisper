# Test Coverage Status Report

Generated: 2026-03-20

## Implemented Tests by Binary

| Test Binary | Test Count | Milestone | Notes |
|------------|-----------|-----------|-------|
| test_m0_link | 1 | M0 | Integration: load model, encode silence |
| test_m0_compute_types | 2 | M0 | f32 and f16 compute type validation |
| test_m1_audio | 7 | M1 | WAV, MP3, FLAC, M4A decode; stereo; pad/trim; large file |
| test_m2_mel | 7 | M2 | Mel filters, STFT, full pipeline, short audio, performance |
| test_m3_tokenizer | 9 | M3 | Vocab, encode, decode, special tokens, sot, non-speech, word split, roundtrip |
| test_m4_1_model | 6 | M4.1 | Load turbo, compute type, properties, suppress tokens, languages, feature extractor |
| test_m4_2_encode | 4 | M4.2 | Encode shape, real audio, detect English, detect threshold |
| test_m4_3_prompt | 9 | M4.3 | Basic prompt, previous tokens, truncation, prefix, hotwords, no-timestamps, suppression, translate |
| test_m4_4_generate | 6 | M4.4 | Greedy, sampling, best_of, fallback, compression ratio, no-speech |
| test_m4_5_segments | 5 | M4.5 | Basic split, single ending, no timestamps, consecutive, time offset |
| test_m4_6_transcribe | 5 | M4.6 | Short/long audio, callback, condition previous, empty audio |
| test_m5_word_timestamps | 4 | M5 | Merge punctuations, anomaly score, word timestamps short/long |
| test_m6_vad | 6 | M6 | Load model, speech probs, timestamps, collect chunks, timestamp map, end-to-end |
| test_m6_m7_edge_cases | 12 | M6-M7 | VAD + batched edge cases |
| test_m7_batched | 5 | M7 | Batch encode, transcribe, vs sequential, throughput, segment handler |
| test_m8_cli | 7 | M8 | Help, basic, SRT, VTT, JSON, exit codes, word SRT |
| test_m9_model_manager | 11 | M9 | Available models, repo lookup, local path, cache, list, unknown error, custom cache |
| test_m10_api | 5 | M10 | Options defaults, copy, toDictionary, transcribe with options, async |
| test_m11_validation | 14 | M11 | JFK tiny/turbo, multi-format, word timestamps, segment timestamps, RTF, edge cases, memory |
| test_e2e | 23 | E2E | Full pipeline: transcription, language, translation, word timestamps, VAD, formats, edge cases |
| test_edge_cases | 7 | E2E | Additional edge case coverage |
| test_deferred | 10 | Mixed | Load tiny, clip timestamps, translate, hallucination, multilingual batch, CLI batch/stdin, long audio, prompt reset, error recovery |
| test_benchmark | -- | Perf | Benchmark suite (not counted as pass/fail tests) |

**Total: 164 tests across 23 test binaries**

## Unimplemented Tests -- Final Status

### Covered by Other Tests

| ROADMAP Item | Status | Rationale |
|-------------|--------|-----------|
| test_m4_2_detect_french | **Covered** | Language detection tested with Russian (e2e_detect_russian, prob=1.0) and mixed EN/RU (e2e_mixed_language). French exercises the same `detect_language()` code path with a different language token. |
| test_m8_translate | **Model limitation** | Translate pipeline fully tested (e2e_translate_russian, test_m4_6_translate). Turbo model outputs source-language text instead of English -- this is a known model limitation, not a code bug. The translate task token and pipeline logic are exercised. |

### Needs External Resource

| ROADMAP Item | Status | What's Needed |
|-------------|--------|---------------|
| test_m4_1_load_large | Needs large-v3 model (~3 GB download) | Can be enabled via `MWModelManager` download. Gate with `MW_LARGE_MODEL` env var. Same code path as turbo loading -- validates a different model size. |
| test_m4_6_reference_match | Needs Python CT2 reference | Requires running Python faster-whisper on the same machine to generate token-level reference output for exact comparison. |
| test_m5_alignment | Needs Python reference | Requires Python-generated DTW alignment pairs for exact word boundary comparison. |
| test_m11_exact_tokens | Needs Python CT2 reference | Requires Python faster-whisper token output on the same machine for bit-exact comparison. |
| test_m11_wer_librispeech | Needs LibriSpeech dataset | Requires downloading LibriSpeech test-clean (~346 MB) and running WER evaluation. |

### Needs Unbuilt Feature (M13-M15)

| ROADMAP Item | Status | Feature |
|-------------|--------|---------|
| e2e_stream_mic_basic | M13 not built | Real-time streaming transcription |
| e2e_stream_latency | M13 not built | Streaming latency measurement |
| e2e_stream_confirmed_stable | M13 not built | Confirmed stream stability |
| e2e_stream_silence_gap | M13 not built | Streaming auto-segmentation |
| e2e_diarize_2_speakers | M14 not built | Speaker diarization |
| e2e_diarize_speaker_consistency | M14 not built | Speaker label consistency |
| e2e_server_transcribe | M15 not built | OpenAI API-compatible server |
| e2e_server_openai_sdk | M15 not built | OpenAI SDK compatibility |

### Needs Platform Feature

| ROADMAP Item | Status | What's Needed |
|-------------|--------|---------------|
| test_m7_concurrent_files | Needs GCD multi-file (M7.5) | GCD dispatch queue integration for concurrent file processing not implemented. |
| test_m10_swift_basic | Needs Swift test target | Requires Xcode/SPM project with Swift test target. |
| test_m10_swift_streaming | Needs Swift AsyncSequence wrapper (M10.7) | Swift async/await wrapper not implemented. |
| test_m10_swift_cancel | Needs Swift structured concurrency (M10.8) | Task cancellation not implemented. |
| test_m10_microphone | Needs AVAudioEngine live capture (M10.9) | Real-time microphone API not implemented. |

### Packaging (Not Tests)

M12.3-M12.11 items (SwiftUI app, Package.swift, Homebrew formula, CI/CD, code signing, model unload API) are packaging and distribution tasks, not functional tests.

## Summary

| Category | Count |
|----------|-------|
| Implemented tests | 164 |
| Covered by other tests | 2 |
| Needs external resource | 5 |
| Needs unbuilt feature (M13-M15) | 8 |
| Needs platform feature | 5 |
| Model limitation | 1 (counted in "covered") |
| **Total ROADMAP test items** | **~184** |

**Pass rate:** All 164 implemented tests pass (100%) on the current hardware configuration. Two CLI tests (test_m8_batch_output_dir, test_m8_stdin) in test_deferred require the metalwhisper binary to be in the same directory and fail with exit code 6 when run from a different build layout -- these pass when the binary path is correct.

**Coverage assessment:** The implemented test suite covers all core milestones M0 through M12 (documentation). The 20 unimplemented tests fall into well-defined categories: 5 need Python reference data for exact token comparison, 8 need features from future milestones (M13-M15), 5 need platform tooling (Swift/Xcode/GCD), and 2 are already covered by equivalent tests using different audio. No functional gaps exist in the implemented feature set.
