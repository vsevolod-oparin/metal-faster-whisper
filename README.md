# MetalWhisper

Native macOS Whisper transcription powered by Metal GPU acceleration.

**Native macOS -- Metal GPU -- No Python required**

MetalWhisper is a complete port of [faster-whisper](https://github.com/SYSTRAN/faster-whisper) from Python to Objective-C++, using [CTranslate2](https://github.com/OpenNMT/CTranslate2) with a custom Metal backend for GPU inference on Apple Silicon.

- **Fast.** RTF 0.087 (tiny) to 0.136 (turbo) on Apple Silicon -- 7-11x faster than real-time
- **Native.** No Python, no FFmpeg, no Docker. One binary, zero runtime dependencies
- **Full-featured.** Word timestamps, VAD filtering, SRT/VTT/JSON output, 18 model aliases
- **Low memory.** ~200 MB peak for tiny, ~1 GB peak for turbo on 200s+ audio
- **Scriptable.** Pipe from ffmpeg, output JSON for `jq`, batch process directories

## Quick Start

```bash
# Build
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(sysctl -n hw.logicalcpu)

# Download a model and transcribe
./metalwhisper audio.mp3 --model turbo
```

## CLI Usage

### Basic transcription

```bash
metalwhisper recording.wav --model turbo
```

### Subtitle generation

```bash
# SRT subtitles
metalwhisper lecture.mp3 --model turbo --output-format srt --output-dir ./subs

# WebVTT subtitles with word-level timestamps
metalwhisper lecture.mp3 --model turbo --output-format vtt --word-timestamps
```

### JSON output with word timestamps

```bash
metalwhisper interview.m4a --model large-v3 --json --word-timestamps
```

### VAD filtering

Voice activity detection skips silence, improving speed on audio with long pauses:

```bash
metalwhisper meeting.wav --model turbo --vad-filter --vad-model /path/to/silero_vad.onnx
```

### Model management

```bash
# List available model aliases
metalwhisper --list-models

# Download a model without transcribing
metalwhisper --model large-v3 --download --verbose
```

### Translate to English

```bash
metalwhisper french_audio.mp3 --model turbo --task translate
```

### Pipe from ffmpeg

```bash
ffmpeg -i video.mkv -ar 16000 -ac 1 -f wav - | metalwhisper --model turbo -
```

### Batch processing

```bash
metalwhisper *.mp3 --model turbo --output-format srt --output-dir ./output
```

### All CLI options

```
Usage: metalwhisper [OPTIONS] <input_file> [input_file2 ...]

Options:
  --model <path|alias>               Model path, alias, or HF repo ID (required)
  --language <code>                  Language code (default: auto-detect)
  --task <transcribe|translate>      Task (default: transcribe)
  --output-format <text|srt|vtt|json>  Output format (default: text)
  --output-dir <dir>                 Write output files to directory
  --compute-type <type>              auto, float32, float16, int8, int8_float16, int8_float32
  --beam-size <n>                    Beam size (default: 5)
  --word-timestamps                  Enable word-level timestamps
  --vad-filter                       Enable voice activity detection
  --vad-model <path>                 Path to Silero VAD ONNX model
  --initial-prompt <text>            Initial prompt text
  --hotwords <text>                  Hotwords to bias toward
  --no-condition-on-previous-text    Disable conditioning on previous text
  --temperature <t1,t2,...>          Fallback temperatures (default: 0.0,0.2,0.4,0.6,0.8,1.0)
  --json                             Shorthand for --output-format json
  --verbose                          Show progress and timing info on stderr
  --list-models                      List available model aliases
  --download                         Download model without transcribing
  -                                  Read audio from stdin (WAV format)
```

## Framework API (Objective-C)

```objc
#import <MetalWhisper/MetalWhisper.h>

NSError *error = nil;

// Load model
MWTranscriber *transcriber = [[MWTranscriber alloc] initWithModelPath:@"/path/to/model"
                                                                error:&error];

// Configure options
MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
opts.wordTimestamps = YES;
opts.beamSize = 5;

// Transcribe
MWTranscriptionInfo *info = nil;
NSArray<MWTranscriptionSegment *> *segments =
    [transcriber transcribeURL:[NSURL fileURLWithPath:@"audio.mp3"]
                      language:nil
                          task:@"transcribe"
                  typedOptions:opts
                segmentHandler:nil
                          info:&info
                         error:&error];

// Process results
NSLog(@"Language: %@ (%.1f%%)", info.language, info.languageProbability * 100);
for (MWTranscriptionSegment *seg in segments) {
    NSLog(@"[%.2f - %.2f] %@", seg.start, seg.end, seg.text);
    for (MWWord *word in seg.words) {
        NSLog(@"  %.2f-%.2f %@ (p=%.2f)", word.start, word.end, word.word, word.probability);
    }
}
```

### Streaming with segment handler

```objc
[transcriber transcribeURL:audioURL
                  language:nil
                      task:@"transcribe"
              typedOptions:opts
            segmentHandler:^(MWTranscriptionSegment *seg, BOOL *stop) {
                NSLog(@"[%.2f] %@", seg.start, seg.text);
                // Set *stop = YES to abort early
            }
                      info:&info
                     error:&error];
```

### Async transcription

```objc
[transcriber transcribeURL:audioURL
                  language:nil
                      task:@"transcribe"
              typedOptions:opts
            segmentHandler:nil
         completionHandler:^(NSArray *segments, MWTranscriptionInfo *info, NSError *err) {
             // Called on main queue
             if (err) { NSLog(@"Error: %@", err); return; }
             NSLog(@"Done: %lu segments", segments.count);
         }];
```

### Auto-download models

```objc
MWModelManager *mgr = [MWModelManager shared];
NSString *path = [mgr resolveModel:@"turbo" progress:nil error:&error];
// Downloads to ~/Library/Caches/MetalWhisper/models/ if not cached
```

## Supported Models

| Alias | HuggingFace Repo | Parameters | Notes |
|-------|-----------------|------------|-------|
| `tiny.en` | Systran/faster-whisper-tiny.en | 39M | English only |
| `tiny` | Systran/faster-whisper-tiny | 39M | Multilingual |
| `base.en` | Systran/faster-whisper-base.en | 74M | English only |
| `base` | Systran/faster-whisper-base | 74M | Multilingual |
| `small.en` | Systran/faster-whisper-small.en | 244M | English only |
| `small` | Systran/faster-whisper-small | 244M | Multilingual |
| `medium.en` | Systran/faster-whisper-medium.en | 769M | English only |
| `medium` | Systran/faster-whisper-medium | 769M | Multilingual |
| `large-v1` | Systran/faster-whisper-large-v1 | 1550M | |
| `large-v2` | Systran/faster-whisper-large-v2 | 1550M | |
| `large-v3` | Systran/faster-whisper-large-v3 | 1550M | Best accuracy |
| `large` | Systran/faster-whisper-large-v3 | 1550M | Alias for large-v3 |
| `turbo` | mobiuslabsgmbh/faster-whisper-large-v3-turbo | 809M | Best speed/accuracy |
| `large-v3-turbo` | mobiuslabsgmbh/faster-whisper-large-v3-turbo | 809M | Alias for turbo |
| `distil-large-v2` | Systran/faster-distil-whisper-large-v2 | ~756M | Distilled |
| `distil-large-v3` | Systran/faster-distil-whisper-large-v3 | ~756M | Distilled |
| `distil-medium.en` | Systran/faster-distil-whisper-medium.en | ~394M | English, distilled |
| `distil-small.en` | Systran/faster-distil-whisper-small.en | ~166M | English, distilled |

Models are CTranslate2-format weights downloaded from HuggingFace. You can also pass a local directory path or any HuggingFace repo ID directly.

## Performance

Benchmarked on Apple Silicon, Release build (-O2), Metal/MPS backend.

| Model | Audio | Wall Time | RTF | Peak RSS |
|-------|-------|-----------|-----|----------|
| turbo (f16) | 11s (JFK) | 1.28s | 0.116 | ~1,016 MB |
| turbo (f16) | 203s (lecture) | 27.5s | 0.136 | ~1,016 MB |
| tiny (f16) | 30s | 2.6s | 0.087 | ~200 MB |

RTF = processing time / audio duration. Lower is better. Values below 1.0 mean faster than real-time.

**Time breakdown per 30s chunk (turbo):**

| Phase | Time | Share |
|-------|------|-------|
| Mel spectrogram (vDSP) | ~11 ms | 0.9% |
| Encode (Metal GPU) | ~990 ms | 80% |
| Decode (Metal GPU) | ~200 ms | 16% |
| Other (prompt, split, tokenize) | ~30 ms | 2.4% |

See [docs/PERFORMANCE.md](docs/PERFORMANCE.md) for model selection guidance and tuning tips.

## Build Requirements

- **macOS 14+** (Sonoma or later)
- **Apple Silicon** (M1, M2, M3, M4)
- **CMake 3.20+**
- **CTranslate2** with Metal backend (`libctranslate2.dylib`, built separately)
- **ONNX Runtime** (for Silero VAD; bundled in `third_party/`)

### Building CTranslate2

CTranslate2 must be built from source with Metal (MPS) support. See the [CTranslate2 documentation](https://opennmt.net/CTranslate2/installation.html) for build instructions.

### Building MetalWhisper

```bash
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(sysctl -n hw.logicalcpu)
```

This produces:
- `metalwhisper` -- CLI binary
- `libMetalWhisper.dylib` -- framework library

## Project Structure

```
src/
  MetalWhisper.h          Umbrella header
  MWTranscriber.h/.mm     Core transcription engine
  MWTranscriptionOptions.h/.mm   Typed options (26 properties)
  MWAudioDecoder.h/.mm    AVFoundation audio decoding
  MWFeatureExtractor.h/.mm  Mel spectrogram via Accelerate/vDSP
  MWTokenizer.h/.mm       BPE tokenizer (reads tokenizer.json)
  MWVoiceActivityDetector.h/.mm  Silero VAD via ONNX Runtime
  MWModelManager.h/.mm    Model downloading and caching
  MWConstants.h           Shared constants
  MWHelpers.h/.mm         Internal utilities
cli/
  metalwhisper.mm         CLI entry point
tests/
  test_m*.mm              Test suites (~134 tests)
```

## Documentation

- [API Reference](docs/API.md) -- Public classes and methods
- [Performance Tuning](docs/PERFORMANCE.md) -- Model selection, compute types, benchmarks
- [Migration from faster-whisper](docs/MIGRATION.md) -- Python to MetalWhisper mapping
- [Man page](docs/man/metalwhisper.1) -- `man metalwhisper`

## Future Work

- Xcode project / Swift Package Manager integration
- Homebrew formula
- Code signing and notarization for binary distribution
- CI/CD pipeline
- ANE (Apple Neural Engine) acceleration
- Real-time microphone transcription
- Speaker diarization
- OpenAI-compatible API server

## License

[MIT](LICENSE) -- Copyright (c) 2026 Vsevolod-Oparin
