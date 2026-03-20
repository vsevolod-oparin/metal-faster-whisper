# MetalWhisper Test Suite Audit

**Date:** 2026-03-20
**Auditor:** Claude Code (automated analysis)

---

## 1. Test Inventory

### test_m0_link (1 test)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `main` (single flow) | Model loads on Metal, encodeSilenceTest succeeds, prints shape |

### test_m0_compute_types (1 test, 4 sub-cases)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `main` loop | f32 and f16 load+encode succeed; int8 and int8_float16 fail as expected |

### test_m1_audio (7 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m1_wav_decode` | 203s WAV: exact sample count, first 100 samples within 1e-4 |
| 2 | `test_m1_mp3_decode` | 4s MP3: sample count within 1% of reference |
| 3 | `test_m1_flac_decode` | 11s FLAC: exact sample count, first 100 samples within 1e-4 |
| 4 | `test_m1_m4a_decode` | 11s M4A: sample count within 5% of FLAC reference |
| 5 | `test_m1_stereo_mono` | 5s stereo WAV: correct mono downmix, first 100 samples match |
| 6 | `test_m1_pad_or_trim` | Padding and trimming match Python reference exactly |
| 7 | `test_m1_large_file` | 83-min MP3: streaming decode, RSS growth < 3x output (skipped if no file) |

### test_m2_mel (7 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m2_mel_filters` | 80-mel filterbank matches Python within 1e-6 |
| 2 | `test_m2_mel_filters_128` | 128-mel filterbank matches Python within 1e-6 |
| 3 | `test_m2_stft` | 440Hz sine: frame count, mel value range [-2, 2] |
| 4 | `test_m2_full_pipeline` | 30s audio -> mel (80 mels) matches Python within 1e-4 |
| 5 | `test_m2_full_pipeline_128` | 30s audio -> mel (128 mels) matches Python within 1e-4 |
| 6 | `test_m2_short_audio` | 5s audio -> (80, 501) shape, matches reference within 1e-4 |
| 7 | `test_m2_performance` | 30s audio mel timing (informational, no threshold) |

### test_m3_tokenizer (9 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m3_load_vocab` | Vocab size = 51866 |
| 2 | `test_m3_encode` | 10 test strings: token IDs match Python exactly |
| 3 | `test_m3_decode` | Known token sequences decode to matching text |
| 4 | `test_m3_special_tokens` | sot, eot, noTimestamps, timestampBegin, etc. match Python |
| 5 | `test_m3_sot_sequence` | English transcribe SOT sequence matches Python |
| 6 | `test_m3_non_speech_tokens` | 82 suppression tokens present (set comparison) |
| 7 | `test_m3_word_split_english` | "Hello, world!" word split matches Python |
| 8 | `test_m3_word_split_cjk` | Japanese text character-level split matches Python |
| 9 | `test_m3_roundtrip` | 10 sentences encode->decode roundtrip match |

### test_m4_1_model (6 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m4_1_load_turbo` | Turbo: multilingual=YES, nMels=128, numLanguages=100, vocab=51866 |
| 2 | `test_m4_1_properties` | Derived constants: inputStride=2, numSamplesPerToken=320, etc. |
| 3 | `test_m4_1_compute_type` | f32 and f16 load with correct properties |
| 4 | `test_m4_1_suppress_tokens` | suppressTokens and suppressTokensAtBegin loaded from config |
| 5 | `test_m4_1_supported_languages` | 100 languages including en, zh, ja, fr |
| 6 | `test_m4_1_feature_extractor_works` | 1s silence -> mel spectrogram succeeds |

### test_m4_2_encode (4 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m4_2_encode_shape` | 30s silence -> 7,680,000 bytes (1x1500x1280 float32) |
| 2 | `test_m4_2_encode_real_audio` | Real audio -> non-zero encoder output |
| 3 | `test_m4_2_detect_english` | physicsworks.wav -> "en" with prob > 0.5, top-5 probs |
| 4 | `test_m4_2_detect_threshold` | threshold=0.0 early stop and threshold=1.0 majority vote both detect "en" |

