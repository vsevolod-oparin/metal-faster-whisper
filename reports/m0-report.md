# M0 Milestone Report -- Project Setup & CTranslate2 Library Integration

**Date:** 2026-03-19
**Status:** PASSED

## Summary

The MetalWhisper M0 milestone establishes the project structure, CMake build system, and verifies that CTranslate2's Whisper C++ API can be called from Objective-C++ with Metal (MPS) GPU acceleration.

## What Was Set Up

### Project Structure

```
metal-faster-whisper/
  CMakeLists.txt           -- Build system
  .gitignore               -- Build artifacts excluded
  src/
    MWTranscriber.h        -- Public Obj-C API header
    MWTranscriber.mm       -- Obj-C++ implementation
  tests/
    test_m0_link.mm        -- Link and smoke test
  reports/
    m0-report.md           -- This report
```

### Build System (CMakeLists.txt)

- CMake 3.20+, C++17, Obj-C++ support
- Finds CTranslate2 via installed CMake config at `CTranslate2/build/install/`
- Builds `libMetalWhisper.dylib` shared library from `src/*.mm`
- All `.mm` files compiled with `-fno-objc-arc` (architecture decision #5)
- Test executables built from `tests/*.mm`
- `@rpath` configured for both build tree and install tree
- Install rules for lib/, include/, bin/ layout

### Public API (MWTranscriber)

Minimal M0 API surface:
- `initWithModelPath:error:` -- loads a CTranslate2 Whisper model on MPS (Metal)
- `isMultilingual` -- whether the model supports multiple languages
- `nMels` -- number of mel frequency bins (80 or 128)
- `encodeSilenceTest` -- encodes 30s of zero-filled mel spectrogram, returns output shape

### Implementation Details

- Uses `ctranslate2::models::Whisper` (the thread-safe ReplicaPool) for model management
- Device is `ctranslate2::Device::MPS` (not METAL -- verified from devices.h)
- StorageView created with `StorageView(Shape, float init=0.0f, Device::CPU)` constructor
- `Whisper::encode()` returns `std::future<StorageView>` -- pool dispatches to worker thread
- Manual retain/release throughout (no ARC)
- `@autoreleasepool` at init entry point; encode method intentionally avoids inner pool to prevent premature release of returned NSString

## Test Results

**Model:** whisper-large-v3-turbo (multilingual, 128 mels)

```
=== MetalWhisper M0 Link Test ===
Model path: /Users/smileijp/projects/branch/whisper-metal/models/whisper-large-v3-turbo/
OK: Model loaded successfully.
  isMultilingual: YES
  nMels:          128
Running encode silence test...
OK: Encoder output shape: [1, 1500, 1280]
=== M0 Link Test PASSED ===
```

- Model loads on MPS device without errors
- Properties (`isMultilingual`, `nMels`) read correctly from the model
- Encoder processes a [1, 128, 3000] input and produces [1, 1500, 1280] output
- Clean shutdown with no crashes or leaks

## Key Findings

1. **Device enum is `Device::MPS`**, not `Device::METAL`. The CTranslate2 codebase uses MPS terminology throughout.

2. **Model::load() returns `shared_ptr<const Model>`**, and the `Whisper` pool class constructor accepts a model path directly (preferred approach for M0).

3. **`@autoreleasepool` gotcha in manual retain/release code:** An inner `@autoreleasepool` around a method body will drain autoreleased return values before the caller can use them. Methods returning autoreleased objects must not wrap their body in `@autoreleasepool`. This is a critical pattern for all future MetalWhisper methods.

4. **Encoder output shape for large-v3-turbo:** [1, 1500, 1280] (1500 time steps, 1280-dim embeddings). This confirms the model has d_model=1280.

## Exit Criteria Status

| Criterion | Status |
|-----------|--------|
| `Model::load(path, Device::MPS)` succeeds | PASS |
| `WhisperReplica::encode()` succeeds on macOS | PASS (via Whisper pool) |
| Framework links and loads `libctranslate2.dylib` at runtime | PASS |
| All `.mm` files compiled with `-fno-objc-arc` | PASS |
| Install layout configured (lib/, include/, bin/) | PASS (CMake rules) |

## Next Steps (M1)

- Audio decoding via AVFoundation (MWAudioDecoder)
- Mel spectrogram extraction via Accelerate/vDSP (MWFeatureExtractor)
- BPE tokenizer (MWTokenizer)
