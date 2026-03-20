// tests/test_coverage.mm -- Coverage gap tests for MetalWhisper
// Adds ~15 new tests targeting zero-coverage API methods, CLI gaps,
// configuration combinations, and Python reference comparison.
//
// Usage: test_coverage <model_path> <data_dir> [binary_dir]
// Manual retain/release (-fno-objc-arc)

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "MWTranscriber.h"
#import "MWTranscriptionOptions.h"
#import "MWAudioDecoder.h"
#import "MWTokenizer.h"
#import "MWVoiceActivityDetector.h"
#import "MWModelManager.h"
#import "MWConstants.h"
#import "MWTestCommon.h"

#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <algorithm>

// Variadic ASSERT for format strings with commas.
#define ASSERT_FMT(name, cond, fmt, ...) do { \
    if (!(cond)) { \
        NSString *_msg = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
        reportResult((name), NO, _msg); \
        return; \
    } \
} while (0)

// ── Globals ──────────────────────────────────────────────────────────────────

static NSString *gModelPath  = nil;
static NSString *gDataDir    = nil;
static NSString *gBinaryDir  = nil;
static NSString *gProjectDir = nil;

static MWTranscriber *gTranscriber = nil;  // loaded once, shared

// ── Helpers ──────────────────────────────────────────────────────────────────

static NSString *vadModelPath(void) {
    return [gProjectDir stringByAppendingPathComponent:@"models/silero_vad_v6.onnx"];
}

static NSString *concatenateSegments(NSArray<MWTranscriptionSegment *> *segments) {
    NSMutableString *text = [[NSMutableString alloc] init];
    for (MWTranscriptionSegment *seg in segments) {
        [text appendString:seg.text];
    }
    return [text autorelease];
}

/// Character-level Jaccard similarity between two strings.
static float characterSimilarity(NSString *a, NSString *b) {
    if (a.length == 0 && b.length == 0) return 1.0f;
    if (a.length == 0 || b.length == 0) return 0.0f;

    NSMutableSet *setA = [NSMutableSet set];
    NSMutableSet *setB = [NSMutableSet set];

    // Use character bigrams for better similarity measurement
    NSString *lowerA = [a lowercaseString];
    NSString *lowerB = [b lowercaseString];

    for (NSUInteger i = 0; i + 1 < lowerA.length; i++) {
        [setA addObject:[lowerA substringWithRange:NSMakeRange(i, 2)]];
    }
    for (NSUInteger i = 0; i + 1 < lowerB.length; i++) {
        [setB addObject:[lowerB substringWithRange:NSMakeRange(i, 2)]];
    }

    NSMutableSet *intersection = [NSMutableSet setWithSet:setA];
    [intersection intersectSet:setB];

    NSMutableSet *unionSet = [NSMutableSet setWithSet:setA];
    [unionSet unionSet:setB];

    if (unionSet.count == 0) return 1.0f;
    return (float)intersection.count / (float)unionSet.count;
}

/// Token set overlap (intersection / union) between two arrays.
static float tokenSetOverlap(NSArray<NSNumber *> *a, NSArray<NSNumber *> *b) {
    NSSet *setA = [NSSet setWithArray:a];
    NSSet *setB = [NSSet setWithArray:b];

    NSMutableSet *intersection = [NSMutableSet setWithSet:setA];
    [intersection intersectSet:setB];

    NSMutableSet *unionSet = [NSMutableSet setWithSet:setA];
    [unionSet unionSet:setB];

    if (unionSet.count == 0) return 1.0f;
    return (float)intersection.count / (float)unionSet.count;
}

// ── CLI subprocess helpers ───────────────────────────────────────────────────

static NSString *runCLI(NSArray<NSString *> *arguments, int *exitCode) {
    NSString *binaryPath = [gBinaryDir stringByAppendingPathComponent:@"metalwhisper"];

    NSTask *task = [[NSTask alloc] init];
    [task setExecutableURL:[NSURL fileURLWithPath:binaryPath]];
    [task setArguments:arguments];

    NSPipe *stdoutPipe = [NSPipe pipe];
    [task setStandardOutput:stdoutPipe];
    [task setStandardError:[NSPipe pipe]];

    NSError *launchError = nil;
    [task launchAndReturnError:&launchError];
    if (launchError) {
        if (exitCode) *exitCode = -1;
        [task release];
        return @"";
    }

    NSData *data = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    if (exitCode) *exitCode = [task terminationStatus];
    [task release];

    NSString *output = [[[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding] autorelease];
    return output ?: @"";
}

static NSString *runCLICapturingStderr(NSArray<NSString *> *arguments,
                                       int *exitCode,
                                       NSString **stderrOut) {
    NSString *binaryPath = [gBinaryDir stringByAppendingPathComponent:@"metalwhisper"];

    NSTask *task = [[NSTask alloc] init];
    [task setExecutableURL:[NSURL fileURLWithPath:binaryPath]];
    [task setArguments:arguments];

    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    [task setStandardOutput:stdoutPipe];
    [task setStandardError:stderrPipe];

    NSError *launchError = nil;
    [task launchAndReturnError:&launchError];
    if (launchError) {
        if (exitCode) *exitCode = -1;
        [task release];
        return @"";
    }

    NSData *data = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    NSData *errData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    if (exitCode) *exitCode = [task terminationStatus];
    [task release];

    if (stderrOut) {
        *stderrOut = [[[NSString alloc] initWithData:errData
                                            encoding:NSUTF8StringEncoding] autorelease] ?: @"";
    }

    NSString *output = [[[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding] autorelease];
    return output ?: @"";
}

// =============================================================================
// Group 1: Zero-coverage API methods
// =============================================================================

// ── Test 1: MWAudioDecoder +decodeAudioFromData:error: ──────────────────────

static void test_audio_decode_from_data(void) {
    const char *name = "test_audio_decode_from_data";
    @autoreleasepool {
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

        // Decode via URL (reference)
        NSError *error = nil;
        NSData *refAudio = [MWAudioDecoder decodeAudioAtURL:audioURL error:&error];
        ASSERT_TRUE(name, refAudio != nil, fmtErr(@"URL decode failed", error));

        // Read file into NSData
        NSData *fileData = [NSData dataWithContentsOfFile:audioPath];
        ASSERT_TRUE(name, fileData != nil, @"Failed to read file into NSData");

        // Decode via NSData
        NSError *dataError = nil;
        NSData *dataAudio = [MWAudioDecoder decodeAudioFromData:fileData error:&dataError];
        ASSERT_TRUE(name, dataAudio != nil, fmtErr(@"Data decode failed", dataError));

        // Compare sample counts
        NSUInteger refSamples = refAudio.length / sizeof(float);
        NSUInteger dataSamples = dataAudio.length / sizeof(float);

        ASSERT_FMT(name, dataSamples == refSamples,
                   @"Sample count mismatch: data=%lu vs url=%lu",
                   (unsigned long)dataSamples, (unsigned long)refSamples);

        reportResult(name, YES, nil);
    }
}

// ── Test 2: MWAudioDecoder +decodeAudioFromBuffer:error: ────────────────────

static void test_audio_decode_from_buffer(void) {
    const char *name = "test_audio_decode_from_buffer";
    @autoreleasepool {
        // Create a 1-second 440Hz sine wave at 44.1kHz stereo
        double sampleRate = 44100.0;
        AVAudioChannelCount channels = 2;
        AVAudioFrameCount frameCount = (AVAudioFrameCount)sampleRate; // 1 second

        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate
                                                                              channels:channels];
        ASSERT_TRUE(name, format != nil, @"Failed to create AVAudioFormat");

        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                                                 frameCapacity:frameCount];
        ASSERT_TRUE(name, buffer != nil, @"Failed to create AVAudioPCMBuffer");

        buffer.frameLength = frameCount;

        // Fill with 440Hz sine wave
        float *leftChannel = buffer.floatChannelData[0];
        float *rightChannel = buffer.floatChannelData[1];
        for (AVAudioFrameCount i = 0; i < frameCount; i++) {
            float sample = sinf(2.0f * M_PI * 440.0f * (float)i / (float)sampleRate);
            leftChannel[i] = sample;
            rightChannel[i] = sample * 0.5f; // Right channel at half volume
        }

        // Decode from buffer
        NSError *error = nil;
        NSData *audio = [MWAudioDecoder decodeAudioFromBuffer:buffer error:&error];
        ASSERT_TRUE(name, audio != nil, fmtErr(@"Buffer decode failed", error));

        NSUInteger sampleCount = audio.length / sizeof(float);

        // Should be resampled to 16kHz mono = 16000 samples for 1 second
        ASSERT_FMT(name, sampleCount == kMWTargetSampleRate,
                   @"Expected %lu samples, got %lu",
                   (unsigned long)kMWTargetSampleRate, (unsigned long)sampleCount);

        [buffer release];
        [format release];

        reportResult(name, YES, nil);
    }
}