### test_m4_3_prompt (9 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m4_3_basic_prompt` | No context -> sotSequence only |
| 2 | `test_m4_3_with_previous` | sot_prev + 5 previous tokens + sotSequence |
| 3 | `test_m4_3_with_previous_truncation` | 300 tokens truncated to 223 (maxLength//2 - 1) |
| 4 | `test_m4_3_with_prefix` | sotSequence + timestampBegin + encoded prefix |
| 5 | `test_m4_3_with_hotwords` | sot_prev + encoded hotwords + sotSequence |
| 6 | `test_m4_3_without_timestamps` | sotSequence + noTimestamps token |
| 7 | `test_m4_3_suppressed_tokens` | -1 expansion -> 88 tokens (82 non-speech + 6 special) |
| 8 | `test_m4_3_suppressed_tokens_empty` | Empty input -> 6 always-suppressed tokens |
| 9 | `test_m4_3_translate_task` | fr/translate sotSequence contains translate token |

### test_m4_4_generate (6 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m4_4_greedy` | Temperature=0, beam_size=5 -> coherent tokens |
| 2 | `test_m4_4_sampling` | Temperature=0.5, bestOf=3 -> coherent output |
| 3 | `test_m4_4_fallback` | logProbThreshold=0.0 forces fallback, best result selected |
| 4 | `test_m4_4_compression_ratio` | Repetitive vs varied text compression ratio |
| 5 | `test_m4_4_no_speech` | 30s silence -> valid generate result, noSpeechProb checked |
| 6 | `test_m4_4_best_of` | Temperature=0.8, bestOf=5 -> coherent output |

### test_m4_5_segments (5 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m4_5_basic_split` | 2 timestamp pairs -> 2 segments with correct times |
| 2 | `test_m4_5_single_ending` | Single timestamp ending: seek advances by segmentSize |
| 3 | `test_m4_5_no_timestamps` | All text tokens -> 1 segment, full duration |
| 4 | `test_m4_5_consecutive` | 3 consecutive pairs -> 3 segments |
| 5 | `test_m4_5_time_offset` | timeOffset=30.0 correctly shifts times |

### test_m4_6_transcribe (5 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m4_6_short_audio` | jfk.flac -> recognizable JFK text, language=en |
| 2 | `test_m4_6_long_audio` | 60s -> multiple segments, monotonic timestamps |
| 3 | `test_m4_6_callback_streaming` | segmentHandler callback count matches segment count |
| 4 | `test_m4_6_empty_audio` | Empty and nil audio -> empty segments, no crash |
| 5 | `test_m4_6_condition_previous` | conditionOnPreviousText YES/NO both produce output |

### test_m5_word_timestamps (4 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m5_merge_punctuations` | Prepend/append punctuation merging logic |
| 2 | `test_m5_anomaly_score` | 4 cases: normal, low-prob, short-dur, long-dur |
| 3 | `test_m5_word_timestamps` | jfk.flac -> 5-40 words, start<=end, monotonic, text match |
| 4 | `test_m5_word_timestamps_long` | 30s -> >10 words, coherent timing |

### test_m6_vad (6 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m6_load_model` | Silero VAD ONNX model loads |
| 2 | `test_m6_speech_probs` | 938 chunks, probabilities match Python within 0.01 |
| 3 | `test_m6_timestamps_speech` | jfk.flac -> >= 1 segment, speech ratio > 0.5 |
| 4 | `test_m6_collect_chunks` | Mock timestamps merged correctly with maxDuration |
| 5 | `test_m6_timestamp_map` | SpeechTimestampsMap restores times for 4 points |
| 6 | `test_m6_end_to_end` | VAD -> collect -> transcribe 30s -> coherent text |

### test_m7_batched (5 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m7_batch_encode` | 4 silence chunks -> each 1500xd_model |
| 2 | `test_m7_batch_transcribe` | 60s batchSize=4 -> segments, monotonic timestamps |
| 3 | `test_m7_batch_vs_sequential` | jfk.flac: batched vs sequential both produce JFK text |
| 4 | `test_m7_throughput` | 203s: batchSize=1 vs batchSize=8 RTF comparison |
| 5 | `test_m7_segment_handler` | Callback count matches segment count, text matches |

### test_m8_cli (7 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m8_help` | --help exits 0, contains usage text |
| 2 | `test_m8_basic` | Basic transcription exits 0, contains JFK text |
| 3 | `test_m8_srt` | --output-format srt: starts with "1\n", contains "-->" |
| 4 | `test_m8_vtt` | --output-format vtt: starts with "WEBVTT" |
| 5 | `test_m8_json` | --json: valid JSON with segments/language keys |
| 6 | `test_m8_exit_codes` | Nonexistent file -> exit 1, missing --model -> exit !=0 |
| 7 | `test_m8_word_srt` | --word-timestamps --output-format srt: >10 SRT entries |

### test_m9_model_manager (11 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m9_available_models` | >= 18 model aliases |
| 2 | `test_m9_repo_id_lookup` | 7 alias -> repo ID mappings, unknown returns nil |
| 3 | `test_m9_local_path` | Local directory resolves directly |
| 4 | `test_m9_cache_directory` | Default under ~/Library/Caches/MetalWhisper/models/ |
| 5 | `test_m9_list_cached` | Returns array with name/path/sizeBytes keys |
| 6 | `test_m9_is_cached` | Local path = cached, unknown = not cached |
| 7 | `test_m9_unknown_model_error` | Unknown alias -> nil + error "Unknown model" |
| 8 | `test_m9_repo_id_injection` | 9 malicious paths rejected, 4 valid repo IDs accepted |
| 9 | `test_m9_delete_nonexistent` | Deleting non-cached model does not crash |
| 10 | `test_m9_custom_cache_dir` | Custom cache directory works |
| 11 | `test_m9_download_tiny` | (NETWORK, skipped by default) Downloads tiny, verifies all files |

### test_m10_api (5 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m10_options_defaults` | All MWTranscriptionOptions defaults correct |
| 2 | `test_m10_options_copy` | NSCopying: modified copy leaves original unchanged |
| 3 | `test_m10_options_to_dict` | toDictionary produces all expected keys |
| 4 | `test_m10_transcribe_with_options` | Typed options: transcribe jfk.flac -> correct text |
| 5 | `test_m10_async_transcribe` | Async API: completion handler on main queue -> correct text |

### test_m11_validation (14 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m11_jfk_tiny` | Tiny model: JFK speech recognized (if tiny cached) |
| 2 | `test_m11_jfk_turbo` | Turbo: >80% character similarity to reference |
| 3 | `test_m11_multi_format` | FLAC vs M4A: >60% word overlap |
| 4 | `test_m11_word_timestamps_monotonic` | 30s: words start<=end, monotonic within segments |
| 5 | `test_m11_segment_timestamps_valid` | 60s: start<end, last end <= audio duration |
| 6 | `test_m11_rtf_turbo` | 203s: RTF < 0.20 |
| 7 | `test_m11_rtf_tiny` | 30s: RTF < 0.15 (if tiny cached) |
| 8 | `test_m11_empty_audio` | 0 segments, no crash |
| 9 | `test_m11_very_short_audio` | 0.05s: handled gracefully |
| 10 | `test_m11_stereo_input` | Stereo WAV -> non-empty text |
| 11 | `test_m11_mp3_input` | MP3 44.1kHz stereo -> non-empty text |
| 12 | `test_m11_corrupt_file` | Garbage data -> error, no crash |
| 13 | `test_m11_memory_sequential` | 5x sequential: RSS growth < 100 MB |
| 14 | `test_m11_memory_peak` | 203s: peak RSS < 3000 MB |

### test_edge_cases (7 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_invalid_model_path` | Nonexistent path -> nil + MWErrorCodeModelLoadFailed |
| 2 | `test_encode_zero_frames` | nFrames=0 -> nil + MWErrorCodeEncodeFailed |
| 3 | `test_encode_wrong_size` | Wrong mel size -> nil + MWErrorCodeEncodeFailed |
| 4 | `test_callback_stop` | segmentHandler sets stop=YES -> stops after 1 callback |
| 5 | `test_suppress_tokens_includes_config` | -1 expansion includes config.json suppress_ids |
| 6 | `test_empty_transcribe` | Empty/nil audio -> empty array, no crash |
| 7 | `test_transcribe_url_not_found` | Nonexistent URL -> nil + error |

### test_m6_m7_edge_cases (12 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_vad_empty_audio` | Empty audio -> empty probs array, no crash |
| 2 | `test_vad_nil_audio` | Nil audio -> empty probs array, no crash |
| 3 | `test_vad_short_audio` | 100 samples -> 1 probability in [0,1] |
| 4 | `test_vad_timestamps_empty` | Empty audio -> empty timestamps |
| 5 | `test_vad_max_speech_splitting` | maxSpeechDurationS=10 -> segments within bounds |
| 6 | `test_vad_model_invalid_path` | Invalid path -> nil + error |
| 7 | `test_timestamp_map_overlapping` | Overlapping chunks -> no crash, monotonic |
| 8 | `test_timestamp_map_empty` | Empty chunks -> identity mapping |
| 9 | `test_collect_chunks_oob` | Out-of-bounds chunks -> no crash |
| 10 | `test_collect_chunks_empty` | Empty chunks -> empty result |
| 11 | `test_memory_vad_repeated` | 10x VAD runs: RSS growth < 5 MB |
| 12 | `test_memory_batched_repeated` | 3x batched runs: RSS growth < 100 MB |

### test_e2e (23 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_e2e_smoke_jfk_turbo` | JFK with turbo: "fellow Americans", "ask not", 1 segment |
| 2 | `test_e2e_smoke_jfk_tiny` | JFK with tiny: shares words with turbo (if tiny cached) |
| 3 | `test_e2e_long_form` | 60s: >5 segments, monotonic, >200 chars |
| 4 | `test_e2e_mp3_format` | MP3 decoded and transcribed |
| 5 | `test_e2e_multi_format_match` | FLAC vs M4A: both contain "ask" |
| 6 | `test_e2e_detect_russian` | russian_60s.wav -> "ru", Cyrillic output |
| 7 | `test_e2e_translate_russian` | translate task runs (turbo limitation noted) |
| 8 | `test_e2e_mixed_language` | EN->RU: Latin + Cyrillic characters present |
| 9 | `test_e2e_explicit_language` | explicit language="en" matches auto-detect |
| 10 | `test_e2e_word_timestamps_basic` | 15-40 words, text concatenation matches segment |
| 11 | `test_e2e_word_timestamps_long` | 30s: >50 words, monotonic within segments |
| 12 | `test_e2e_word_srt_output` | CLI word SRT: >15 entries |
| 13 | `test_e2e_vad_silence_detection` | silence+speech+silence: speech detected, JFK text |
| 14 | `test_e2e_vad_music_only` | Music: <=2 segments with VAD |
| 15 | `test_e2e_vad_vs_no_vad` | VAD vs no-VAD both produce JFK text |
| 16 | `test_e2e_srt_format` | Valid SRT with timestamps (regex verified) |
| 17 | `test_e2e_vtt_format` | Valid VTT with WEBVTT header |
| 18 | `test_e2e_json_format` | Valid JSON: language, duration, segments keys |
| 19 | `test_e2e_json_word_timestamps` | JSON words array: start/end/word/probability |
| 20 | `test_e2e_stereo_input` | Stereo auto-downmixed to mono |
| 21 | `test_e2e_callback_streaming` | Callback count == segment count |
| 22 | `test_e2e_condition_on_previous` | YES/NO both produce valid output |
| 23 | `test_e2e_async_api` | Async: completion fires, streaming count matches |

### test_deferred (10 tests)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `test_m4_1_load_tiny` | Tiny via MWModelManager: multilingual, nMels=80, transcribes JFK |
| 2 | `test_m4_6_clip_timestamps` | clipTimestamps=[5.0, 15.0]: segments bounded correctly |
| 3 | `test_m4_6_translate` | russian_60s.wav translate task runs without error |
| 4 | `test_m5_hallucination_skip` | hallucinationSilenceThreshold=1.0 vs 0.0 |
| 5 | `test_m7_multilingual_batch` | mixed_en_ru.wav batched VAD: Latin or Cyrillic present |
| 6 | `test_m8_batch_output_dir` | CLI --output-dir: jfk.txt + hotwords.txt created |
| 7 | `test_m8_stdin` | Pipe WAV via stdin -> correct output |
| 8 | `test_m11_long_audio` | 83min: >100 segments, monotonic timestamps (MW_LARGE_FILE gated) |
| 9 | `test_m4_3_prompt_reset` | promptResetOnTemperature: threshold=0.1 vs 2.0 |
| 10 | `test_m4_4_error_recovery` | Garbage encoder output -> nil + error, no crash |

### test_benchmark (1 test binary, multiple benchmarks)
| # | Benchmark | Measures |
|---|-----------|----------|
| 1 | Audio decode | jfk.flac (11s), physicsworks.wav (203s) median of 3 |
| 2 | Mel spectrogram | 30s audio, 5 iterations, median |
| 3 | Encode | 30s silence, median of 3 |
| 4 | Full transcription | jfk.flac and physicsworks.wav, 3 runs each |
| 5 | Word timestamps | jfk.flac + word_timestamps, 3 runs |
| 6 | Peak RSS | Current RSS at end |

### test_swift (1 test)
| # | Function | Verifies |
|---|----------|----------|
| 1 | `main` | Swift imports MetalWhisper, loads model, creates options, transcribes with streaming |

---

**Total: 25 test binaries, ~145 individual test functions/cases**

---

## 2. ROADMAP Deferred Items Analysis

### M4.1 -- Model Loading
| Item | Status | Notes |
|------|--------|-------|
| `test_m4_1_load_large` | **BLOCKED** | Requires large-v3 model (~3 GB download), not cached locally |

### M4.2 -- Encoding & Language Detection
| Item | Status | Notes |
|------|--------|-------|
| `test_m4_2_detect_french` | **BLOCKED** | No French audio file available in test data |

### M4.3 -- Prompt Construction
| Item | Status | Notes |
|------|--------|-------|
| `test_m4_3_prompt_reset` | **COVERED BY OTHER TEST** | Implemented in `test_deferred.mm` as `test_m4_3_prompt_reset` |

### M4.4 -- Generate
| Item | Status | Notes |
|------|--------|-------|
| `test_m4_4_error_recovery` | **COVERED BY OTHER TEST** | Implemented in `test_deferred.mm` as `test_m4_4_error_recovery` |

### M4.6 -- Main Decode Loop
| Item | Status | Notes |
|------|--------|-------|
| `test_m4_6_reference_match` | **BLOCKED** | Requires Python reference generation on same machine |

### M5 -- Word Timestamps
| Item | Status | Notes |
|------|--------|-------|
| `test_m5_alignment` | **BLOCKED** | Requires Python reference alignment pairs for exact comparison |

### M7 -- Batched Inference
| Item | Status | Notes |
|------|--------|-------|
| `test_m7_concurrent_files` | **BLOCKED** | Requires GCD concurrent dispatch integration (M7.5 not built) |

### M8 -- CLI
| Item | Status | Notes |
|------|--------|-------|
| `test_m8_translate` | **CAN IMPLEMENT NOW** | Russian audio available; test should verify CLI with `--task translate` flag runs (turbo limitation is OK to note) |

### M10 -- Public API & Swift
| Item | Status | Notes |
|------|--------|-------|
| `test_m10_swift_basic` | **BLOCKED** | Requires Xcode/SPM project for Swift test target. `test_swift.swift` exists but is manually built. |
| `test_m10_swift_streaming` | **FUTURE FEATURE** | Requires M10.7 AsyncSequence wrapper (not built) |
| `test_m10_swift_cancel` | **FUTURE FEATURE** | Requires M10.8 structured concurrency (not built) |
| `test_m10_microphone` | **FUTURE FEATURE** | Requires M10.9 live AVAudioEngine capture (not built) |

### M11 -- Validation
| Item | Status | Notes |
|------|--------|-------|
| `test_m11_exact_tokens` | **BLOCKED** | Requires Python reference token generation on same machine |
| `test_m11_wer_librispeech` | **BLOCKED** | Requires LibriSpeech dataset download |

### M12 -- App & Documentation
| Item | Status | Notes |
|------|--------|-------|
| M12.3 SwiftUI example app | **FUTURE FEATURE** | Requires Xcode/Apple Developer account |
| M12.4 Package.swift (SPM) | **FUTURE FEATURE** | Requires Xcode/Apple Developer account |
| M12.5 Homebrew formula | **FUTURE FEATURE** | Requires CI/CD setup |
| M12.6 CI/CD | **FUTURE FEATURE** | Requires GitHub Actions setup |
| M12.10 Code signing | **FUTURE FEATURE** | Requires Apple Developer account |
| M12.11 Model unload/reload | **FUTURE FEATURE** | API not built |

### M13-M15 (Future Milestones)
| Item | Status | Notes |
|------|--------|-------|
| All M13 streaming tests | **FUTURE FEATURE** | M13 not built |
| All M14 diarization tests | **FUTURE FEATURE** | M14 not built |
| All M15 server tests | **FUTURE FEATURE** | M15 not built |

---

## 3. Coverage Gaps

### 3.1 API Methods with Zero or Weak Test Coverage

| API Method | Status | Priority |
|------------|--------|----------|
| `MWAudioDecoder +decodeAudioFromData:error:` | **NO TEST** | **CAN ADD** -- Create in-memory WAV data, decode, verify |
| `MWAudioDecoder +decodeAudioFromBuffer:error:` | **NO TEST** | **CAN ADD** -- Create AVAudioPCMBuffer, decode, verify |
| `MWTokenizer -decodeWithTimestamps:` | **NO TEST** | **CAN ADD** -- Feed tokens with timestamp tokens, verify `<\|0.00\|>` markers |
| `MWTokenizer -tokenIDForString:` | **NO TEST** | **CAN ADD** -- Test lookup of known tokens like `<\|en\|>`, `<\|endoftext\|>` |
| `MWTranscriber buildPromptWithPreviousTokens:...tokenizer:` (per-segment tokenizer variant) | **NO DIRECT TEST** | **CAN ADD** -- Test with a different-language tokenizer |
| `MWSpeechTimestampsMap -originalTimeForTime:chunkIndex:` | **NO TEST** | **CAN ADD** -- Test the chunk-indexed variant |
| `MWSpeechTimestampsMap -chunkIndexForTime:isEnd:` | **NO TEST** | **CAN ADD** -- Test chunk index lookup |
| `MWModelManager -deleteCachedModel:error:` (with real cached model) | **WEAK** | **CAN ADD** -- Download tiny, verify cached, delete, verify gone (network-gated) |
| `MWTranscriptionOptions -languageDetectionSegments` | **NO DIRECT TEST** | **CAN ADD** -- Set to 3, verify multi-segment detection behavior |
| `MWTranscriptionOptions -languageDetectionThreshold` | **NO DIRECT TEST** | **CAN ADD** -- Verify threshold affects detection behavior |
| `MWTranscriptionOptions -maxNewTokens` | **NO DIRECT TEST** | **CAN ADD** -- Set maxNewTokens=10, verify output is truncated |
| `MWVADOptions -negThreshold` | **NO DIRECT TEST** | **CAN ADD** -- Set custom negThreshold, verify different behavior vs default |
| `MWVADOptions -minSpeechDurationMs` | **NO DIRECT TEST** | **CAN ADD** -- Set high value, verify short speech filtered |
| `MWVADOptions -minSilenceDurationMs` | **NO DIRECT TEST** | **CAN ADD** -- Vary value, verify segment merging behavior |
| `MWVADOptions -speechPadMs` | **NO DIRECT TEST** | **CAN ADD** -- Vary padding, check segment boundary changes |

### 3.2 Error Paths Not Exercised

| Gap | Status | Notes |
|-----|--------|-------|
| `MWFeatureExtractor` with nil/empty audio | **CAN ADD** | What happens with 0-length input? |
| `MWFeatureExtractor` with non-standard nFFT/hopLength | **CAN ADD** | Test custom params via designated initializer |
| `MWTokenizer` with invalid model path | **CAN ADD** | Verify proper error returned |
| `MWTokenizer` with non-multilingual model + language setting | **CAN ADD** if tiny.en is downloadable |
| `MWTranscriber` double-release / use-after-release | **CAN ADD** | Manual memory management correctness |
| `MWModelManager` network failure (unreachable host) | **BLOCKED** | Would need to mock network or use unreachable URL |
| `MWModelManager` partial download / resume | **BLOCKED** | Would need to interrupt a download mid-stream |
| CLI with invalid `--compute-type` value | **CAN ADD** | Verify error message and exit code |
| CLI with invalid `--output-format` value | **CAN ADD** | Verify error message and exit code |
| CLI `--language` with invalid code | **CAN ADD** | Verify behavior with nonsense language code |

### 3.3 Configuration Combinations Not Tested

| Combination | Status |
|-------------|--------|
| `vadFilter=YES` + `wordTimestamps=YES` (both together) | **CAN ADD** -- Verify word timestamps are remapped to original time |
| `vadFilter=YES` + `conditionOnPreviousText=YES` | **CAN ADD** -- Verify prompt conditioning works across VAD chunks |
| `initialPrompt` + `hotwords` simultaneously | **CAN ADD** -- Both set at once |
| `prefix` + `hotwords` simultaneously | **CAN ADD** -- Both set at once |
| `withoutTimestamps=YES` + `wordTimestamps=YES` | **CAN ADD** -- Verify behavior (should fail or ignore one) |
| `beamSize=1` (greedy without beam search) | **CAN ADD** -- Verify output quality |
| `noRepeatNgramSize > 0` | **CAN ADD** -- Verify repetition suppression |
| `repetitionPenalty != 1.0` | **CAN ADD** -- Verify effect on output |
| `lengthPenalty != 1.0` | **CAN ADD** -- Verify effect on output |
| Batched with `wordTimestamps=YES` | **CAN ADD** -- Verify words produced per segment |
| Batched with `conditionOnPreviousText=YES` | **CAN ADD** -- Verify context not passed between chunks |

### 3.4 Missing Regression Scenarios

| Scenario | Status |
|----------|--------|
| Infinite loop protection (seek doesn't advance) | **CAN ADD** -- Would need crafted input or mock |
| `maxInitialTimestamp` effect on first timestamp | **CAN ADD** -- Set to 0.0, verify first segment starts near 0 |
| TSV output format from CLI | **CAN ADD** if CLI supports `--output-format tsv` |
| `--version` flag | **CAN ADD** -- Verify version string output |
| Multiple `--language` override on multilingual audio | **CAN ADD** -- Force "zh" on English audio, verify garbled output |

---

## 4. Recommended Prioritized Action List

### Priority 1: High-Value, Low-Effort (< 1 hour each)

1. **`MWTokenizer -decodeWithTimestamps:` test** -- Zero coverage on a public API method. Feed `[timestampBegin+0, 100, 200, timestampBegin+125]` and verify `<|0.00|>text<|2.50|>` output format.

2. **`MWTokenizer -tokenIDForString:` test** -- Zero coverage. Test `<|en|>` -> 50259, `<|endoftext|>` -> 50257, unknown string -> NSNotFound.

3. **`MWAudioDecoder +decodeAudioFromData:error:` test** -- Zero coverage. Read jfk.flac into NSData, call decodeAudioFromData, verify sample count matches decodeAudioAtURL result.

4. **CLI `--task translate` test** -- The `test_m8_translate` item is marked deferred but the pipeline works (tested in test_deferred via API). Just test the CLI flag: `metalwhisper russian_60s.wav --model turbo --task translate` exits 0.

5. **CLI invalid argument tests** -- Test `--output-format invalid`, `--compute-type invalid`, `--language zzz`. All should produce stderr error and nonzero exit.

6. **`MWTranscriptionOptions -maxNewTokens` test** -- Set to 10, transcribe, verify output is short (< 15 tokens per segment).

### Priority 2: Medium-Value, Medium-Effort (1-2 hours each)

7. **VAD option parameter tests** -- Create a test that varies `negThreshold`, `minSpeechDurationMs`, `minSilenceDurationMs`, `speechPadMs` on the same audio and verifies the segment count/boundaries change as expected.

8. **`vadFilter=YES` + `wordTimestamps=YES` combination test** -- Transcribe silence_speech_silence.wav with both enabled, verify word timestamps are remapped to original (non-filtered) time positions.

9. **`MWSpeechTimestampsMap` additional methods** -- Test `originalTimeForTime:chunkIndex:` and `chunkIndexForTime:isEnd:` with the existing mock chunk setup.

10. **`MWAudioDecoder +decodeAudioFromBuffer:error:` test** -- Create an AVAudioPCMBuffer programmatically (e.g., 1s of 440Hz sine at 44.1kHz stereo), decode, verify 16000 mono samples.

11. **Configuration conflict test: `withoutTimestamps=YES` + `wordTimestamps=YES`** -- Verify the framework handles this gracefully (should either error or prioritize one).

12. **`noRepeatNgramSize` and `repetitionPenalty` tests** -- Transcribe audio with default vs modified values, verify output differs.

### Priority 3: Medium-Value, Higher Effort (2-4 hours each)

13. **`MWFeatureExtractor` edge case tests** -- Empty audio, 1-sample audio, non-standard nFFT/hopLength via designated initializer.

14. **CLI `--version` test** -- If implemented, verify output. If not, flag as missing CLI feature.

15. **Multi-language detection parameter tests** -- Test `languageDetectionSegments=3` and `languageDetectionThreshold=0.9` with russian_60s.wav.

16. **French language detection test** -- Requires creating or obtaining a short French audio file. Could generate with text-to-speech as a test fixture.

17. **Batched + wordTimestamps combination test** -- Transcribe 60s with batched mode and wordTimestamps=YES, verify words are populated per segment.

### Priority 4: Blocked / Future (Needs External Resources)

18. **Python reference token match (test_m11_exact_tokens)** -- Requires running Python faster-whisper on same machine to generate reference tokens. High value for accuracy validation.

19. **Large-v3 model loading test** -- Requires ~3 GB download. Could be network-gated like the tiny download test.

20. **LibriSpeech WER benchmark** -- Requires dataset download (~350 MB for test-clean). High value for accuracy benchmarking against published results.

21. **GCD concurrent file transcription (test_m7_concurrent_files)** -- Requires M7.5 GCD integration to be built.

22. **Swift integration via Xcode/SPM** -- `test_swift.swift` exists but is manually compiled. Needs Package.swift for proper CI integration.

---

## Summary Statistics

| Category | Count |
|----------|-------|
| Implemented test functions | ~145 |
| ROADMAP deferred items: **CAN IMPLEMENT NOW** | 1 (CLI translate) |
| ROADMAP deferred items: **COVERED BY OTHER TEST** | 2 (prompt_reset, error_recovery) |
| ROADMAP deferred items: **BLOCKED** | 7 |
| ROADMAP deferred items: **FUTURE FEATURE** | 10+ |
| New coverage gaps identified: **CAN ADD** | ~30 |
| New coverage gaps identified: **BLOCKED** | ~5 |
| API methods with zero test coverage | 7 |
| Untested configuration combinations | 11 |
