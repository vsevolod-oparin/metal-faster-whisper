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
// Group 5: Large-v3 model test (gated)
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
        MWModelManager *manager = [MWModelManager shared];

        // Try to resolve large-v3
        NSError *error = nil;
        NSString *modelPath = [manager resolveModel:@"large-v3"
                                           progress:nil
                                              error:&error];

        if (!modelPath) {
            fprintf(stdout, "  SKIP: %s (large-v3 not cached: %s)\n",
                    name, [[error localizedDescription] UTF8String]);
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

        // ── Group 5: Large-v3 (gated) ──
        fprintf(stdout, "\n--- Group 5: Large-v3 (gated) ---\n");
        test_load_large_v3();

        // ── Summary ──
        fprintf(stdout, "\n=== Results: %d passed, %d failed ===\n",
                gPassCount, gFailCount);

        [gTranscriber release];

        return gFailCount > 0 ? 1 : 0;
    }
}