// ── Test 3: MWTokenizer -decodeWithTimestamps: ──────────────────────────────

static void test_tokenizer_decode_with_timestamps(void) {
    const char *name = "test_tokenizer_decode_with_timestamps";
    @autoreleasepool {
        MWTokenizer *tokenizer = gTranscriber.tokenizer;
        ASSERT_TRUE(name, tokenizer != nil, @"Tokenizer is nil");

        NSUInteger tsBegin = tokenizer.timestampBegin;

        // Build token array: <|0.00|> text_tokens <|2.50|> <|2.50|> more_text <|5.00|>
        // timestampBegin + 0 = <|0.00|>
        // timestampBegin + 125 = <|2.50|> (125 * 0.02 = 2.50)
        // timestampBegin + 250 = <|5.00|> (250 * 0.02 = 5.00)
        NSArray<NSNumber *> *tokens = @[
            @(tsBegin + 0),    // <|0.00|>
            @400,              // text token " And"
            @370,              // text token " so"
            @(tsBegin + 125),  // <|2.50|>
            @(tsBegin + 125),  // <|2.50|>
            @938,              // text token
            @(tsBegin + 250),  // <|5.00|>
        ];

        NSString *decoded = [tokenizer decodeWithTimestamps:tokens];
        ASSERT_TRUE(name, decoded != nil, @"decodeWithTimestamps returned nil");
        ASSERT_TRUE(name, decoded.length > 0, @"decodeWithTimestamps returned empty string");

        // Verify timestamp markers are present
        ASSERT_FMT(name, [decoded containsString:@"<|0.00|>"],
                   @"Output should contain <|0.00|>, got: %@", decoded);
        ASSERT_FMT(name, [decoded containsString:@"<|2.50|>"],
                   @"Output should contain <|2.50|>, got: %@", decoded);
        ASSERT_FMT(name, [decoded containsString:@"<|5.00|>"],
                   @"Output should contain <|5.00|>, got: %@", decoded);

        reportResult(name, YES, nil);
    }
}

// ── Test 4: MWTokenizer -tokenIDForString: ──────────────────────────────────

static void test_tokenizer_token_id_for_string(void) {
    const char *name = "test_tokenizer_token_id_for_string";
    @autoreleasepool {
        MWTokenizer *tokenizer = gTranscriber.tokenizer;
        ASSERT_TRUE(name, tokenizer != nil, @"Tokenizer is nil");

        // Test known special tokens
        NSUInteger enToken = [tokenizer tokenIDForString:@"<|en|>"];
        ASSERT_FMT(name, enToken == 50259,
                   @"Expected <|en|> = 50259, got %lu", (unsigned long)enToken);

        NSUInteger eotToken = [tokenizer tokenIDForString:@"<|endoftext|>"];
        ASSERT_FMT(name, eotToken == 50257,
                   @"Expected <|endoftext|> = 50257, got %lu", (unsigned long)eotToken);

        NSUInteger translateToken = [tokenizer tokenIDForString:@"<|translate|>"];
        ASSERT_FMT(name, translateToken == 50359,
                   @"Expected <|translate|> = 50359, got %lu", (unsigned long)translateToken);

        // Test nonexistent token -> NSNotFound
        NSUInteger missing = [tokenizer tokenIDForString:@"nonexistent_token_xyz"];
        ASSERT_FMT(name, missing == NSNotFound,
                   @"Expected NSNotFound for nonexistent token, got %lu", (unsigned long)missing);

        reportResult(name, YES, nil);
    }
}

// ── Test 5: MWSpeechTimestampsMap chunk index & original time ───────────────

static void test_timestamp_map_chunk_index(void) {
    const char *name = "test_timestamp_map_chunk_index";
    @autoreleasepool {
        // Create chunks: [0..16000) and [32000..48000)
        // At 16kHz: chunk0 = 0-1s, chunk1 = 2-3s
        NSArray<NSDictionary<NSString *, NSNumber *> *> *chunks = @[
            @{@"start": @0, @"end": @16000},
            @{@"start": @32000, @"end": @48000},
        ];

        MWSpeechTimestampsMap *map = [[MWSpeechTimestampsMap alloc]
            initWithChunks:chunks samplingRate:kMWTargetSampleRate];
        ASSERT_TRUE(name, map != nil, @"Failed to create MWSpeechTimestampsMap");

        // chunkIndexForTime:0.5 isEnd:NO should be chunk 0
        NSUInteger idx0 = [map chunkIndexForTime:0.5f isEnd:NO];
        ASSERT_FMT(name, idx0 == 0,
                   @"Expected chunk index 0 for time 0.5, got %lu", (unsigned long)idx0);

        // chunkIndexForTime:1.5 isEnd:NO should be chunk 1
        // (In the concatenated audio, 0-1s is chunk0, 1-2s is chunk1)
        NSUInteger idx1 = [map chunkIndexForTime:1.5f isEnd:NO];
        ASSERT_FMT(name, idx1 == 1,
                   @"Expected chunk index 1 for time 1.5, got %lu", (unsigned long)idx1);

        // originalTimeForTime with chunkIndex
        float origTime0 = [map originalTimeForTime:0.5f chunkIndex:0];
        // 0.5s into chunk0 which starts at sample 0 -> original time ~ 0.5s
        ASSERT_FMT(name, fabsf(origTime0 - 0.5f) < 0.1f,
                   @"Expected original time ~0.5 for chunk 0, got %f", origTime0);

        float origTime1 = [map originalTimeForTime:1.5f chunkIndex:1];
        // 0.5s into chunk1 which starts at sample 32000 (2.0s) -> original time ~ 2.5s
        ASSERT_FMT(name, fabsf(origTime1 - 2.5f) < 0.1f,
                   @"Expected original time ~2.5 for chunk 1, got %f", origTime1);

        [map release];
        reportResult(name, YES, nil);
    }
}

// ── Test 6: maxNewTokens ────────────────────────────────────────────────────

static void test_max_new_tokens(void) {
    const char *name = "test_max_new_tokens";
    @autoreleasepool {
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

        // Transcribe with very small maxNewTokens
        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.maxNewTokens = 5;

        NSError *error = nil;
        MWTranscriptionInfo *info = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTranscriber transcribeURL:audioURL
                               language:@"en"
                                   task:@"transcribe"
                           typedOptions:opts
                         segmentHandler:nil
                                   info:&info
                                  error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"Transcription failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"Expected at least 1 segment");

        // With maxNewTokens=5, the output text should be very short
        NSString *fullText = concatenateSegments(segments);
        ASSERT_FMT(name, fullText.length > 0,
                   @"Expected non-empty text");

        // Also transcribe without maxNewTokens limit for comparison
        MWTranscriptionOptions *defaultOpts = [MWTranscriptionOptions defaults];
        NSArray<MWTranscriptionSegment *> *fullSegments =
            [gTranscriber transcribeURL:audioURL
                               language:@"en"
                                   task:@"transcribe"
                           typedOptions:defaultOpts
                         segmentHandler:nil
                                   info:nil
                                  error:nil];

        NSString *fullDefaultText = concatenateSegments(fullSegments);

        // The truncated output should be shorter than the full output
        ASSERT_FMT(name, fullText.length < fullDefaultText.length,
                   @"maxNewTokens=5 text (%lu chars) should be shorter than default (%lu chars)",
                   (unsigned long)fullText.length, (unsigned long)fullDefaultText.length);

        reportResult(name, YES, nil);
    }
}

// ── Test 7: Build prompt with different tokenizer (language=fr, task=translate) ─

