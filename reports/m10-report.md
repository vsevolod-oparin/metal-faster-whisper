# M10 Milestone Report — Public API & Swift Integration

**Date:** 2026-03-20
**Status:** PASSED (5/5 tests)

## Summary

Created a typed options class (`MWTranscriptionOptions`), async completion handler API, and umbrella header (`MetalWhisper.h`). The Obj-C API is now clean enough for Swift apps to consume via bridging headers.

## What was built

### MWTranscriptionOptions

Replaces the untyped `NSDictionary` options with a proper Obj-C class:

```objc
MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
opts.beamSize = 3;
opts.wordTimestamps = YES;
opts.language = @"en";

NSArray *segments = [transcriber transcribeURL:url
                                     language:@"en"
                                         task:@"transcribe"
                                 typedOptions:opts
                               segmentHandler:nil
                                         info:&info
                                        error:&error];
```

26 configurable properties with sensible defaults, `NSCopying` support, and `toDictionary` for backward compatibility.

### Async API

```objc
[transcriber transcribeURL:url
                  language:@"en"
                      task:@"transcribe"
              typedOptions:opts
            segmentHandler:^(MWTranscriptionSegment *seg, BOOL *stop) {
                NSLog(@"[%f-%f] %@", seg.start, seg.end, seg.text);
            }
         completionHandler:^(NSArray *segments, MWTranscriptionInfo *info, NSError *error) {
                // Called on main queue
         }];
```

Dispatches to `QOS_CLASS_USER_INITIATED` background queue, calls completion on main queue. Proper MRC retain/release of captured objects.

### Umbrella Header

`MetalWhisper.h` imports all public headers — single import for framework users.

## Files

| File | Lines | Purpose |
|------|-------|---------|
| `src/MWTranscriptionOptions.h` | ~80 | Typed options with 26 properties |
| `src/MWTranscriptionOptions.mm` | ~200 | Defaults, NSCopying, toDictionary |
| `src/MetalWhisper.h` | 12 | Umbrella header |

## Test Results

| Test | Result |
|------|--------|
| m10_options_defaults | PASS — all 26 defaults verified |
| m10_options_copy | PASS — NSCopying independence confirmed |
| m10_options_to_dict | PASS — all keys present in dictionary |
| m10_transcribe_with_options | PASS — JFK speech transcribed correctly |
| m10_async_transcribe | PASS — completion handler called on main queue |

## Deferred to M12 (Xcode/SPM)

| Feature | Reason |
|---------|--------|
| Swift async/await wrapper | Requires Swift source file in Xcode/SPM |
| AsyncSequence streaming | Requires Swift source file |
| Task cancellation | Requires Swift structured concurrency |
| Live microphone capture | Requires AVAudioEngine + permissions |

These are Swift-side wrappers around the Obj-C API we've built. They'll be implemented when the Xcode project or Swift Package is set up in M12.

## Project Status: 112+ tests across 20 test suites, M0-M10 complete
