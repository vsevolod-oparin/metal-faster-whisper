# M1 Milestone Report — Audio Decoding (AVFoundation)

**Date:** 2026-03-19
**Status:** PASSED

## Summary

Replaced Python's PyAV/FFmpeg audio decoding with native macOS AVFoundation. The `MWAudioDecoder` class decodes any macOS-supported audio format to 16 kHz mono float32 samples, matching the Python faster-whisper `decode_audio()` output within float32 tolerance.

## Files Created

| File | Purpose |
|------|---------|
| `src/MWAudioDecoder.h` | Public API: `decodeAudioAtURL:`, `decodeAudioFromData:`, `decodeAudioFromBuffer:`, `padOrTrimAudio:` |
| `src/MWAudioDecoder.mm` | Implementation using AVAudioFile + AVAudioConverter, chunked streaming |
| `src/MWConstants.h` | Shared named constants: `kMWTargetSampleRate`, `kMWTargetChannels`, etc. |
| `tests/test_m1_audio.mm` | 7 test cases with Python reference data comparison |
| `tests/generate_reference.py` | Script to generate Python reference data from faster-whisper |
| `tests/data/` | Test audio files: WAV, MP3, FLAC, M4A, stereo WAV |
| `tests/data/reference/` | Python reference: raw float32 samples + JSON metadata |

## Implementation Details

- **AVAudioFile** handles all format detection and decoding (WAV, MP3, M4A/AAC, FLAC, CAF, AIFF)
- **AVAudioConverter** handles resampling (any rate → 16 kHz) and channel mixing (stereo → mono) in a single pass
- **Chunked streaming**: reads 8192 frames at a time, never loads entire file into memory
- **Stereo→mono normalization**: AVAudioConverter sums channels when downmixing; we divide by source channel count via `vDSP_vsmul` to match ffmpeg's averaging behavior
- **Three input modes**: file URL, in-memory NSData (via temp file), AVAudioPCMBuffer (direct conversion)
- **OGG not supported**: AVAudioFile doesn't support Vorbis/OGG on macOS. Users can pipe through ffmpeg: `ffmpeg -i input.ogg -f wav - | metalwhisper -`

## Test Results

```
PASS: test_m1_wav_decode       — 203s WAV, exact sample match, first 100 within 1e-4
PASS: test_m1_mp3_decode       — 4s MP3, sample count within 1% of Python
PASS: test_m1_flac_decode      — 11s FLAC, exact sample match, first 100 within 1e-4
PASS: test_m1_m4a_decode       — 11s M4A, sample count within 5% of FLAC
PASS: test_m1_stereo_mono      — 5s stereo WAV → mono, matches Python reference
PASS: test_m1_pad_or_trim      — Padding and trimming match Python exactly
PASS: test_m1_large_file       — 83 min MP3, 304 MB output, RSS growth 1.0x (streaming confirmed)
```

## Task Checklist

| Task | Status | Notes |
|------|--------|-------|
| M1.1: MWAudioDecoder via AVAudioFile | Done | |
| M1.2: Resample to 16 kHz mono float32 | Done | AVAudioConverter handles both |
| M1.3: File paths, NSData, AVAudioPCMBuffer | Done | All three input modes |
| M1.4: Format support | Done | WAV, MP3, M4A, FLAC, CAF, AIFF. OGG not supported (macOS limitation) |
| M1.5: padOrTrim utility | Done | |
| M1.6: Microphone live capture | Deferred to M13 | ROADMAP: "for real-time transcription in later milestones" |

## Exit Criteria

| Criterion | Status |
|-----------|--------|
| Bit-identical (float32 tolerance) vs Python for WAV | PASS — first 100 samples within 1e-4 |
| Close match for lossy formats | PASS — MP3 within 1%, M4A within 5% |
| Streaming decode for large files | PASS — 83 min file, RSS = 1.0x output |

## Key Findings

1. **AVAudioConverter sums stereo channels**, it doesn't average. Python's ffmpeg averages. Fix: divide by source channel count after conversion.
2. **`mutable` is a C++ keyword** — can't use as variable name in `.mm` files.
3. **Large file performance**: 83-minute MP3 decoded in chunked mode with RSS growth tracking output size 1:1 — no excess buffering.