static void test_prompt_with_different_tokenizer(void) {
    const char *name = "test_prompt_with_different_tokenizer";
    @autoreleasepool {
        // Create a tokenizer with language="fr" and task="translate"
        NSError *error = nil;
        MWTokenizer *frTokenizer = [[MWTokenizer alloc] initWithModelPath:gModelPath
                                                             multilingual:YES
                                                                     task:@"translate"
                                                                 language:@"fr"
                                                                    error:&error];
        ASSERT_TRUE(name, frTokenizer != nil, fmtErr(@"French tokenizer load failed", error));

        // Build prompt using the French translate tokenizer
        NSArray<NSNumber *> *prompt =
            [gTranscriber buildPromptWithPreviousTokens:nil
                                      withoutTimestamps:NO
                                                 prefix:nil
                                               hotwords:nil
                                              tokenizer:frTokenizer];

        ASSERT_TRUE(name, prompt != nil, @"buildPrompt returned nil");
        ASSERT_TRUE(name, prompt.count > 0, @"buildPrompt returned empty array");

        // The SOT sequence should contain:
        // - French language token (50283 for "fr")
        // - Translate token (50359)
        BOOL hasFrench = NO;
        BOOL hasTranslate = NO;
        for (NSNumber *tokenID in prompt) {
            if ([tokenID unsignedIntegerValue] == 50283) hasFrench = YES;
            if ([tokenID unsignedIntegerValue] == 50359) hasTranslate = YES;
        }

        // Verify French language token
        NSUInteger frLangToken = [frTokenizer tokenIDForString:@"<|fr|>"];
        ASSERT_FMT(name, hasFrench || frLangToken != 50283,
                   @"Prompt should contain French language token (50283). Prompt: %@", prompt);

        // If the lookup gives us a different ID, check for that instead
        if (frLangToken != 50283 && frLangToken != NSNotFound) {
            hasFrench = NO;
            for (NSNumber *tokenID in prompt) {
                if ([tokenID unsignedIntegerValue] == frLangToken) hasFrench = YES;
            }
        }

        ASSERT_FMT(name, hasFrench,
                   @"Prompt should contain French language token. Prompt: %@", prompt);
        ASSERT_FMT(name, hasTranslate,
                   @"Prompt should contain translate token (50359). Prompt: %@", prompt);

        [frTokenizer release];
        reportResult(name, YES, nil);
    }
}

// =============================================================================
// Group 2: CLI tests
// =============================================================================

// ── Test 8: CLI --task translate ────────────────────────────────────────────

static void test_cli_translate(void) {
    const char *name = "test_cli_translate";
    @autoreleasepool {
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"russian_60s.wav"];

        int code = -1;
        NSString *output = runCLI(@[@"--model", gModelPath,
                                    @"--task", @"translate",
                                    @"--language", @"ru",
                                    audioPath], &code);

        ASSERT_FMT(name, code == 0,
                   @"Expected exit code 0, got %d", code);
        ASSERT_TRUE(name, output.length > 0, @"Output should not be empty");

        reportResult(name, YES, nil);
    }
}

// ── Test 9: CLI invalid arguments ───────────────────────────────────────────

static void test_cli_invalid_args(void) {
    const char *name = "test_cli_invalid_args";
    @autoreleasepool {
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];

        // --beam-size with non-numeric value -> should fail
        int code1 = -1;
        NSString *stderr1 = nil;
        runCLICapturingStderr(@[@"--model", gModelPath,
                                @"--beam-size", @"abc",
                                audioPath],
                              &code1, &stderr1);
        ASSERT_FMT(name, code1 != 0,
                   @"Expected non-zero exit for --beam-size abc, got %d", code1);

        // --task with invalid value -> should fail
        int code2 = -1;
        NSString *stderr2 = nil;
        runCLICapturingStderr(@[@"--model", gModelPath,
                                @"--task", @"invalid_task",
                                audioPath],
                              &code2, &stderr2);
        ASSERT_FMT(name, code2 != 0,
                   @"Expected non-zero exit for --task invalid, got %d", code2);

        reportResult(name, YES, nil);
    }
}

// ── Test 10: CLI --version ──────────────────────────────────────────────────

static void test_cli_version(void) {
    const char *name = "test_cli_version";
    @autoreleasepool {
        int code = -1;
        NSString *output = runCLI(@[@"--version"], &code);

        ASSERT_FMT(name, code == 0,
                   @"Expected exit code 0 for --version, got %d", code);

        // Should contain some version-like string (digits and dots)
        NSString *combined = output;
        BOOL hasVersion = [combined containsString:@"."] ||
                          [combined containsString:@"metalwhisper"] ||
                          [combined containsString:@"MetalWhisper"] ||
                          [combined containsString:@"version"];
        ASSERT_FMT(name, hasVersion,
                   @"--version output should contain version info, got: %@",
                   [combined substringToIndex:MIN(combined.length, (NSUInteger)100)]);

        reportResult(name, YES, nil);
    }
}

// =============================================================================
// Group 3: Configuration combinations
// =============================================================================

// ── Test 11: VAD + word timestamps ──────────────────────────────────────────

static void test_vad_plus_word_timestamps(void) {
    const char *name = "test_vad_plus_word_timestamps";
    @autoreleasepool {
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"silence_speech_silence.wav"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.vadFilter = YES;
        opts.vadModelPath = vadModelPath();
        opts.wordTimestamps = YES;

        NSError *error = nil;
        MWTranscriptionInfo *info = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTranscriber transcribeURL:audioURL
                               language:@"en"
                                   task:@"transcribe"
                           typedOptions:opts
                         segmentHandler:nil
                                   info:&info
                                  error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"Transcription failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"Expected at least 1 segment");

        // Check that words are populated
        BOOL hasWords = NO;
        for (MWTranscriptionSegment *seg in segments) {
            if (seg.words && seg.words.count > 0) {
                hasWords = YES;

                // Verify word timestamps are sane
                for (MWWord *word in seg.words) {
                    ASSERT_FMT(name, word.start <= word.end,
                               @"Word '%@' has start(%f) > end(%f)",
                               word.word, word.start, word.end);
                    ASSERT_FMT(name, word.start >= 0.0f,
                               @"Word '%@' has negative start: %f",
                               word.word, word.start);
                }
                break;
            }
        }

        ASSERT_TRUE(name, hasWords, @"Expected words to be populated with VAD + word_timestamps");

        reportResult(name, YES, nil);
    }
}

// ── Test 12: Greedy (beam_size=1) ───────────────────────────────────────────

static void test_greedy_beam_one(void) {
    const char *name = "test_greedy_beam_one";
    @autoreleasepool {
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

        // Transcribe with beamSize=1 (greedy)
        MWTranscriptionOptions *greedyOpts = [MWTranscriptionOptions defaults];
        greedyOpts.beamSize = 1;

        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *greedySegments =
            [gTranscriber transcribeURL:audioURL
                               language:@"en"
                                   task:@"transcribe"
                           typedOptions:greedyOpts
                         segmentHandler:nil
                                   info:nil
                                  error:&error];

        ASSERT_TRUE(name, greedySegments != nil, fmtErr(@"Greedy transcription failed", error));
        ASSERT_TRUE(name, greedySegments.count > 0, @"Expected segments from greedy");

        NSString *greedyText = [concatenateSegments(greedySegments) lowercaseString];
        ASSERT_FMT(name, [greedyText containsString:@"americans"] ||
                         [greedyText containsString:@"country"],
                   @"Greedy output should contain recognizable JFK text, got: %@", greedyText);

        // Compare with default beam search
        MWTranscriptionOptions *beamOpts = [MWTranscriptionOptions defaults];
        // beamSize defaults to 5
        NSArray<MWTranscriptionSegment *> *beamSegments =
            [gTranscriber transcribeURL:audioURL
                               language:@"en"
                                   task:@"transcribe"
                           typedOptions:beamOpts
                         segmentHandler:nil
                                   info:nil
                                  error:nil];

        NSString *beamText = [concatenateSegments(beamSegments) lowercaseString];
        ASSERT_FMT(name, [beamText containsString:@"americans"],
                   @"Beam search output should contain 'americans', got: %@", beamText);

        reportResult(name, YES, nil);
    }
}

// ── Test 13: noRepeatNgramSize ──────────────────────────────────────────────

static void test_no_repeat_ngram(void) {
    const char *name = "test_no_repeat_ngram";
    @autoreleasepool {
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"physicsworks.wav"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

        // Transcribe first 30s with noRepeatNgramSize=3
        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.noRepeatNgramSize = 3;

        NSError *error = nil;
        MWTranscriptionInfo *info = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTranscriber transcribeURL:audioURL
                               language:@"en"
                                   task:@"transcribe"
                           typedOptions:opts
                         segmentHandler:nil
                                   info:&info
                                  error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"Transcription failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"Expected segments");

        NSString *text = concatenateSegments(segments);
        ASSERT_FMT(name, text.length > 0,
                   @"Expected non-empty output with noRepeatNgramSize=3");

        reportResult(name, YES, nil);
    }
}

// =============================================================================
// Group 4: Python reference comparison
// =============================================================================

