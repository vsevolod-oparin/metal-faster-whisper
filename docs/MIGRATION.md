# Migration Guide: faster-whisper (Python) to MetalWhisper

This guide maps faster-whisper Python API concepts to their MetalWhisper equivalents, covering both the CLI tool and the Objective-C framework.

## Model Loading

**Python:**
```python
from faster_whisper import WhisperModel
model = WhisperModel("large-v3-turbo", device="cuda", compute_type="float16")
```

**MetalWhisper CLI:**
```bash
metalwhisper audio.wav --model turbo --compute-type float16
```

**MetalWhisper Obj-C:**
```objc
MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:@"turbo"
                                                computeType:MWComputeTypeFloat16
                                                      error:&error];
```

To auto-download by alias (equivalent to Python's automatic HuggingFace download):

```objc
MWModelManager *mgr = [MWModelManager shared];
NSString *path = [mgr resolveModel:@"turbo" progress:nil error:&error];
MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:path error:&error];
```

Models are cached in `~/Library/Caches/MetalWhisper/models/`.

## Basic Transcription

**Python:**
```python
segments, info = model.transcribe("audio.mp3", beam_size=5)
print(f"Detected language: {info.language} ({info.language_probability:.0%})")
for segment in segments:
    print(f"[{segment.start:.2f}s -> {segment.end:.2f}s] {segment.text}")
```

**MetalWhisper CLI:**
```bash
metalwhisper audio.mp3 --model turbo --beam-size 5
```

**MetalWhisper Obj-C:**
```objc
MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
opts.beamSize = 5;

MWTranscriptionInfo *info = nil;
NSArray *segments = [t transcribeURL:[NSURL fileURLWithPath:@"audio.mp3"]
                            language:nil
                                task:@"transcribe"
                        typedOptions:opts
                      segmentHandler:nil
                                info:&info
                               error:&error];

NSLog(@"Language: %@ (%.0f%%)", info.language, info.languageProbability * 100);
for (MWTranscriptionSegment *seg in segments) {
    NSLog(@"[%.2fs -> %.2fs] %@", seg.start, seg.end, seg.text);
}
```

## Word Timestamps

**Python:**
```python
segments, _ = model.transcribe("audio.mp3", word_timestamps=True)
for segment in segments:
    for word in segment.words:
        print(f"[{word.start:.2f} -> {word.end:.2f}] {word.word}")
```

**MetalWhisper CLI:**
```bash
metalwhisper audio.mp3 --model turbo --word-timestamps
metalwhisper audio.mp3 --model turbo --word-timestamps --json  # structured output
```

**MetalWhisper Obj-C:**
```objc
opts.wordTimestamps = YES;
// ... transcribe as above ...
for (MWTranscriptionSegment *seg in segments) {
    for (MWWord *word in seg.words) {
        NSLog(@"[%.2f -> %.2f] %@ (p=%.2f)", word.start, word.end, word.word, word.probability);
    }
}
```

## VAD Filtering

**Python:**
```python
segments, _ = model.transcribe("audio.mp3", vad_filter=True)
```

**MetalWhisper CLI:**
```bash
metalwhisper audio.mp3 --model turbo --vad-filter --vad-model /path/to/silero_vad.onnx
```

**MetalWhisper Obj-C:**
```objc
opts.vadFilter = YES;
opts.vadModelPath = @"/path/to/silero_vad.onnx";
```

Note: MetalWhisper requires an explicit path to the Silero VAD ONNX model file. Python faster-whisper downloads it automatically.

## Language Detection

**Python:**
```python
model = WhisperModel("turbo")
segments, info = model.transcribe("audio.mp3")
print(info.language, info.language_probability)
```

**MetalWhisper CLI:**
```bash
metalwhisper audio.mp3 --model turbo --verbose  # prints detected language to stderr
```

**MetalWhisper Obj-C:**
```objc
// Automatic (during transcription)
MWTranscriptionInfo *info;
[t transcribeURL:url language:nil task:@"transcribe" typedOptions:nil
  segmentHandler:nil info:&info error:&error];
NSLog(@"%@ (%.2f)", info.language, info.languageProbability);

// Explicit detection
NSString *lang; float prob;
[t detectLanguageFromAudio:audioData segments:1 threshold:0.5
          detectedLanguage:&lang probability:&prob allLanguageProbs:nil error:&error];
```

## Translation

**Python:**
```python
segments, _ = model.transcribe("french.mp3", task="translate")
```

**MetalWhisper CLI:**
```bash
metalwhisper french.mp3 --model turbo --task translate
```

**MetalWhisper Obj-C:**
```objc
[t transcribeURL:url language:nil task:@"translate" typedOptions:nil
  segmentHandler:nil info:&info error:&error];
```

## Output Formats

**Python:**
```python
# Python outputs segment objects; formatting is manual or via faster-whisper-cli
from faster_whisper import WriteSRT
with open("output.srt", "w") as f:
    WriteSRT(f).write(segments)
```

**MetalWhisper CLI:**
```bash
metalwhisper audio.mp3 --model turbo --output-format srt --output-dir ./out
metalwhisper audio.mp3 --model turbo --output-format vtt --output-dir ./out
metalwhisper audio.mp3 --model turbo --json
metalwhisper audio.mp3 --model turbo --output-format text  # default
```

## Batched Inference

**Python:**
```python
from faster_whisper import BatchedInferencePipeline
batched = BatchedInferencePipeline(model=model)
segments, info = batched.transcribe("audio.mp3", batch_size=16)
```

**MetalWhisper Obj-C:**
```objc
[t transcribeBatchedURL:url language:nil task:@"transcribe" batchSize:16
                options:nil segmentHandler:nil info:&info error:&error];
```

Note: For single files, sequential mode (`transcribeURL:`) is typically faster than batched on Metal due to GPU scheduling overhead. Batched mode benefits audio with many speech segments separated by silence.

## Streaming (Segment Callback)

**Python:**
```python
segments, _ = model.transcribe("audio.mp3")
for segment in segments:  # generator, produces segments lazily
    print(segment.text)
```

**MetalWhisper Obj-C:**
```objc
[t transcribeURL:url language:nil task:@"transcribe" typedOptions:nil
  segmentHandler:^(MWTranscriptionSegment *seg, BOOL *stop) {
      NSLog(@"%@", seg.text);
      // *stop = YES;  // abort early
  } info:nil error:&error];
```

## Options Mapping

| Python parameter | CLI flag | Obj-C property |
|-----------------|----------|----------------|
| `beam_size=5` | `--beam-size 5` | `opts.beamSize = 5` |
| `word_timestamps=True` | `--word-timestamps` | `opts.wordTimestamps = YES` |
| `vad_filter=True` | `--vad-filter` | `opts.vadFilter = YES` |
| `language="en"` | `--language en` | `language:@"en"` (method param) |
| `task="translate"` | `--task translate` | `task:@"translate"` (method param) |
| `initial_prompt="..."` | `--initial-prompt "..."` | `opts.initialPrompt = @"..."` |
| `hotwords="..."` | `--hotwords "..."` | `opts.hotwords = @"..."` |
| `condition_on_previous_text=False` | `--no-condition-on-previous-text` | `opts.conditionOnPreviousText = NO` |
| `temperature=[0, 0.2, ...]` | `--temperature 0,0.2,...` | `opts.temperatures = @[@0, @0.2, ...]` |
| `compression_ratio_threshold=2.4` | (not exposed) | `opts.compressionRatioThreshold = 2.4` |
| `log_prob_threshold=-1.0` | (not exposed) | `opts.logProbThreshold = -1.0` |
| `no_speech_threshold=0.6` | (not exposed) | `opts.noSpeechThreshold = 0.6` |
| `repetition_penalty=1.0` | (not exposed) | `opts.repetitionPenalty = 1.0` |
| `patience=1.0` | (not exposed) | `opts.patience = 1.0` |

## Key Differences

1. **No Python runtime.** MetalWhisper is a compiled binary. No virtual environments, no pip, no dependency conflicts.

2. **Metal GPU only.** MetalWhisper uses Apple's Metal (MPS) backend exclusively. There is no CPU-only or CUDA mode.

3. **VAD model path is explicit.** Python faster-whisper downloads the Silero VAD model automatically. MetalWhisper requires `--vad-model <path>` pointing to the ONNX file.

4. **Model format is the same.** Both use CTranslate2-format models from HuggingFace. The same model files work with both tools.

5. **Manual memory management.** The Obj-C API uses manual retain/release (`-fno-objc-arc`). When embedding in ARC projects, the framework handles its own memory internally -- you only manage the objects you create.

6. **Audio format support.** MetalWhisper uses AVFoundation (WAV, MP3, M4A, FLAC, CAF, AIFF). Python uses PyAV/FFmpeg (broader format support). For unsupported formats, pipe through ffmpeg to MetalWhisper's stdin.

7. **Output formats built in.** The CLI produces SRT, VTT, JSON, and plain text directly. No additional libraries needed.
