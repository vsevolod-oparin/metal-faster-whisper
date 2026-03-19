# M0 Milestone Report — Project Setup & CTranslate2 Library Integration

**Date:** 2026-03-19
**Status:** PASSED

## Summary

The MetalWhisper M0 milestone establishes the project structure, CMake build system, and verifies that CTranslate2's Whisper C++ API can be called from Objective-C++ with Metal (MPS) GPU acceleration.

## What Was Set Up

### Project Structure

```
metal-faster-whisper/
  CMakeLists.txt                -- Build system
  .gitignore                    -- Build artifacts excluded
  src/
    MWTranscriber.h             -- Public Obj-C API header
    MWTranscriber.mm            -- Obj-C++ implementation
  tests/
    test_m0_link.mm             -- Link and smoke test
    test_m0_compute_types.mm    -- Compute type matrix test
  docs/
    ARC_POLICY.md               -- Manual retain/release conventions (M0.6)
  reports/
    m0-report.md                -- This report
```

### Build System (CMakeLists.txt)

- CMake 3.20+, C++17, Obj-C++ support
- Finds CTranslate2 via `CT2_INSTALL_PREFIX` (defaults to sibling `../CTranslate2/build/install/`, overridable)
- Builds `libMetalWhisper.dylib` shared library from `src/*.mm`
- All `.mm` files compiled with `-fno-objc-arc` (architecture decision #5)
- Test executables built from `tests/*.mm`
- `@rpath` configured for both build tree and install tree
- Install rules: `lib/` (MetalWhisper + CTranslate2 dylibs), `include/MetalWhisper/`, `bin/`
- CTranslate2 dylib is co-installed so the install prefix is self-contained
- Zero compiler warnings (clean build)

### Public API (MWTranscriber)

Minimal M0 API surface:
- `initWithModelPath:error:` — convenience init, default compute type
- `initWithModelPath:computeType:error:` — designated initializer, explicit compute type
- `isMultilingual` — whether the model supports multiple languages
- `nMels` — number of mel frequency bins (80 or 128)
- `encodeSilenceTestWithError:` — encodes 30s of zero-filled mel spectrogram, returns output shape
- `MWComputeType` enum — `Default`, `Float32`, `Float16`, `Int8`, `Int8Float16`, `Int8Float32`
- `MWErrorCode` enum — `ModelLoadFailed`, `EncodeFailed`
- `init` marked `NS_UNAVAILABLE`; designated initializer marked `NS_DESIGNATED_INITIALIZER`

### Implementation Details

- Uses `ctranslate2::models::Whisper` (the thread-safe ReplicaPool) for model management
- Device is `ctranslate2::Device::MPS` (not METAL — verified from devices.h)
- StorageView created with `StorageView(Shape, float init=0.0f, Device::CPU)` constructor
- `Whisper::encode()` returns `std::future<StorageView>` — pool dispatches to worker thread
- Manual retain/release throughout (no ARC); conventions documented in `docs/ARC_POLICY.md`
- Init does NOT use `@autoreleasepool` (avoids premature dealloc on failure path)
- `encodeSilenceTestWithError:` does NOT use inner `@autoreleasepool` (autoreleased return value)

## Test Results

### test_m0_link (link + encode smoke test)

**Model:** whisper-large-v3-turbo (multilingual, 128 mels)

```
=== MetalWhisper M0 Link Test ===
Model path: .../whisper-large-v3-turbo
OK: Model loaded successfully.
  isMultilingual: YES
  nMels:          128
Running encode silence test...
OK: Encoder output shape: [1, 1500, 1280]
=== M0 Link Test PASSED ===
```

### test_m0_compute_types (f32, f16, int8, int8_f16)

```
[1/4] float32      → OK: Encoder output shape: [1, 1500, 1280]
[2/4] float16      → OK: Encoder output shape: [1, 1500, 1280]
[3/4] int8         → OK (expected failure): MPS backend does not support int8 encode
[4/4] int8_float16 → OK (expected failure): MPS backend does not support int8 encode
Results: 4/4 passed, 0 failed
=== M0 Compute Types Test PASSED ===
```

### Install layout verification

Installed binary `bin/test_m0_link` runs successfully from the install prefix — `libctranslate2.dylib` and `libMetalWhisper.dylib` both resolve via `@rpath → @loader_path/../lib`.

```
install/
  bin/test_m0_link, test_m0_compute_types
  include/MetalWhisper/MWTranscriber.h
  lib/libMetalWhisper.{dylib,0.dylib,0.1.0.dylib}
  lib/libctranslate2.{dylib,4.dylib,4.7.1.dylib}
```

## Key Findings

1. **Device enum is `Device::MPS`**, not `Device::METAL`. The CTranslate2 codebase uses MPS terminology throughout.

2. **int8 compute types load but fail at encode.** The model loads successfully with `ComputeType::INT8`, but `encode()` throws because the MPS backend expects float16 storage. This is a known CTranslate2 limitation — whisper models aren't int8-quantized on this backend. Functional compute types on MPS: **float32** and **float16**.

3. **`@autoreleasepool` gotchas in manual retain/release code:**
   - An inner pool around a method body drains autoreleased return values before the caller gets them (SIGSEGV).
   - An inner pool in init risks premature dealloc of `self` on the `[self release]` failure path.
   - Full conventions documented in `docs/ARC_POLICY.md`.

4. **Encoder output shape for large-v3-turbo:** `[1, 1500, 1280]` (d_model=1280).

## Task Checklist

| Task | Status | Notes |
|------|--------|-------|
| M0.1: CMake config for CTranslate2 dylib | DONE | Already built in sibling dir |
| M0.2: Framework project setup | DONE | CMakeLists.txt, libMetalWhisper.dylib |
| M0.3: Install name and rpath | DONE | `@rpath` for build + install; installed binary verified |
| M0.4: Minimal Obj-C++ test | DONE | test_m0_link + test_m0_compute_types |
| M0.5: Brew-style install layout | DONE | lib/, include/, bin/ with co-installed CT2 dylib |
| M0.6: ARC policy documented | DONE | `-fno-objc-arc` in CMake; `docs/ARC_POLICY.md` |

## Exit Criteria

| Criterion | Status |
|-----------|--------|
| `Model::load(path, Device::MPS)` succeeds | PASS |
| `WhisperReplica::encode()` succeeds on macOS | PASS (via Whisper pool) |
| Framework links and loads `libctranslate2.dylib` at runtime | PASS (build tree + install tree) |
| All `.mm` files compiled with `-fno-objc-arc` | PASS |
| Install layout: `lib/`, `include/`, `bin/` | PASS (verified with installed binary) |

## Issues Found and Fixed During Review

| # | Issue | Severity | Fix |
|---|-------|----------|-----|
| 1 | Install layout missing libctranslate2.dylib — installed binary crashed | Bug | Added CT2 dylib to install rules |
| 2 | Hardcoded absolute path to CT2 install in CMakeLists.txt | Quality | Changed to `CT2_INSTALL_PREFIX` cache variable |
| 3 | ARC conventions not documented (M0.6 incomplete) | Missing | Created `docs/ARC_POLICY.md` |
| 4 | `@autoreleasepool` wrapping init with `[self release]` failure path | Potential bug | Removed pool from init |
| 5 | Missing `NS_DESIGNATED_INITIALIZER` / `NS_UNAVAILABLE` | Quality | Added to header |
| 6 | Compiler warning from CMake variable name collision | Quality | Renamed to `CT2_INSTALL_PREFIX` |
| 7 | Compiler warning from missing designated init override | Quality | Marked `-init` as `NS_UNAVAILABLE` |

## Next Steps (M1, M2, M3 — can proceed in parallel)

- M1: Audio decoding via AVFoundation (MWAudioDecoder)
- M2: Mel spectrogram extraction via Accelerate/vDSP (MWFeatureExtractor)
- M3: BPE tokenizer (MWTokenizer)