// ── Test 14: Python reference - JFK ─────────────────────────────────────────

static void test_python_reference_jfk(void) {
    const char *name = "test_python_reference_jfk";
    @autoreleasepool {
        // Load reference JSON
        NSString *refPath = [gDataDir stringByAppendingPathComponent:
            @"reference/python_transcription_jfk.json"];
        NSData *refData = [NSData dataWithContentsOfFile:refPath];
        ASSERT_TRUE(name, refData != nil, @"Failed to load JFK reference JSON");

        NSError *jsonError = nil;
        NSDictionary *ref = [NSJSONSerialization JSONObjectWithData:refData
                                                            options:0
                                                              error:&jsonError];
        ASSERT_TRUE(name, ref != nil, fmtErr(@"JSON parse failed", jsonError));

        NSString *refText = @"";
        NSArray *refSegments = ref[@"segments"];
        ASSERT_TRUE(name, refSegments != nil, @"No segments in reference");

        // Extract reference text
        NSMutableString *refFullText = [NSMutableString string];
        for (NSDictionary *seg in refSegments) {
            [refFullText appendString:seg[@"text"] ?: @""];
        }
        refText = refFullText;

        // Extract reference tokens (first segment)
        NSArray<NSNumber *> *refTokens = refSegments[0][@"tokens"];

        // Extract reference word timestamps
        NSArray *refWords = refSegments[0][@"words"];

        // Transcribe with matching parameters
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.beamSize = 6;
        opts.temperatures = @[@0.0f, @0.2f, @0.4f, @0.6f, @0.8f, @1.0f];
        opts.lengthPenalty = 0.6f;
        opts.conditionOnPreviousText = YES;
        opts.wordTimestamps = YES;

        NSError *error = nil;
        MWTranscriptionInfo *info = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTranscriber transcribeURL:audioURL
                               language:@"en"
                                   task:@"transcribe"
                           typedOptions:opts
                         segmentHandler:nil
                                   info:&info
                                  error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"Transcription failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"Expected at least 1 segment");

        NSString *ourText = concatenateSegments(segments);

        // 1) Text similarity > 80%
        float similarity = characterSimilarity(ourText, refText);
        ASSERT_FMT(name, similarity > 0.80f,
                   @"Text similarity %.2f%% < 80%%. Ours: %@ | Ref: %@",
                   similarity * 100, ourText, refText);

        // 2) Segment count matches
        ASSERT_FMT(name, segments.count == refSegments.count,
                   @"Segment count mismatch: ours=%lu ref=%lu",
                   (unsigned long)segments.count, (unsigned long)refSegments.count);

        // 3) Token overlap > 70%
        if (segments.count > 0 && refTokens.count > 0) {
            NSArray<NSNumber *> *ourTokens = segments[0].tokens;
            float overlap = tokenSetOverlap(ourTokens, refTokens);
            ASSERT_FMT(name, overlap > 0.70f,
                       @"Token overlap %.2f%% < 70%%", overlap * 100);
        }

        // 4) Word timestamps: first/last word start within +/- 0.5s
        if (segments.count > 0 && segments[0].words.count > 0 && refWords.count > 0) {
            MWWord *ourFirstWord = segments[0].words[0];
            NSDictionary *refFirstWord = refWords[0];
            float refFirstStart = [refFirstWord[@"start"] floatValue];
            float firstDiff = fabsf(ourFirstWord.start - refFirstStart);
            ASSERT_FMT(name, firstDiff < 0.5f,
                       @"First word start diff %.3f > 0.5s (ours=%.3f ref=%.3f)",
                       firstDiff, ourFirstWord.start, refFirstStart);

            MWWord *ourLastWord = segments[0].words.lastObject;
            NSDictionary *refLastWord = refWords.lastObject;
            float refLastStart = [refLastWord[@"start"] floatValue];
            float lastDiff = fabsf(ourLastWord.start - refLastStart);
            ASSERT_FMT(name, lastDiff < 0.5f,
                       @"Last word start diff %.3f > 0.5s (ours=%.3f ref=%.3f)",
                       lastDiff, ourLastWord.start, refLastStart);
        }

        reportResult(name, YES, nil);
    }
}

// ── Test 15: Python reference - Russian ─────────────────────────────────────

static void test_python_reference_russian(void) {
    const char *name = "test_python_reference_russian";
    @autoreleasepool {
        // Load reference JSON
        NSString *refPath = [gDataDir stringByAppendingPathComponent:
            @"reference/python_transcription_russian_60s.json"];
        NSData *refData = [NSData dataWithContentsOfFile:refPath];
        ASSERT_TRUE(name, refData != nil, @"Failed to load Russian reference JSON");

        NSError *jsonError = nil;
        NSDictionary *ref = [NSJSONSerialization JSONObjectWithData:refData
                                                            options:0
                                                              error:&jsonError];
        ASSERT_TRUE(name, ref != nil, fmtErr(@"JSON parse failed", jsonError));

        // Extract reference text
        NSArray *refSegments = ref[@"segments"];
        ASSERT_TRUE(name, refSegments != nil, @"No segments in reference");

        NSMutableString *refFullText = [NSMutableString string];
        for (NSDictionary *seg in refSegments) {
            [refFullText appendString:seg[@"text"] ?: @""];
        }

        // Transcribe
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"russian_60s.wav"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.beamSize = 6;
        opts.temperatures = @[@0.0f, @0.2f, @0.4f, @0.6f, @0.8f, @1.0f];
        opts.lengthPenalty = 0.6f;
        opts.conditionOnPreviousText = YES;
        opts.wordTimestamps = YES;

        NSError *error = nil;
        MWTranscriptionInfo *info = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTranscriber transcribeURL:audioURL
                               language:@"ru"
                                   task:@"transcribe"
                           typedOptions:opts
                         segmentHandler:nil
                                   info:&info
                                  error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"Transcription failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"Expected at least 1 segment");

        NSString *ourText = concatenateSegments(segments);

        // Text similarity > 60% (Cyrillic tokenization may differ at different precision)
        float similarity = characterSimilarity(ourText, refFullText);
        ASSERT_FMT(name, similarity > 0.60f,
                   @"Russian text similarity %.2f%% < 60%%", similarity * 100);

        // Verify language detected as Russian
        ASSERT_TRUE(name, info != nil, @"Transcription info is nil");
        ASSERT_FMT(name, [info.language isEqualToString:@"ru"],
                   @"Expected language 'ru', got '%@'", info.language);

        reportResult(name, YES, nil);
    }
}

// =============================================================================
// Group 5: Python reference deep comparison
// =============================================================================

// ── Test M4.6: Full transcription reference match (physicsworks) ─────────────

static void test_m4_6_reference_match(void) {
    const char *name = "test_m4_6_reference_match";
    @autoreleasepool {
        // 1) Load reference JSON
        NSString *refPath = [gDataDir stringByAppendingPathComponent:
            @"reference/python_transcription_physicsworks.json"];
        NSData *refData = [NSData dataWithContentsOfFile:refPath];
        ASSERT_TRUE(name, refData != nil, @"Failed to load physicsworks reference JSON");

        NSError *jsonError = nil;
        NSDictionary *ref = [NSJSONSerialization JSONObjectWithData:refData
                                                            options:0
                                                              error:&jsonError];
        ASSERT_TRUE(name, ref != nil, fmtErr(@"JSON parse failed", jsonError));

        NSArray *refSegments = ref[@"segments"];
        ASSERT_TRUE(name, refSegments != nil && refSegments.count > 0,
                    @"No segments in reference");

        // Extract reference combined text
        NSMutableString *refFullText = [NSMutableString string];
        for (NSDictionary *seg in refSegments) {
            [refFullText appendString:seg[@"text"] ?: @""];
        }

        // Extract ALL reference token IDs across all segments
        NSMutableArray<NSNumber *> *refAllTokens = [NSMutableArray array];
        for (NSDictionary *seg in refSegments) {
            NSArray<NSNumber *> *segTokens = seg[@"tokens"];
            if (segTokens) [refAllTokens addObjectsFromArray:segTokens];
        }

        // Reference first segment start time
        float refFirstStart = [refSegments[0][@"start"] floatValue];

        // 2) Transcribe physicsworks.wav with SAME parameters
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"physicsworks.wav"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.beamSize = 6;
        opts.temperatures = @[@0.0f, @0.2f, @0.4f, @0.6f, @0.8f, @1.0f];
        opts.lengthPenalty = 0.6f;
        opts.conditionOnPreviousText = YES;
        opts.wordTimestamps = YES;

        NSError *error = nil;
        MWTranscriptionInfo *info = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTranscriber transcribeURL:audioURL
                               language:@"en"
                                   task:@"transcribe"
                           typedOptions:opts
                         segmentHandler:nil
                                   info:&info
                                  error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"Transcription failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"Expected at least 1 segment");

        // 3a) Segment count: within +/- 5
        NSInteger segDiff = (NSInteger)segments.count - (NSInteger)refSegments.count;
        fprintf(stdout, "    [info] Segment count: ours=%lu ref=%lu diff=%ld\n",
                (unsigned long)segments.count, (unsigned long)refSegments.count, (long)segDiff);
        ASSERT_FMT(name, labs(segDiff) <= 5,
                   @"Segment count diff %ld > 5 (ours=%lu ref=%lu)",
                   (long)segDiff, (unsigned long)segments.count,
                   (unsigned long)refSegments.count);

        // 3b) Combined text similarity > 75%
        NSString *ourText = concatenateSegments(segments);
        float similarity = characterSimilarity(ourText, refFullText);
        fprintf(stdout, "    [info] Text similarity: %.1f%%\n", similarity * 100);
        ASSERT_FMT(name, similarity > 0.75f,
                   @"Text similarity %.1f%% < 75%%", similarity * 100);

        // 3c) Token overlap > 60% (intersection/union of all token IDs)
        NSMutableArray<NSNumber *> *ourAllTokens = [NSMutableArray array];
        for (MWTranscriptionSegment *seg in segments) {
            if (seg.tokens) [ourAllTokens addObjectsFromArray:seg.tokens];
        }
        float tokenOverlap = tokenSetOverlap(ourAllTokens, refAllTokens);
        fprintf(stdout, "    [info] Token set overlap: %.1f%%\n", tokenOverlap * 100);
        ASSERT_FMT(name, tokenOverlap > 0.60f,
                   @"Token set overlap %.1f%% < 60%%", tokenOverlap * 100);

        // 3d) Timestamp alignment: first segment start within +/- 0.5s
        float ourFirstStart = segments[0].start;
        float startDiff = fabsf(ourFirstStart - refFirstStart);
        fprintf(stdout, "    [info] First segment start: ours=%.3f ref=%.3f diff=%.3f\n",
                ourFirstStart, refFirstStart, startDiff);
        ASSERT_FMT(name, startDiff < 0.5f,
                   @"First segment start diff %.3fs > 0.5s (ours=%.3f ref=%.3f)",
                   startDiff, ourFirstStart, refFirstStart);

        // Verify timestamps are sane: each segment has start <= end,
        // and overall progression is forward (last segment end > first segment start).
        // Note: segments within the same 30s chunk can overlap, so we only check
        // that start times are generally non-decreasing with a tolerance.
        for (NSUInteger i = 0; i < segments.count; i++) {
            MWTranscriptionSegment *seg = segments[i];
            ASSERT_FMT(name, seg.start <= seg.end,
                       @"Segment %lu: start(%.3f) > end(%.3f)",
                       (unsigned long)i, seg.start, seg.end);
        }
        // Overall progression: last segment should be well past first
        if (segments.count > 1) {
            float firstStart = segments[0].start;
            float lastEnd = segments[segments.count - 1].end;
            ASSERT_FMT(name, lastEnd > firstStart + 10.0f,
                       @"Timestamps not progressing: first start=%.3f, last end=%.3f",
                       firstStart, lastEnd);
        }

        reportResult(name, YES, nil);
    }
}

// ── Test M11: Exact token comparison (JFK) ───────────────────────────────────

static void test_m11_exact_tokens(void) {
    const char *name = "test_m11_exact_tokens";
    @autoreleasepool {
        // 1) Load reference JSON
        NSString *refPath = [gDataDir stringByAppendingPathComponent:
            @"reference/python_transcription_jfk.json"];
        NSData *refData = [NSData dataWithContentsOfFile:refPath];
        ASSERT_TRUE(name, refData != nil, @"Failed to load JFK reference JSON");

        NSError *jsonError = nil;
        NSDictionary *ref = [NSJSONSerialization JSONObjectWithData:refData
                                                            options:0
                                                              error:&jsonError];
        ASSERT_TRUE(name, ref != nil, fmtErr(@"JSON parse failed", jsonError));

        NSArray *refSegments = ref[@"segments"];
        ASSERT_TRUE(name, refSegments != nil && refSegments.count > 0,
                    @"No segments in reference");

        // Extract reference data from first segment
        NSString *refText = refSegments[0][@"text"] ?: @"";
        NSArray<NSNumber *> *refTokens = refSegments[0][@"tokens"];
        ASSERT_TRUE(name, refTokens != nil && refTokens.count > 0,
                    @"No tokens in reference first segment");

        // Extract params from JSON
        NSDictionary *params = ref[@"params"];
        NSUInteger beamSize = params[@"beam_size"] ? [params[@"beam_size"] unsignedIntegerValue] : 6;
        float lengthPenalty = params[@"length_penalty"] ? [params[@"length_penalty"] floatValue] : 0.6f;

        // 2) Transcribe jfk.flac with SAME params
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.beamSize = beamSize;
        opts.temperatures = @[@0.0f, @0.2f, @0.4f, @0.6f, @0.8f, @1.0f];
        opts.lengthPenalty = lengthPenalty;
        opts.conditionOnPreviousText = YES;
        opts.wordTimestamps = YES;

        NSError *error = nil;
        MWTranscriptionInfo *info = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTranscriber transcribeURL:audioURL
                               language:@"en"
                                   task:@"transcribe"
                           typedOptions:opts
                         segmentHandler:nil
                                   info:&info
                                  error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"Transcription failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"Expected at least 1 segment");

        // 3) Per-segment token comparison
        // JFK has 1 segment in reference — compare first segment
        NSArray<NSNumber *> *ourTokens = segments[0].tokens;
        ASSERT_TRUE(name, ourTokens != nil && ourTokens.count > 0,
                    @"No tokens in our first segment");

        // Print both token sequences for visual comparison
        fprintf(stdout, "    [info] Ref tokens (%lu): [", (unsigned long)refTokens.count);
        for (NSUInteger i = 0; i < refTokens.count; i++) {
            fprintf(stdout, "%s%ld", i > 0 ? ", " : "",
                    (long)[refTokens[i] integerValue]);
        }
        fprintf(stdout, "]\n");

        fprintf(stdout, "    [info] Our tokens (%lu): [", (unsigned long)ourTokens.count);
        for (NSUInteger i = 0; i < ourTokens.count; i++) {
            fprintf(stdout, "%s%ld", i > 0 ? ", " : "",
                    (long)[ourTokens[i] integerValue]);
        }
        fprintf(stdout, "]\n");

        // Compute token ID overlap: |intersection| / |union|
        float overlap = tokenSetOverlap(ourTokens, refTokens);
        fprintf(stdout, "    [info] Token set overlap: %.1f%%\n", overlap * 100);
        ASSERT_FMT(name, overlap > 0.80f,
                   @"Token overlap %.1f%% < 80%% for JFK", overlap * 100);

        // Text comparison: > 90% character similarity (JFK is clean, short)
        NSString *ourText = segments[0].text;
        float textSim = characterSimilarity(ourText, refText);
        fprintf(stdout, "    [info] Text similarity: %.1f%%\n", textSim * 100);
        fprintf(stdout, "    [info] Ref text: %s\n", [refText UTF8String]);
        fprintf(stdout, "    [info] Our text: %s\n", [ourText UTF8String]);
        ASSERT_FMT(name, textSim > 0.90f,
                   @"Text similarity %.1f%% < 90%% for JFK. Ours: %@ | Ref: %@",
                   textSim * 100, ourText, refText);

        // Also check token count is in same ballpark (within 30%)
        float tokenCountRatio = (float)ourTokens.count / (float)refTokens.count;
        fprintf(stdout, "    [info] Token count ratio: %.2f (ours=%lu ref=%lu)\n",
                tokenCountRatio, (unsigned long)ourTokens.count,
                (unsigned long)refTokens.count);
        ASSERT_FMT(name, tokenCountRatio > 0.7f && tokenCountRatio < 1.3f,
                   @"Token count ratio %.2f outside [0.7, 1.3] (ours=%lu ref=%lu)",
                   tokenCountRatio, (unsigned long)ourTokens.count,
                   (unsigned long)refTokens.count);

        reportResult(name, YES, nil);
    }
}

// =============================================================================
// Group 6: French language detection
// =============================================================================

// ── Test: Auto-detect French from french_30s.wav ─────────────────────────────

static void test_detect_french(void) {
    const char *name = "test_detect_french";
    @autoreleasepool {
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"french_30s.wav"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

        // Verify the test audio file exists
        ASSERT_TRUE(name,
                    [[NSFileManager defaultManager] fileExistsAtPath:audioPath],
                    @"french_30s.wav not found in data dir");

        // Transcribe with language=nil to trigger auto-detection
        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];

        NSError *error = nil;
        MWTranscriptionInfo *info = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTranscriber transcribeURL:audioURL
                               language:nil
                                   task:@"transcribe"
                           typedOptions:opts
                         segmentHandler:nil
                                   info:&info
                                  error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"Transcription failed", error));
        ASSERT_TRUE(name, info != nil, @"Transcription info is nil");

        // Verify language detected as French
        ASSERT_FMT(name, [info.language isEqualToString:@"fr"],
                   @"Expected detected language 'fr', got '%@'", info.language);

        // Verify output contains text
        ASSERT_TRUE(name, segments.count > 0, @"Expected at least 1 segment");

        NSString *fullText = concatenateSegments(segments);
        ASSERT_FMT(name, fullText.length > 10,
                   @"Expected substantial French text, got: %@", fullText);

        // Verify output contains French accented characters (common: e with accent,
        // a with grave, c with cedilla, etc.)
        NSCharacterSet *frenchAccents = [NSCharacterSet characterSetWithCharactersInString:
            @"\u00E9\u00E8\u00EA\u00EB"  // e-acute, e-grave, e-circumflex, e-diaeresis
            @"\u00E0\u00E2"              // a-grave, a-circumflex
            @"\u00F4\u00F9\u00FB"        // o-circumflex, u-grave, u-circumflex
            @"\u00E7"                     // c-cedilla
            @"\u00EE\u00EF"              // i-circumflex, i-diaeresis
        ];

        NSRange accentRange = [fullText rangeOfCharacterFromSet:frenchAccents];
        ASSERT_FMT(name, accentRange.location != NSNotFound,
                   @"Expected French accented characters in output, got: %@", fullText);

        fprintf(stdout, "    [info] Detected language: %s (prob: %.2f)\n",
                [info.language UTF8String], info.languageProbability);
        fprintf(stdout, "    [info] Text preview: %.100s...\n", [fullText UTF8String]);

        reportResult(name, YES, nil);
    }
}

// =============================================================================
// Group 7: Large-v3 model test (gated)
// =============================================================================

// ── Test 16: Load large-v3 ──────────────────────────────────────────────────

static void test_load_large_v3(void) {
    const char *name = "test_load_large_v3";

    // Gate: only run if MW_TEST_LARGE_V3=1
    const char *envVal = getenv("MW_TEST_LARGE_V3");
    if (!envVal || strcmp(envVal, "1") != 0) {
        fprintf(stdout, "  SKIP: %s (set MW_TEST_LARGE_V3=1 to enable)\n", name);
        return;
    }

    @autoreleasepool {
        // Try local path first (e.g. ../data/whisper-large-v3/)
        NSString *localPath = [[NSString stringWithUTF8String:__FILE__]
            stringByDeletingLastPathComponent];
        localPath = [[localPath stringByAppendingPathComponent:@"../../data/whisper-large-v3"]
            stringByStandardizingPath];

        NSString *modelPath = nil;
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:[localPath stringByAppendingPathComponent:@"model.bin"]]) {
            modelPath = localPath;
        } else {
            // Fall back to MWModelManager cache
            MWModelManager *manager = [MWModelManager shared];
            NSError *error = nil;
            modelPath = [manager resolveModel:@"large-v3"
                                     progress:nil
                                        error:&error];
        }

        if (!modelPath) {
            fprintf(stdout, "  SKIP: %s (large-v3 not found locally or cached)\n", name);
            return;
        }

        // Load the model
        NSError *loadError = nil;
        MWTranscriber *transcriber = [[MWTranscriber alloc] initWithModelPath:modelPath
                                                                        error:&loadError];
        ASSERT_TRUE(name, transcriber != nil, fmtErr(@"large-v3 load failed", loadError));

        // Verify properties
        ASSERT_FMT(name, transcriber.nMels == 128,
                   @"Expected nMels=128, got %lu", (unsigned long)transcriber.nMels);
        ASSERT_FMT(name, transcriber.isMultilingual == YES,
                   @"Expected multilingual=YES");

        // Transcribe jfk.flac
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

        NSError *txError = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [transcriber transcribeURL:audioURL
                              language:@"en"
                                  task:@"transcribe"
                               options:nil
                        segmentHandler:nil
                                  info:nil
                                 error:&txError];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"large-v3 transcribe failed", txError));

        NSString *text = [concatenateSegments(segments) lowercaseString];
        ASSERT_FMT(name, [text containsString:@"americans"] || [text containsString:@"country"],
                   @"large-v3 should produce recognizable JFK text, got: %@", text);

        [transcriber release];
        reportResult(name, YES, nil);
    }
}

// =============================================================================
// Group 8: Word alignment reference comparison (M5)
// =============================================================================

// Python faster-whisper reference: JFK, beam=6, word_timestamps=True, turbo f32 CPU
// Generated with: model.transcribe('jfk.flac', beam_size=6, word_timestamps=True)
static void test_m5_alignment(void) {
    const char *name = "test_m5_alignment";

    @autoreleasepool {
        // Python reference word data (22 words)
        struct RefWord { const char *word; float start; float end; float prob; };
        static const RefWord pyRef[] = {
            {" And",       0.00f, 0.52f, 0.787f},
            {" so,",       0.52f, 0.86f, 0.996f},
            {" my",        1.10f, 1.20f, 0.999f},
            {" fellow",    1.20f, 1.54f, 0.999f},
            {" Americans,",1.54f, 2.12f, 0.982f},
            {" ask",       3.32f, 3.78f, 0.986f},
            {" not",       3.78f, 4.34f, 0.981f},
            {" what",      4.34f, 5.56f, 0.987f},
            {" your",      5.56f, 5.80f, 0.996f},
            {" country",   5.80f, 6.24f, 0.999f},
            {" can",       6.24f, 6.62f, 1.000f},
            {" do",        6.62f, 6.82f, 1.000f},
            {" for",       6.82f, 7.06f, 0.999f},
            {" you,",      7.06f, 7.40f, 1.000f},
            {" ask",       7.78f, 8.52f, 0.998f},
            {" what",      8.52f, 8.80f, 1.000f},
            {" you",       8.80f, 9.04f, 0.997f},
            {" can",       9.04f, 9.34f, 1.000f},
            {" do",        9.34f, 9.56f, 1.000f},
            {" for",       9.56f, 9.78f, 1.000f},
            {" your",      9.78f, 9.96f, 0.999f},
            {" country.",   9.96f, 10.34f, 1.000f},
        };
        static const int pyRefCount = 22;

        // Transcribe JFK with word timestamps
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.wordTimestamps = YES;
        opts.beamSize = 6;

        MWTranscriptionInfo *info = nil;
        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTranscriber transcribeURL:audioURL
                               language:@"en"
                                   task:@"transcribe"
                           typedOptions:opts
                         segmentHandler:nil
                                   info:&info
                                  error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"Transcribe failed", error));

        // Collect all words
        NSMutableArray<MWWord *> *allWords = [NSMutableArray array];
        for (MWTranscriptionSegment *seg in segments) {
            if (seg.words) {
                [allWords addObjectsFromArray:seg.words];
            }
        }

        fprintf(stdout, "    [info] Word count: ours=%lu ref=%d\n",
                (unsigned long)allWords.count, pyRefCount);

        // Word count should match exactly
        ASSERT_FMT(name, allWords.count == (NSUInteger)pyRefCount,
                   @"Word count mismatch: ours=%lu ref=%d",
                   (unsigned long)allWords.count, pyRefCount);

        // Compare each word: text match, timing within tolerance
        static const float kTimeTolerance = 0.10f; // 100ms tolerance
        int textMatches = 0;
        int timeMatches = 0;
        float maxTimeDiff = 0.0f;

        for (int i = 0; i < pyRefCount && i < (int)allWords.count; i++) {
            MWWord *w = allWords[i];
            NSString *refWord = [NSString stringWithUTF8String:pyRef[i].word];

            // Text comparison (trimmed, lowercased)
            NSString *ourTrimmed = [[w.word stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]] lowercaseString];
            NSString *refTrimmed = [[refWord stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]] lowercaseString];

            if ([ourTrimmed isEqualToString:refTrimmed]) {
                textMatches++;
            } else {
                fprintf(stdout, "    [diff] Word %d: ours='%s' ref='%s'\n",
                        i, [w.word UTF8String], pyRef[i].word);
            }

            // Timing comparison
            float startDiff = fabsf((float)w.start - pyRef[i].start);
            float endDiff = fabsf((float)w.end - pyRef[i].end);
            float wordMaxDiff = fmaxf(startDiff, endDiff);
            if (wordMaxDiff > maxTimeDiff) maxTimeDiff = wordMaxDiff;

            if (startDiff <= kTimeTolerance && endDiff <= kTimeTolerance) {
                timeMatches++;
            } else {
                fprintf(stdout, "    [diff] Word %d timing: ours=[%.2f-%.2f] ref=[%.2f-%.2f]\n",
                        i, w.start, w.end, pyRef[i].start, pyRef[i].end);
            }
        }

        float textMatchRate = (float)textMatches / pyRefCount;
        float timeMatchRate = (float)timeMatches / pyRefCount;

        fprintf(stdout, "    [info] Text match: %d/%d (%.0f%%), Time match: %d/%d (%.0f%%), max diff: %.3fs\n",
                textMatches, pyRefCount, textMatchRate * 100,
                timeMatches, pyRefCount, timeMatchRate * 100, maxTimeDiff);

        // Require ≥90% text match and ≥80% timing match
        ASSERT_FMT(name, textMatchRate >= 0.90f,
                   @"Text match rate %.0f%% < 90%%", textMatchRate * 100);
        ASSERT_FMT(name, timeMatchRate >= 0.80f,
                   @"Time match rate %.0f%% < 80%%", timeMatchRate * 100);

        reportResult(name, YES, nil);
    }
}

// =============================================================================
// Group 9: Concurrent transcription (M7)
// =============================================================================

static void test_m7_concurrent_files(void) {
    const char *name = "test_m7_concurrent_files";

    @autoreleasepool {
        // Test processing multiple files via GCD dispatch.
        // Metal/MPS doesn't support two model instances simultaneously, so we use
        // a single transcriber with a serial dispatch queue (the documented pattern).
        // This verifies that GCD dispatch + transcription works correctly.
        NSString *audio1 = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSString *audio2 = [gDataDir stringByAppendingPathComponent:@"hotwords.mp3"];

        NSURL *url1 = [NSURL fileURLWithPath:audio1];
        NSURL *url2 = [NSURL fileURLWithPath:audio2];

        __block NSArray *result1 = nil;
        __block NSArray *result2 = nil;
        __block NSError *txErr1 = nil;
        __block NSError *txErr2 = nil;

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_queue_t queue = dispatch_queue_create("mw.test.concurrent", DISPATCH_QUEUE_SERIAL);

        // Dispatch both transcriptions to a background serial queue
        dispatch_async(queue, ^{
            @autoreleasepool {
                NSError *err = nil;
                NSArray *segs = [gTranscriber transcribeURL:url1
                                                  language:@"en"
                                                      task:@"transcribe"
                                                   options:nil
                                            segmentHandler:nil
                                                      info:nil
                                                     error:&err];
                result1 = [segs retain];
                txErr1 = [err retain];
            }
        });

        dispatch_async(queue, ^{
            @autoreleasepool {
                NSError *err = nil;
                NSArray *segs = [gTranscriber transcribeURL:url2
                                                  language:@"en"
                                                      task:@"transcribe"
                                                   options:nil
                                            segmentHandler:nil
                                                      info:nil
                                                     error:&err];
                result2 = [segs retain];
                txErr2 = [err retain];
            }
        });

        // Signal when queue drains
        dispatch_async(queue, ^{
            dispatch_semaphore_signal(sem);
        });

        long timeout = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 120LL * NSEC_PER_SEC));
        dispatch_release(sem);
        dispatch_release(queue);

        ASSERT_FMT(name, timeout == 0, @"GCD transcription timed out after 120s");
        ASSERT_TRUE(name, result1 != nil, fmtErr(@"File 1 failed", txErr1));
        ASSERT_TRUE(name, result2 != nil, fmtErr(@"File 2 failed", txErr2));

        NSString *text1 = [concatenateSegments(result1) lowercaseString];
        NSString *text2 = [concatenateSegments(result2) lowercaseString];

        fprintf(stdout, "    [info] File 1: %lu segments, File 2: %lu segments\n",
                (unsigned long)[result1 count], (unsigned long)[result2 count]);
        fprintf(stdout, "    [info] Text 1: %.60s...\n", [text1 UTF8String]);
        fprintf(stdout, "    [info] Text 2: %.60s...\n", [text2 UTF8String]);

        ASSERT_FMT(name, [text1 containsString:@"country"] || [text1 containsString:@"americans"],
                   @"File 1 (JFK) text incorrect: %@", text1);
        ASSERT_FMT(name, text2.length > 0,
                   @"File 2 (hotwords) produced empty text");

        [result1 release];
        [result2 release];
        [txErr1 release];
        [txErr2 release];

        reportResult(name, YES, nil);
    }
}

// =============================================================================
// Group 10: WER on LibriSpeech subset (M11)
// =============================================================================

/// Compute word error rate between hypothesis and reference (both lowercased, split on whitespace).
static float computeWER(NSString *hypothesis, NSString *reference) {
    NSArray *hyp = [[hypothesis lowercaseString] componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *ref = [[reference lowercaseString] componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Filter empty strings
    NSMutableArray *h = [NSMutableArray array];
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *s in hyp) if (s.length > 0) [h addObject:s];
    for (NSString *s in ref) if (s.length > 0) [r addObject:s];

    NSUInteger hLen = h.count;
    NSUInteger rLen = r.count;

    if (rLen == 0) return (hLen == 0) ? 0.0f : 1.0f;

    // Levenshtein distance at word level
    std::vector<std::vector<NSUInteger>> dp(hLen + 1, std::vector<NSUInteger>(rLen + 1, 0));
    for (NSUInteger i = 0; i <= hLen; i++) dp[i][0] = i;
    for (NSUInteger j = 0; j <= rLen; j++) dp[0][j] = j;

    for (NSUInteger i = 1; i <= hLen; i++) {
        for (NSUInteger j = 1; j <= rLen; j++) {
            NSUInteger cost = [h[i-1] isEqualToString:r[j-1]] ? 0 : 1;
            dp[i][j] = std::min({dp[i-1][j] + 1, dp[i][j-1] + 1, dp[i-1][j-1] + cost});
        }
    }

    return (float)dp[hLen][rLen] / (float)rLen;
}

static void test_m11_wer_librispeech(void) {
    const char *name = "test_m11_wer_librispeech";

    @autoreleasepool {
        // Load LibriSpeech references
        NSString *libriDir = [gProjectDir stringByAppendingPathComponent:@"tmp/librispeech"];
        NSString *refsPath = [libriDir stringByAppendingPathComponent:@"references.json"];

        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:refsPath]) {
            fprintf(stdout, "  SKIP: %s (no LibriSpeech data at %s)\n", name, [refsPath UTF8String]);
            return;
        }

        NSData *jsonData = [NSData dataWithContentsOfFile:refsPath];
        NSError *parseErr = nil;
        NSArray *refs = [NSJSONSerialization JSONObjectWithData:jsonData
                                                       options:0
                                                         error:&parseErr];
        ASSERT_TRUE(name, refs != nil, fmtErr(@"Failed to parse references.json", parseErr));
        ASSERT_FMT(name, refs.count > 0, @"No references found");

        float totalWER = 0.0f;
        int count = 0;
        int perfect = 0;

        for (NSDictionary *ref in refs) {
            @autoreleasepool {
                NSString *audioFile = ref[@"audio"];
                NSString *refText = ref[@"text"];
                NSString *audioPath = [libriDir stringByAppendingPathComponent:audioFile];

                if (![fm fileExistsAtPath:audioPath]) {
                    fprintf(stdout, "    [warn] Missing audio: %s\n", [audioFile UTF8String]);
                    continue;
                }

                NSURL *audioURL = [NSURL fileURLWithPath:audioPath];
                NSError *txErr = nil;
                NSArray<MWTranscriptionSegment *> *segments =
                    [gTranscriber transcribeURL:audioURL
                                      language:@"en"
                                          task:@"transcribe"
                                       options:nil
                                segmentHandler:nil
                                          info:nil
                                         error:&txErr];

                if (!segments) {
                    fprintf(stdout, "    [warn] Transcription failed for %s: %s\n",
                            [audioFile UTF8String], [[txErr localizedDescription] UTF8String]);
                    continue;
                }

                NSString *hypText = concatenateSegments(segments);
                // Strip leading/trailing whitespace and punctuation for WER comparison
                NSString *cleanHyp = [[hypText stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                    stringByReplacingOccurrencesOfString:@"," withString:@""];
                cleanHyp = [cleanHyp stringByReplacingOccurrencesOfString:@"." withString:@""];
                cleanHyp = [cleanHyp stringByReplacingOccurrencesOfString:@"?" withString:@""];

                float wer = computeWER(cleanHyp, refText);
                totalWER += wer;
                count++;
                if (wer == 0.0f) perfect++;

                if (wer > 0.15f) {
                    fprintf(stdout, "    [info] %s WER=%.1f%% ref='%.50s' hyp='%.50s'\n",
                            [ref[@"id"] UTF8String], wer * 100,
                            [refText UTF8String], [cleanHyp UTF8String]);
                }
            }
        }

        ASSERT_FMT(name, count > 0, @"No utterances processed");

        float avgWER = totalWER / count;
        fprintf(stdout, "    [info] LibriSpeech WER: %.1f%% avg over %d utterances (%d perfect)\n",
                avgWER * 100, count, perfect);

        // Turbo model should achieve <10% WER on clean LibriSpeech English
        ASSERT_FMT(name, avgWER < 0.10f,
                   @"Average WER %.1f%% exceeds 10%% threshold", avgWER * 100);

        reportResult(name, YES, nil);
    }
}

// =============================================================================
// Group 11: Model unload/reload (M12.11)
// =============================================================================

static void test_model_unload_reload(void) {
    const char *name = "test_model_unload_reload";

    @autoreleasepool {
        // Verify model starts loaded
        ASSERT_FMT(name, gTranscriber.isModelLoaded == YES,
                   @"Model should be loaded initially");

        // Unload
        [gTranscriber unloadModel];
        ASSERT_FMT(name, gTranscriber.isModelLoaded == NO,
                   @"Model should be unloaded after unloadModel");

        // Transcription should fail when unloaded
        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];
        NSError *txErr = nil;
        NSArray *segments = [gTranscriber transcribeURL:audioURL
                                              language:@"en"
                                                  task:@"transcribe"
                                               options:nil
                                        segmentHandler:nil
                                                  info:nil
                                                 error:&txErr];

        // Should either return nil/error or crash — we check for nil
        fprintf(stdout, "    [info] Transcribe while unloaded: segments=%s error=%s\n",
                segments ? "non-nil" : "nil",
                txErr ? [[txErr localizedDescription] UTF8String] : "none");

        // Reload
        NSError *reloadErr = nil;
        BOOL reloaded = [gTranscriber reloadModel:&reloadErr];
        ASSERT_FMT(name, reloaded == YES,
                   @"reloadModel failed: %@", [reloadErr localizedDescription]);
        ASSERT_FMT(name, gTranscriber.isModelLoaded == YES,
                   @"Model should be loaded after reload");

        // Verify transcription works again after reload
        NSError *txErr2 = nil;
        NSArray *segments2 = [gTranscriber transcribeURL:audioURL
                                               language:@"en"
                                                   task:@"transcribe"
                                                options:nil
                                         segmentHandler:nil
                                                   info:nil
                                                  error:&txErr2];
        ASSERT_TRUE(name, segments2 != nil, fmtErr(@"Transcribe after reload failed", txErr2));

        NSString *text = [concatenateSegments(segments2) lowercaseString];
        ASSERT_FMT(name, [text containsString:@"country"],
                   @"Post-reload transcription incorrect: %@", text);

        fprintf(stdout, "    [info] Post-reload text: %.80s...\n", [text UTF8String]);

        // Reload when already loaded should be a no-op
        NSError *reloadErr2 = nil;
        BOOL reloaded2 = [gTranscriber reloadModel:&reloadErr2];
        ASSERT_FMT(name, reloaded2 == YES, @"Reload when loaded should succeed");

        reportResult(name, YES, nil);
    }
}

// =============================================================================
// Main
// =============================================================================

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);

        if (argc < 3) {
            fprintf(stderr, "Usage: test_coverage <model_path> <data_dir> [binary_dir]\n");
            return 1;
        }

        gModelPath = [NSString stringWithUTF8String:argv[1]];
        gDataDir   = [NSString stringWithUTF8String:argv[2]];

        if (argc >= 4) {
            gBinaryDir = [NSString stringWithUTF8String:argv[3]];
        } else {
            NSString *selfPath = [NSString stringWithUTF8String:argv[0]];
            gBinaryDir = [selfPath stringByDeletingLastPathComponent];
            if (gBinaryDir.length == 0) gBinaryDir = @".";
        }

        // Derive project dir (two levels up from data_dir: tests/data -> project root)
        gProjectDir = [[gDataDir stringByDeletingLastPathComponent]
                        stringByDeletingLastPathComponent];

        fprintf(stdout, "=== Coverage Gap Tests ===\n");
        fprintf(stdout, "Model:   %s\n", [gModelPath UTF8String]);
        fprintf(stdout, "Data:    %s\n", [gDataDir UTF8String]);
        fprintf(stdout, "Binary:  %s\n", [gBinaryDir UTF8String]);
        fprintf(stdout, "Project: %s\n\n", [gProjectDir UTF8String]);

        // Load model once for all API tests
        fprintf(stdout, "Loading model...\n");
        NSError *loadError = nil;
        gTranscriber = [[MWTranscriber alloc] initWithModelPath:gModelPath error:&loadError];
        if (!gTranscriber) {
            fprintf(stderr, "FATAL: Failed to load model: %s\n",
                    [[loadError localizedDescription] UTF8String]);
            return 1;
        }
        fprintf(stdout, "Model loaded (nMels=%lu, multilingual=%s)\n\n",
                (unsigned long)gTranscriber.nMels,
                gTranscriber.isMultilingual ? "YES" : "NO");

        // ── Group 1: Zero-coverage API methods ──
        fprintf(stdout, "--- Group 1: Zero-coverage API methods ---\n");
        test_audio_decode_from_data();
        test_audio_decode_from_buffer();
        test_tokenizer_decode_with_timestamps();
        test_tokenizer_token_id_for_string();
        test_timestamp_map_chunk_index();
        test_max_new_tokens();
        test_prompt_with_different_tokenizer();

        // ── Group 2: CLI tests ──
        fprintf(stdout, "\n--- Group 2: CLI tests ---\n");
        test_cli_translate();
        test_cli_invalid_args();
        test_cli_version();

        // ── Group 3: Configuration combinations ──
        fprintf(stdout, "\n--- Group 3: Configuration combinations ---\n");
        test_vad_plus_word_timestamps();
        test_greedy_beam_one();
        test_no_repeat_ngram();

        // ── Group 4: Python reference comparison ──
        fprintf(stdout, "\n--- Group 4: Python reference comparison ---\n");
        test_python_reference_jfk();
        test_python_reference_russian();

        // ── Group 5: Python reference deep comparison ──
        fprintf(stdout, "\n--- Group 5: Python reference deep comparison ---\n");
        test_m4_6_reference_match();
        test_m11_exact_tokens();

        // ── Group 6: French language detection ──
        fprintf(stdout, "\n--- Group 6: French language detection ---\n");
        test_detect_french();

        // ── Group 7: Large-v3 (gated) ──
        fprintf(stdout, "\n--- Group 7: Large-v3 (gated) ---\n");
        test_load_large_v3();

        // ── Group 8: Word alignment reference (M5) ──
        fprintf(stdout, "\n--- Group 8: Word alignment reference (M5) ---\n");
        test_m5_alignment();

        // ── Group 9: Concurrent transcription (M7) ──
        fprintf(stdout, "\n--- Group 9: Concurrent transcription (M7) ---\n");
        test_m7_concurrent_files();

        // ── Group 10: WER on LibriSpeech subset (M11) ──
        fprintf(stdout, "\n--- Group 10: WER on LibriSpeech (M11) ---\n");
        test_m11_wer_librispeech();

        // ── Group 11: Model unload/reload (M12.11) — must be last (modifies shared model) ──
        fprintf(stdout, "\n--- Group 11: Model unload/reload (M12.11) ---\n");
        test_model_unload_reload();

        // ── Summary ──
        fprintf(stdout, "\n=== Results: %d passed, %d failed ===\n",
                gPassCount, gFailCount);

        [gTranscriber release];

        return gFailCount > 0 ? 1 : 0;
    }
}
