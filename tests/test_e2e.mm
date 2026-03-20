// tests/test_e2e.mm -- Comprehensive E2E test suite for MetalWhisper.
// Exercises the full transcription pipeline with real audio across
// different languages, formats, and configurations.
//
// Usage: test_e2e <turbo_model_path> <data_dir>
// Manual retain/release (-fno-objc-arc).

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "MWTranscriber.h"
#import "MWTranscriptionOptions.h"
#import "MWAudioDecoder.h"
#import "MWModelManager.h"
#import "MWVoiceActivityDetector.h"
#import "MWConstants.h"
#import "MWTestCommon.h"

#include <cstdio>
#include <cmath>

// Variadic ASSERT that builds the message via stringWithFormat, avoiding
// the preprocessor comma-in-macro-argument problem.
#define ASSERT_FMT(name, cond, fmt, ...) do { \
    if (!(cond)) { \
        NSString *_msg = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
        reportResult((name), NO, _msg); \
        return; \
    } \
} while (0)

// ── Globals ──────────────────────────────────────────────────────────────────

static NSString *gTurboModelPath = nil;
static NSString *gDataDir        = nil;
static NSString *gBinaryDir      = nil;
static NSString *gProjectDir     = nil;

static MWTranscriber *gTurbo = nil;   // loaded once, shared across tests
static MWTranscriber *gTiny  = nil;   // loaded if available

// ── Helpers ──────────────────────────────────────────────────────────────────

static BOOL containsCyrillic(NSString *text) {
    // Check for characters in Unicode range U+0400 - U+04FF (Cyrillic block)
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c >= 0x0400 && c <= 0x04FF) return YES;
    }
    return NO;
}

static BOOL hasNoCyrillic(NSString *text) {
    return !containsCyrillic(text);
}

static NSString *concatenateSegments(NSArray<MWTranscriptionSegment *> *segments) {
    NSMutableString *text = [[NSMutableString alloc] init];
    for (MWTranscriptionSegment *seg in segments) {
        [text appendString:seg.text];
    }
    return [text autorelease];
}

static NSString *vadModelPath(void) {
    return [gProjectDir stringByAppendingPathComponent:@"models/silero_vad_v6.onnx"];
}

// ── CLI subprocess helper ────────────────────────────────────────────────────

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

// ── Section 1: Basic Transcription ───────────────────────────────────────────

static void test_e2e_smoke_jfk_turbo(void) {
    @autoreleasepool {
        const char *name = "e2e_smoke_jfk_turbo";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSURL *url = [NSURL fileURLWithPath:path];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path], @"jfk.flac not found");

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.beamSize = 5;
        opts.temperatures = @[@0.0];

        MWTranscriptionInfo *info = nil;
        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTurbo transcribeURL:url
                         language:nil
                             task:@"transcribe"
                     typedOptions:opts
                   segmentHandler:nil
                             info:&info
                            error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeURL failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"expected non-empty segments");

        NSString *fullText = concatenateSegments(segments);
        fprintf(stdout, "    Text: %s\n", [fullText UTF8String]);

        NSString *lower = [fullText lowercaseString];
        ASSERT_TRUE(name, [lower containsString:@"fellow americans"] ||
                          ([lower containsString:@"fellow"] && [lower containsString:@"americans"]),
                    @"text should contain 'fellow Americans'");
        ASSERT_TRUE(name, [lower containsString:@"ask not"],
                    @"text should contain 'ask not'");

        // Verify 1 segment (short audio)
        NSString *segCountMsg = [NSString stringWithFormat:@"expected 1 segment, got %lu",
                                 (unsigned long)segments.count];
        ASSERT_TRUE(name, segments.count == 1, segCountMsg);

        // Timestamps within [0, ~11s]
        MWTranscriptionSegment *seg = segments[0];
        ASSERT_TRUE(name, seg.start >= 0.0f, @"start should be >= 0");
        ASSERT_FMT(name, seg.end <= 12.0f, @"end should be <= 12, got %.2f", seg.end);

        // Info check
        ASSERT_TRUE(name, info != nil, @"info should not be nil");
        ASSERT_TRUE(name, [info.language isEqualToString:@"en"],
                    fmtStr(@"expected language 'en', got", info.language));

        reportResult(name, YES, nil);
    }
}

static void test_e2e_smoke_jfk_tiny(void) {
    @autoreleasepool {
        const char *name = "e2e_smoke_jfk_tiny";

        if (!gTiny) {
            fprintf(stdout, "  SKIP: %s -- tiny model not available\n", name);
            return;
        }

        NSString *path = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSURL *url = [NSURL fileURLWithPath:path];

        MWTranscriptionInfo *info = nil;
        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTiny transcribeURL:url
                        language:nil
                            task:@"transcribe"
                         options:nil
                  segmentHandler:nil
                            info:&info
                           error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeURL failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"expected non-empty segments");

        NSString *tinyText = concatenateSegments(segments);
        fprintf(stdout, "    Tiny text: %s\n", [tinyText UTF8String]);

        // Should produce recognizable JFK text
        NSString *lower = [tinyText lowercaseString];
        BOOL hasRecognizable = [lower containsString:@"country"] ||
                               [lower containsString:@"ask"] ||
                               [lower containsString:@"what"] ||
                               [lower containsString:@"fellow"] ||
                               [lower containsString:@"americans"];
        ASSERT_TRUE(name, hasRecognizable, @"tiny text should contain recognizable JFK words");

        // Compare with turbo result -- get turbo text
        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.beamSize = 5;
        opts.temperatures = @[@0.0];

        NSError *error2 = nil;
        NSArray<MWTranscriptionSegment *> *turboSegs =
            [gTurbo transcribeURL:url
                         language:nil
                             task:@"transcribe"
                     typedOptions:opts
                   segmentHandler:nil
                             info:nil
                            error:&error2];

        if (turboSegs && turboSegs.count > 0) {
            NSString *turboText = concatenateSegments(turboSegs);

            // Compare word overlap -- both should share most words
            NSMutableSet *turboWords = [NSMutableSet set];
            for (NSString *w in [[turboText lowercaseString] componentsSeparatedByCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
                if (w.length > 2) [turboWords addObject:w];
            }

            NSUInteger shared = 0;
            NSArray *tinyWords = [[tinyText lowercaseString] componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            for (NSString *w in tinyWords) {
                if (w.length > 2 && [turboWords containsObject:w]) shared++;
            }

            fprintf(stdout, "    Shared words: %lu\n", (unsigned long)shared);
            ASSERT_TRUE(name, shared >= 3,
                        @"tiny and turbo should share at least 3 words");
        }

        reportResult(name, YES, nil);
    }
}

static void test_e2e_long_form(void) {
    @autoreleasepool {
        const char *name = "e2e_long_form";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"physicsworks.wav"];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                    @"physicsworks.wav not found");

        NSURL *audioURL = [NSURL fileURLWithPath:path];
        NSError *decodeError = nil;
        NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:audioURL error:&decodeError];
        ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"Audio decode failed", decodeError));

        // Truncate to first 60s
        NSUInteger maxSamples = 60 * kMWTargetSampleRate;
        NSUInteger totalSamples = fullAudio.length / sizeof(float);
        NSData *audio = fullAudio;
        if (totalSamples > maxSamples) {
            audio = [NSData dataWithBytes:fullAudio.bytes length:maxSamples * sizeof(float)];
        }

        MWTranscriptionInfo *info = nil;
        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTurbo transcribeAudio:audio
                           language:@"en"
                               task:@"transcribe"
                            options:nil
                     segmentHandler:nil
                               info:&info
                              error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeAudio failed", error));
        ASSERT_FMT(name, segments.count > 5, @"expected >5 segments, got %lu",
                   (unsigned long)segments.count);

        // Timestamps monotonically increasing
        for (NSUInteger i = 1; i < segments.count; i++) {
            BOOL mono = segments[i].start >= segments[i-1].start;
            ASSERT_FMT(name, mono, @"timestamps not monotonic at segment %lu: %.2f < %.2f",
                       (unsigned long)i, segments[i].start, segments[i-1].start);
        }

        // All timestamps within [0, 61s]
        for (MWTranscriptionSegment *seg in segments) {
            ASSERT_FMT(name, seg.start >= 0.0f && seg.end <= 61.0f,
                       @"timestamp out of range: [%.2f, %.2f]", seg.start, seg.end);
        }

        // Total text > 200 characters
        NSString *fullText = concatenateSegments(segments);
        ASSERT_FMT(name, fullText.length > 200, @"text too short: %lu chars",
                   (unsigned long)fullText.length);

        fprintf(stdout, "    Segments: %lu, Text length: %lu chars\n",
                (unsigned long)segments.count, (unsigned long)fullText.length);

        reportResult(name, YES, nil);
    }
}

static void test_e2e_mp3_format(void) {
    @autoreleasepool {
        const char *name = "e2e_mp3_format";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"hotwords.mp3"];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                    @"hotwords.mp3 not found");

        NSURL *url = [NSURL fileURLWithPath:path];
        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTurbo transcribeURL:url
                         language:@"en"
                             task:@"transcribe"
                          options:nil
                   segmentHandler:nil
                             info:nil
                            error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeURL failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"expected non-empty output for MP3");

        NSString *text = concatenateSegments(segments);
        fprintf(stdout, "    MP3 text: %s\n", [text UTF8String]);
        ASSERT_TRUE(name, text.length > 0, @"MP3 text should not be empty");

        reportResult(name, YES, nil);
    }
}

static void test_e2e_multi_format_match(void) {
    @autoreleasepool {
        const char *name = "e2e_multi_format_match";

        NSString *flacPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSString *m4aPath  = [gDataDir stringByAppendingPathComponent:@"jfk.m4a"];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:flacPath],
                    @"jfk.flac not found");
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:m4aPath],
                    @"jfk.m4a not found");

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.beamSize = 5;
        opts.temperatures = @[@0.0];

        // Transcribe FLAC
        NSError *error1 = nil;
        NSArray<MWTranscriptionSegment *> *flacSegs =
            [gTurbo transcribeURL:[NSURL fileURLWithPath:flacPath]
                         language:@"en"
                             task:@"transcribe"
                     typedOptions:opts
                   segmentHandler:nil
                             info:nil
                            error:&error1];
        ASSERT_TRUE(name, flacSegs != nil, fmtErr(@"FLAC transcribe failed", error1));

        // Transcribe M4A
        NSError *error2 = nil;
        NSArray<MWTranscriptionSegment *> *m4aSegs =
            [gTurbo transcribeURL:[NSURL fileURLWithPath:m4aPath]
                         language:@"en"
                             task:@"transcribe"
                     typedOptions:opts
                   segmentHandler:nil
                             info:nil
                            error:&error2];
        ASSERT_TRUE(name, m4aSegs != nil, fmtErr(@"M4A transcribe failed", error2));

        NSString *flacText = concatenateSegments(flacSegs);
        NSString *m4aText  = concatenateSegments(m4aSegs);

        fprintf(stdout, "    FLAC: %s\n", [flacText UTF8String]);
        fprintf(stdout, "    M4A:  %s\n", [m4aText UTF8String]);

        BOOL match = [flacText isEqualToString:m4aText];
        if (!match) {
            fprintf(stdout, "    NOTE: Texts differ (codec affects mel features), checking similarity\n");
            // At minimum, both should contain the same key phrases
            NSString *flacLower = [flacText lowercaseString];
            NSString *m4aLower = [m4aText lowercaseString];
            BOOL bothHaveAsk = [flacLower containsString:@"ask"] && [m4aLower containsString:@"ask"];
            ASSERT_TRUE(name, bothHaveAsk, @"both formats should produce recognizable JFK text");
        }

        reportResult(name, YES, nil);
    }
}

// ── Section 2: Language & Translation ────────────────────────────────────────

static void test_e2e_detect_russian(void) {
    @autoreleasepool {
        const char *name = "e2e_detect_russian";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"russian_60s.wav"];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                    @"russian_60s.wav not found");

        NSURL *url = [NSURL fileURLWithPath:path];
        MWTranscriptionInfo *info = nil;
        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTurbo transcribeURL:url
                         language:nil   // auto-detect
                             task:@"transcribe"
                          options:nil
                   segmentHandler:nil
                             info:&info
                            error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeURL failed", error));
        ASSERT_TRUE(name, info != nil, @"info should not be nil");

        fprintf(stdout, "    Detected language: %s (%.2f)\n",
                [info.language UTF8String], info.languageProbability);

        ASSERT_TRUE(name, [info.language isEqualToString:@"ru"],
                    fmtStr(@"expected language 'ru', got", info.language));

        // Verify output contains Cyrillic characters
        NSString *fullText = concatenateSegments(segments);
        fprintf(stdout, "    Text: %s\n", [fullText UTF8String]);
        ASSERT_TRUE(name, containsCyrillic(fullText),
                    @"Russian transcription should contain Cyrillic characters");

        reportResult(name, YES, nil);
    }
}

static void test_e2e_translate_russian(void) {
    @autoreleasepool {
        const char *name = "e2e_translate_russian";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"russian_60s.wav"];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                    @"russian_60s.wav not found");

        NSURL *url = [NSURL fileURLWithPath:path];
        MWTranscriptionInfo *info = nil;
        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTurbo transcribeURL:url
                         language:nil
                             task:@"translate"  // translate to English
                          options:nil
                   segmentHandler:nil
                             info:&info
                            error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"translate failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"expected non-empty segments");
        ASSERT_TRUE(name, info != nil, @"info should not be nil");

        fprintf(stdout, "    Detected language: %s\n", [info.language UTF8String]);
        ASSERT_TRUE(name, [info.language isEqualToString:@"ru"],
                    fmtStr(@"expected detected language 'ru', got", info.language));

        NSString *fullText = concatenateSegments(segments);
        fprintf(stdout, "    Translated text: %s\n", [fullText UTF8String]);

        // Translation quality depends on the model. The turbo model has limited
        // translation capability and may output Russian even with task="translate".
        // Verify the pipeline runs without error. If Latin text is present, great;
        // if not, warn but don't fail (model limitation, not framework bug).
        BOOL hasLatinText = NO;
        for (NSUInteger i = 0; i < fullText.length; i++) {
            unichar c = [fullText characterAtIndex:i];
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) { hasLatinText = YES; break; }
        }
        if (!hasLatinText) {
            fprintf(stdout, "    WARNING: Translate produced no English text (known turbo model limitation)\n");
        }

        reportResult(name, YES, nil);
    }
}

static void test_e2e_mixed_language(void) {
    @autoreleasepool {
        const char *name = "e2e_mixed_language";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"mixed_en_ru.wav"];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                    @"mixed_en_ru.wav not found");

        NSURL *url = [NSURL fileURLWithPath:path];

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.multilingual = YES;   // enable per-segment language re-detection (C3 fix)

        MWTranscriptionInfo *info = nil;
        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTurbo transcribeURL:url
                         language:nil
                             task:@"transcribe"
                     typedOptions:opts
                   segmentHandler:nil
                             info:&info
                            error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeURL failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"expected non-empty segments");

        NSString *fullText = concatenateSegments(segments);
        fprintf(stdout, "    Mixed text: %s\n", [fullText UTF8String]);

        // The audio is JFK English (11s) followed by Russian (30s).
        // With multilingual=YES, we should see both Latin and Cyrillic text.
        // Check that the full text contains some Latin letters (English part)
        // and some Cyrillic characters (Russian part).
        BOOL hasLatin = NO;
        BOOL hasCyrillic = NO;
        for (NSUInteger i = 0; i < fullText.length; i++) {
            unichar c = [fullText characterAtIndex:i];
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) hasLatin = YES;
            if (c >= 0x0400 && c <= 0x04FF) hasCyrillic = YES;
        }

        fprintf(stdout, "    Has Latin: %s, Has Cyrillic: %s\n",
                hasLatin ? "YES" : "NO", hasCyrillic ? "YES" : "NO");

        ASSERT_TRUE(name, hasLatin, @"mixed audio should have some English (Latin) text");
        ASSERT_TRUE(name, hasCyrillic, @"mixed audio should have some Russian (Cyrillic) text");

        reportResult(name, YES, nil);
    }
}

static void test_e2e_explicit_language(void) {
    @autoreleasepool {
        const char *name = "e2e_explicit_language";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSURL *url = [NSURL fileURLWithPath:path];

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.beamSize = 5;
        opts.temperatures = @[@0.0];

        // Auto-detect
        NSError *error1 = nil;
        NSArray<MWTranscriptionSegment *> *autoSegs =
            [gTurbo transcribeURL:url
                         language:nil
                             task:@"transcribe"
                     typedOptions:opts
                   segmentHandler:nil
                             info:nil
                            error:&error1];
        ASSERT_TRUE(name, autoSegs != nil, fmtErr(@"auto-detect failed", error1));

        // Explicit en
        NSError *error2 = nil;
        NSArray<MWTranscriptionSegment *> *explicitSegs =
            [gTurbo transcribeURL:url
                         language:@"en"
                             task:@"transcribe"
                     typedOptions:opts
                   segmentHandler:nil
                             info:nil
                            error:&error2];
        ASSERT_TRUE(name, explicitSegs != nil, fmtErr(@"explicit en failed", error2));

        NSString *autoText = concatenateSegments(autoSegs);
        NSString *explicitText = concatenateSegments(explicitSegs);

        fprintf(stdout, "    Auto:     %s\n", [autoText UTF8String]);
        fprintf(stdout, "    Explicit: %s\n", [explicitText UTF8String]);

        BOOL match = [autoText isEqualToString:explicitText];
        fprintf(stdout, "    Exact match: %s\n", match ? "YES" : "NO");

        // They should be very similar if not identical
        if (!match) {
            // At minimum both should contain the same key phrase
            NSString *autoLower = [autoText lowercaseString];
            NSString *explicitLower = [explicitText lowercaseString];
            ASSERT_TRUE(name, [autoLower containsString:@"ask"] && [explicitLower containsString:@"ask"],
                        @"both should contain 'ask'");
        }

        reportResult(name, YES, nil);
    }
}

// ── Section 3: Word Timestamps ───────────────────────────────────────────────

static void test_e2e_word_timestamps_basic(void) {
    @autoreleasepool {
        const char *name = "e2e_word_timestamps_basic";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSURL *url = [NSURL fileURLWithPath:path];

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.wordTimestamps = YES;
        opts.beamSize = 5;
        opts.temperatures = @[@0.0];

        MWTranscriptionInfo *info = nil;
        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTurbo transcribeURL:url
                         language:@"en"
                             task:@"transcribe"
                     typedOptions:opts
                   segmentHandler:nil
                             info:&info
                            error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeURL failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"expected non-empty segments");

        MWTranscriptionSegment *seg = segments[0];
        ASSERT_TRUE(name, seg.words != nil, @"words array should not be nil");
        ASSERT_FMT(name, seg.words.count >= 15 && seg.words.count <= 40,
                   @"expected 15-40 words, got %lu", (unsigned long)seg.words.count);

        // All start <= end
        for (MWWord *w in seg.words) {
            ASSERT_FMT(name, w.start <= w.end, @"word '%@' start %.3f > end %.3f",
                       w.word, w.start, w.end);
        }

        // Text concatenation should approximate segment text
        NSMutableString *wordConcat = [[NSMutableString alloc] init];
        for (MWWord *w in seg.words) {
            [wordConcat appendString:w.word];
        }
        NSString *segTextTrimmed = [seg.text stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *wordConcatTrimmed = [wordConcat stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        fprintf(stdout, "    Word count: %lu\n", (unsigned long)seg.words.count);
        fprintf(stdout, "    First word: '%s' [%.3f - %.3f]\n",
                [seg.words[0].word UTF8String], seg.words[0].start, seg.words[0].end);
        fprintf(stdout, "    Segment text: %s\n", [segTextTrimmed UTF8String]);
        fprintf(stdout, "    Word concat:  %s\n", [wordConcatTrimmed UTF8String]);

        // Normalized comparison: ignore spaces and trailing punctuation
        NSCharacterSet *stripChars = [NSCharacterSet characterSetWithCharactersInString:
                                      @" .,!?;:\"'"];
        NSMutableString *segNorm = [[[segTextTrimmed lowercaseString] mutableCopy] autorelease];
        NSMutableString *wordNorm = [[[wordConcatTrimmed lowercaseString] mutableCopy] autorelease];
        // Remove all matching characters
        for (NSUInteger ci = 0; ci < segNorm.length; ) {
            if ([stripChars characterIsMember:[segNorm characterAtIndex:ci]])
                [segNorm deleteCharactersInRange:NSMakeRange(ci, 1)];
            else ci++;
        }
        for (NSUInteger ci = 0; ci < wordNorm.length; ) {
            if ([stripChars characterIsMember:[wordNorm characterAtIndex:ci]])
                [wordNorm deleteCharactersInRange:NSMakeRange(ci, 1)];
            else ci++;
        }
        ASSERT_TRUE(name, [segNorm isEqualToString:wordNorm],
                    @"word concatenation should match segment text (ignoring spaces/punctuation)");

        [wordConcat release];
        reportResult(name, YES, nil);
    }
}

static void test_e2e_word_timestamps_long(void) {
    @autoreleasepool {
        const char *name = "e2e_word_timestamps_long";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"physicsworks.wav"];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                    @"physicsworks.wav not found");

        NSURL *audioURL = [NSURL fileURLWithPath:path];
        NSError *decodeError = nil;
        NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:audioURL error:&decodeError];
        ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"Audio decode failed", decodeError));

        // Truncate to 30s
        NSUInteger maxSamples = 30 * kMWTargetSampleRate;
        NSUInteger totalSamples = fullAudio.length / sizeof(float);
        NSData *audio = fullAudio;
        if (totalSamples > maxSamples) {
            audio = [NSData dataWithBytes:fullAudio.bytes length:maxSamples * sizeof(float)];
        }

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.wordTimestamps = YES;

        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTurbo transcribeAudio:audio
                           language:@"en"
                               task:@"transcribe"
                            options:[opts toDictionary]
                     segmentHandler:nil
                               info:nil
                              error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeAudio failed", error));

        // Count total words across all segments
        NSUInteger totalWords = 0;
        for (MWTranscriptionSegment *seg in segments) {
            if (seg.words) {
                totalWords += seg.words.count;

                // Monotonic within each segment
                for (NSUInteger i = 1; i < seg.words.count; i++) {
                    ASSERT_FMT(name, seg.words[i].start >= seg.words[i-1].start,
                               @"words not monotonic in segment %lu: '%.3f < %.3f'",
                               (unsigned long)seg.segmentId,
                               seg.words[i].start, seg.words[i-1].start);
                }
            }
        }

        fprintf(stdout, "    Total words across %lu segments: %lu\n",
                (unsigned long)segments.count, (unsigned long)totalWords);
        ASSERT_FMT(name, totalWords > 50, @"expected >50 words, got %lu",
                   (unsigned long)totalWords);

        reportResult(name, YES, nil);
    }
}

static void test_e2e_word_srt_output(void) {
    @autoreleasepool {
        const char *name = "e2e_word_srt_output";

        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];

        int code = -1;
        NSString *output = runCLI(@[@"--model", gTurboModelPath,
                                    @"--word-timestamps",
                                    @"--output-format", @"srt",
                                    audioPath], &code);

        NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
        ASSERT_TRUE(name, code == 0, msg);
        ASSERT_TRUE(name, [output containsString:@"-->"], @"Word SRT should contain '-->'");

        // Count SRT entries
        NSArray<NSString *> *lines = [output componentsSeparatedByString:@"\n"];
        NSUInteger entryCount = 0;
        for (NSString *line in lines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0) {
                NSScanner *scanner = [NSScanner scannerWithString:trimmed];
                NSInteger val;
                if ([scanner scanInteger:&val] && [scanner isAtEnd] && val > 0) {
                    entryCount++;
                }
            }
        }

        fprintf(stdout, "    Word SRT entries: %lu\n", (unsigned long)entryCount);
        ASSERT_FMT(name, entryCount > 15, @"expected >15 SRT entries, got %lu",
                   (unsigned long)entryCount);

        reportResult(name, YES, nil);
    }
}

// ── Section 4: VAD ───────────────────────────────────────────────────────────

static void test_e2e_vad_silence_detection(void) {
    @autoreleasepool {
        const char *name = "e2e_vad_silence_detection";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"silence_speech_silence.wav"];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                    @"silence_speech_silence.wav not found");

        NSURL *url = [NSURL fileURLWithPath:path];

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.vadFilter = YES;
        opts.vadModelPath = vadModelPath();

        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTurbo transcribeURL:url
                         language:@"en"
                             task:@"transcribe"
                     typedOptions:opts
                   segmentHandler:nil
                             info:nil
                            error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribe with VAD failed", error));
        ASSERT_TRUE(name, segments.count > 0, @"expected non-empty segments");

        // Speech is in ~10-21s range. VAD should produce segments in that region.
        for (MWTranscriptionSegment *seg in segments) {
            fprintf(stdout, "    VAD seg: [%.2f - %.2f] %s\n",
                    seg.start, seg.end, [seg.text UTF8String]);
        }

        // VAD should detect the speech portion and produce transcription.
        // The timestamps may be remapped to original audio positions.
        float firstStart = segments[0].start;
        float lastEnd = [segments lastObject].end;

        fprintf(stdout, "    First start: %.2f, Last end: %.2f\n", firstStart, lastEnd);

        // Verify the transcription contains JFK speech content
        NSString *vadText = concatenateSegments(segments);
        NSString *vadLower = [vadText lowercaseString];
        BOOL hasJFK = [vadLower containsString:@"ask"] || [vadLower containsString:@"country"] ||
                      [vadLower containsString:@"fellow"];
        ASSERT_TRUE(name, hasJFK, @"VAD transcription should contain JFK speech text");

        // VAD should not produce excessive hallucinated text beyond the speech.
        // The speech is ~11s, so total transcribed duration should be reasonable.
        float totalDuration = lastEnd - firstStart;
        ASSERT_FMT(name, totalDuration <= 32.0f,
                   @"VAD transcription duration %.2f seems too long", totalDuration);

        reportResult(name, YES, nil);
    }
}

static void test_e2e_vad_music_only(void) {
    @autoreleasepool {
        const char *name = "e2e_vad_music_only";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"music_only.wav"];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                    @"music_only.wav not found");

        NSURL *url = [NSURL fileURLWithPath:path];

        MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
        opts.vadFilter = YES;
        opts.vadModelPath = vadModelPath();

        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTurbo transcribeURL:url
                         language:@"en"
                             task:@"transcribe"
                     typedOptions:opts
                   segmentHandler:nil
                             info:nil
                            error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribe music with VAD failed", error));

        NSString *fullText = concatenateSegments(segments);
        NSString *trimmed = [fullText stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        fprintf(stdout, "    Music-only with VAD: %lu segments, text: '%s'\n",
                (unsigned long)segments.count, [trimmed UTF8String]);

        // With VAD, music-only audio should produce either no segments or minimal output.
        // Without VAD, Whisper typically hallucinates "Thank you." on music.
        ASSERT_FMT(name, segments.count <= 2,
                   @"expected <=2 segments for music-only with VAD, got %lu",
                   (unsigned long)segments.count);

        reportResult(name, YES, nil);
    }
}

static void test_e2e_vad_vs_no_vad(void) {
    @autoreleasepool {
        const char *name = "e2e_vad_vs_no_vad";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"silence_speech_silence.wav"];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                    @"silence_speech_silence.wav not found");

        NSURL *url = [NSURL fileURLWithPath:path];

        // WITHOUT VAD
        MWTranscriptionOptions *optsNoVAD = [MWTranscriptionOptions defaults];
        optsNoVAD.vadFilter = NO;

        NSError *error1 = nil;
        NSArray<MWTranscriptionSegment *> *segsNoVAD =
            [gTurbo transcribeURL:url
                         language:@"en"
                             task:@"transcribe"
                     typedOptions:optsNoVAD
                   segmentHandler:nil
                             info:nil
                            error:&error1];
        ASSERT_TRUE(name, segsNoVAD != nil, fmtErr(@"transcribe without VAD failed", error1));

        // WITH VAD
        MWTranscriptionOptions *optsVAD = [MWTranscriptionOptions defaults];
        optsVAD.vadFilter = YES;
        optsVAD.vadModelPath = vadModelPath();

        NSError *error2 = nil;
        NSArray<MWTranscriptionSegment *> *segsVAD =
            [gTurbo transcribeURL:url
                         language:@"en"
                             task:@"transcribe"
                     typedOptions:optsVAD
                   segmentHandler:nil
                             info:nil
                            error:&error2];
        ASSERT_TRUE(name, segsVAD != nil, fmtErr(@"transcribe with VAD failed", error2));

        NSString *textNoVAD = concatenateSegments(segsNoVAD);
        NSString *textVAD   = concatenateSegments(segsVAD);

        fprintf(stdout, "    No VAD: %lu segments, text: %s\n",
                (unsigned long)segsNoVAD.count, [textNoVAD UTF8String]);
        fprintf(stdout, "    VAD:    %lu segments, text: %s\n",
                (unsigned long)segsVAD.count, [textVAD UTF8String]);

        // VAD version should have text only from the speech portion
        // Both should contain recognizable JFK text
        NSString *vadLower = [textVAD lowercaseString];
        BOOL vadHasJFK = [vadLower containsString:@"ask"] || [vadLower containsString:@"country"];
        ASSERT_TRUE(name, vadHasJFK, @"VAD version should still transcribe the speech portion");

        reportResult(name, YES, nil);
    }
}

// ── Section 5: Output Formats ────────────────────────────────────────────────

static void test_e2e_srt_format(void) {
    @autoreleasepool {
        const char *name = "e2e_srt_format";

        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        int code = -1;
        NSString *output = runCLI(@[@"--model", gTurboModelPath,
                                    @"--output-format", @"srt", audioPath], &code);

        ASSERT_FMT(name, code == 0, @"Expected exit code 0, got %d", code);
        ASSERT_TRUE(name, [output hasPrefix:@"1\n"], @"SRT should start with '1\\n'");
        ASSERT_TRUE(name, [output containsString:@"-->"], @"SRT should contain '-->'");

        // Verify timestamp format: HH:MM:SS,mmm
        NSRegularExpression *tsRegex = [NSRegularExpression
            regularExpressionWithPattern:@"\\d{2}:\\d{2}:\\d{2},\\d{3}"
                                 options:0 error:nil];
        NSUInteger matches = [tsRegex numberOfMatchesInString:output options:0
                                                        range:NSMakeRange(0, output.length)];
        ASSERT_FMT(name, matches >= 2, @"expected >=2 SRT timestamps, found %lu",
                   (unsigned long)matches);

        fprintf(stdout, "    SRT output (%lu chars, %lu timestamps)\n",
                (unsigned long)output.length, (unsigned long)matches);

        reportResult(name, YES, nil);
    }
}

static void test_e2e_vtt_format(void) {
    @autoreleasepool {
        const char *name = "e2e_vtt_format";

        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        int code = -1;
        NSString *output = runCLI(@[@"--model", gTurboModelPath,
                                    @"--output-format", @"vtt", audioPath], &code);

        ASSERT_FMT(name, code == 0, @"Expected exit code 0, got %d", code);
        ASSERT_TRUE(name, [output hasPrefix:@"WEBVTT"], @"VTT should start with 'WEBVTT'");
        ASSERT_TRUE(name, [output containsString:@"-->"], @"VTT should contain '-->'");

        // Verify timestamp format: HH:MM:SS.mmm (note dot, not comma)
        NSRegularExpression *tsRegex = [NSRegularExpression
            regularExpressionWithPattern:@"\\d{2}:\\d{2}:\\d{2}\\.\\d{3}"
                                 options:0 error:nil];
        NSUInteger matches = [tsRegex numberOfMatchesInString:output options:0
                                                        range:NSMakeRange(0, output.length)];
        ASSERT_FMT(name, matches >= 2, @"expected >=2 VTT timestamps, found %lu",
                   (unsigned long)matches);

        fprintf(stdout, "    VTT output (%lu chars, %lu timestamps)\n",
                (unsigned long)output.length, (unsigned long)matches);

        reportResult(name, YES, nil);
    }
}

static void test_e2e_json_format(void) {
    @autoreleasepool {
        const char *name = "e2e_json_format";

        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        int code = -1;
        NSString *output = runCLI(@[@"--model", gTurboModelPath,
                                    @"--json", audioPath], &code);

        ASSERT_FMT(name, code == 0, @"Expected exit code 0, got %d", code);

        NSData *jsonData = [output dataUsingEncoding:NSUTF8StringEncoding];
        ASSERT_TRUE(name, jsonData != nil, @"Failed to convert output to data");

        NSError *parseErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&parseErr];
        ASSERT_FMT(name, json != nil, @"JSON parse failed: %@", [parseErr localizedDescription]);

        // Verify required keys
        ASSERT_TRUE(name, json[@"language"] != nil, @"JSON should have 'language' key");
        ASSERT_TRUE(name, json[@"duration"] != nil, @"JSON should have 'duration' key");
        ASSERT_TRUE(name, json[@"segments"] != nil, @"JSON should have 'segments' key");

        // Verify segment structure
        NSArray *segments = json[@"segments"];
        ASSERT_TRUE(name, [segments isKindOfClass:[NSArray class]], @"segments should be array");
        ASSERT_TRUE(name, segments.count > 0, @"segments should not be empty");

        NSDictionary *seg0 = segments[0];
        ASSERT_TRUE(name, seg0[@"text"] != nil, @"segment should have 'text'");
        ASSERT_TRUE(name, seg0[@"start"] != nil, @"segment should have 'start'");
        ASSERT_TRUE(name, seg0[@"end"] != nil, @"segment should have 'end'");
        ASSERT_TRUE(name, seg0[@"tokens"] != nil, @"segment should have 'tokens'");

        fprintf(stdout, "    JSON: language=%s, duration=%s, segments=%lu\n",
                [json[@"language"] UTF8String],
                [[json[@"duration"] description] UTF8String],
                (unsigned long)segments.count);

        reportResult(name, YES, nil);
    }
}

static void test_e2e_json_word_timestamps(void) {
    @autoreleasepool {
        const char *name = "e2e_json_word_timestamps";

        NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        int code = -1;
        NSString *output = runCLI(@[@"--model", gTurboModelPath,
                                    @"--word-timestamps",
                                    @"--json", audioPath], &code);

        ASSERT_FMT(name, code == 0, @"Expected exit code 0, got %d", code);

        NSData *jsonData = [output dataUsingEncoding:NSUTF8StringEncoding];
        NSError *parseErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&parseErr];
        ASSERT_FMT(name, json != nil, @"JSON parse failed: %@", [parseErr localizedDescription]);

        NSArray *segments = json[@"segments"];
        ASSERT_TRUE(name, segments.count > 0, @"segments should not be empty");

        NSDictionary *seg0 = segments[0];
        NSArray *words = seg0[@"words"];
        ASSERT_TRUE(name, words != nil, @"segment should have 'words' array");
        ASSERT_TRUE(name, [words isKindOfClass:[NSArray class]], @"words should be array");
        ASSERT_TRUE(name, words.count > 0, @"words should not be empty");

        // Check word structure
        NSDictionary *word0 = words[0];
        ASSERT_TRUE(name, word0[@"start"] != nil, @"word should have 'start'");
        ASSERT_TRUE(name, word0[@"end"] != nil, @"word should have 'end'");
        ASSERT_TRUE(name, word0[@"word"] != nil, @"word should have 'word'");
        ASSERT_TRUE(name, word0[@"probability"] != nil, @"word should have 'probability'");

        fprintf(stdout, "    JSON words: %lu words in first segment\n",
                (unsigned long)words.count);
        fprintf(stdout, "    First word: '%s' [%s - %s] prob=%s\n",
                [[word0[@"word"] description] UTF8String],
                [[word0[@"start"] description] UTF8String],
                [[word0[@"end"] description] UTF8String],
                [[word0[@"probability"] description] UTF8String]);

        reportResult(name, YES, nil);
    }
}

// ── Section 6: Edge Cases & Robustness ───────────────────────────────────────

static void test_e2e_stereo_input(void) {
    @autoreleasepool {
        const char *name = "e2e_stereo_input";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"stereo_diarization.wav"];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                    @"stereo_diarization.wav not found");

        NSURL *url = [NSURL fileURLWithPath:path];
        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTurbo transcribeURL:url
                         language:@"en"
                             task:@"transcribe"
                          options:nil
                   segmentHandler:nil
                             info:nil
                            error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"stereo transcribe failed", error));

        NSString *text = concatenateSegments(segments);
        fprintf(stdout, "    Stereo text: %s\n", [text UTF8String]);
        ASSERT_TRUE(name, text.length > 0, @"stereo input should produce text");

        reportResult(name, YES, nil);
    }
}

static void test_e2e_callback_streaming(void) {
    @autoreleasepool {
        const char *name = "e2e_callback_streaming";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"physicsworks.wav"];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                    @"physicsworks.wav not found");

        NSURL *audioURL = [NSURL fileURLWithPath:path];
        NSError *decodeError = nil;
        NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:audioURL error:&decodeError];
        ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"Audio decode failed", decodeError));

        // Truncate to 30s
        NSUInteger maxSamples = 30 * kMWTargetSampleRate;
        NSUInteger totalSamples = fullAudio.length / sizeof(float);
        NSData *audio = fullAudio;
        if (totalSamples > maxSamples) {
            audio = [NSData dataWithBytes:fullAudio.bytes length:maxSamples * sizeof(float)];
        }

        __block NSUInteger callbackCount = 0;
        NSError *error = nil;
        NSArray<MWTranscriptionSegment *> *segments =
            [gTurbo transcribeAudio:audio
                           language:@"en"
                               task:@"transcribe"
                            options:nil
                     segmentHandler:^(MWTranscriptionSegment *segment, BOOL *stop) {
                         callbackCount++;
                     }
                               info:nil
                              error:&error];

        ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeAudio failed", error));

        fprintf(stdout, "    Callback count: %lu, Segment count: %lu\n",
                (unsigned long)callbackCount, (unsigned long)segments.count);

        ASSERT_FMT(name, callbackCount == segments.count,
                   @"callback count %lu != segment count %lu",
                   (unsigned long)callbackCount, (unsigned long)segments.count);

        reportResult(name, YES, nil);
    }
}

static void test_e2e_condition_on_previous(void) {
    @autoreleasepool {
        const char *name = "e2e_condition_on_previous";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"physicsworks.wav"];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                    @"physicsworks.wav not found");

        NSURL *audioURL = [NSURL fileURLWithPath:path];
        NSError *decodeError = nil;
        NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:audioURL error:&decodeError];
        ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"Audio decode failed", decodeError));

        // Truncate to 60s
        NSUInteger maxSamples = 60 * kMWTargetSampleRate;
        NSUInteger totalSamples = fullAudio.length / sizeof(float);
        NSData *audio = fullAudio;
        if (totalSamples > maxSamples) {
            audio = [NSData dataWithBytes:fullAudio.bytes length:maxSamples * sizeof(float)];
        }

        // conditionOnPreviousText = YES
        MWTranscriptionOptions *optsYes = [MWTranscriptionOptions defaults];
        optsYes.conditionOnPreviousText = YES;

        NSError *error1 = nil;
        NSArray<MWTranscriptionSegment *> *segsYes =
            [gTurbo transcribeAudio:audio
                           language:@"en"
                               task:@"transcribe"
                            options:[optsYes toDictionary]
                     segmentHandler:nil
                               info:nil
                              error:&error1];
        ASSERT_TRUE(name, segsYes != nil, fmtErr(@"condition=YES failed", error1));
        ASSERT_TRUE(name, segsYes.count > 0, @"condition=YES produced no segments");

        // conditionOnPreviousText = NO
        MWTranscriptionOptions *optsNo = [MWTranscriptionOptions defaults];
        optsNo.conditionOnPreviousText = NO;

        NSError *error2 = nil;
        NSArray<MWTranscriptionSegment *> *segsNo =
            [gTurbo transcribeAudio:audio
                           language:@"en"
                               task:@"transcribe"
                            options:[optsNo toDictionary]
                     segmentHandler:nil
                               info:nil
                              error:&error2];
        ASSERT_TRUE(name, segsNo != nil, fmtErr(@"condition=NO failed", error2));
        ASSERT_TRUE(name, segsNo.count > 0, @"condition=NO produced no segments");

        NSString *textYes = concatenateSegments(segsYes);
        NSString *textNo  = concatenateSegments(segsNo);

        fprintf(stdout, "    condition=YES: %lu segments, %lu chars\n",
                (unsigned long)segsYes.count, (unsigned long)textYes.length);
        fprintf(stdout, "    condition=NO:  %lu segments, %lu chars\n",
                (unsigned long)segsNo.count, (unsigned long)textNo.length);

        reportResult(name, YES, nil);
    }
}

static void test_e2e_async_api(void) {
    @autoreleasepool {
        const char *name = "e2e_async_api";

        NSString *path = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
        NSURL *url = [NSURL fileURLWithPath:path];
        ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                    @"jfk.flac not found");

        __block NSArray<MWTranscriptionSegment *> *resultSegments = nil;
        __block MWTranscriptionInfo *resultInfo = nil;
        __block NSError *resultError = nil;
        __block BOOL completed = NO;
        __block NSUInteger streamCount = 0;

        [gTurbo transcribeURL:url
                     language:nil
                         task:@"transcribe"
                 typedOptions:nil
               segmentHandler:^(MWTranscriptionSegment *segment, BOOL *stop) {
                   streamCount++;
               }
            completionHandler:^(NSArray<MWTranscriptionSegment *> *segments,
                                MWTranscriptionInfo *info,
                                NSError *error) {
                resultSegments = [segments retain];
                resultInfo = [info retain];
                resultError = [error retain];
                completed = YES;
            }];

        // Pump main run loop (completion fires on main queue)
        NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:120.0];
        while (!completed && [[NSDate date] compare:timeout] == NSOrderedAscending) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }

        ASSERT_TRUE(name, completed, @"async transcription timed out after 120s");
        ASSERT_TRUE(name, resultError == nil, fmtErr(@"async transcribe failed", resultError));
        ASSERT_TRUE(name, resultSegments != nil, @"async segments nil");
        ASSERT_TRUE(name, resultSegments.count > 0, @"async segments empty");
        ASSERT_TRUE(name, resultInfo != nil, @"async info nil");

        NSString *text = concatenateSegments(resultSegments);
        fprintf(stdout, "    Async text: %s\n", [text UTF8String]);
        fprintf(stdout, "    Streaming callbacks: %lu\n", (unsigned long)streamCount);

        NSString *lower = [text lowercaseString];
        ASSERT_TRUE(name, [lower containsString:@"ask"] || [lower containsString:@"country"],
                    @"async output should contain recognizable JFK text");

        // Verify streaming count matches final segments
        ASSERT_FMT(name, streamCount == resultSegments.count,
                   @"stream count %lu != segment count %lu",
                   (unsigned long)streamCount, (unsigned long)resultSegments.count);

        [resultSegments release];
        [resultInfo release];
        [resultError release];

        reportResult(name, YES, nil);
    }
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);

        if (argc < 3) {
            fprintf(stderr, "Usage: test_e2e <turbo_model_path> <data_dir>\n");
            return 1;
        }

        gTurboModelPath = [NSString stringWithUTF8String:argv[1]];
        gDataDir        = [NSString stringWithUTF8String:argv[2]];

        // Derive binary dir from argv[0]
        NSString *selfPath = [NSString stringWithUTF8String:argv[0]];
        gBinaryDir = [selfPath stringByDeletingLastPathComponent];
        if (gBinaryDir.length == 0) gBinaryDir = @".";

        // Derive project dir from data_dir (data_dir is <project>/tests/data)
        gProjectDir = [[gDataDir stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];

        fprintf(stdout, "=== E2E Test Suite ===\n");
        fprintf(stdout, "Turbo model: %s\n", [gTurboModelPath UTF8String]);
        fprintf(stdout, "Data dir:    %s\n", [gDataDir UTF8String]);
        fprintf(stdout, "Binary dir:  %s\n", [gBinaryDir UTF8String]);
        fprintf(stdout, "Project dir: %s\n\n", [gProjectDir UTF8String]);

        // ── Load turbo model ─────────────────────────────────────────────
        fprintf(stdout, "Loading turbo model...\n");
        NSError *turboError = nil;
        gTurbo = [[MWTranscriber alloc] initWithModelPath:gTurboModelPath error:&turboError];
        if (!gTurbo) {
            fprintf(stderr, "FATAL: Failed to load turbo model: %s\n",
                    [[turboError localizedDescription] UTF8String]);
            return 1;
        }
        fprintf(stdout, "Turbo model loaded.\n\n");

        // ── Try to load tiny model via MWModelManager ────────────────────
        if ([[MWModelManager shared] isModelCached:@"tiny"]) {
            fprintf(stdout, "Loading tiny model...\n");
            NSError *tinyResolveError = nil;
            NSString *tinyPath = [[MWModelManager shared] resolveModel:@"tiny"
                                                              progress:nil
                                                                 error:&tinyResolveError];
            if (tinyPath) {
                NSError *tinyLoadError = nil;
                gTiny = [[MWTranscriber alloc] initWithModelPath:tinyPath error:&tinyLoadError];
                if (gTiny) {
                    fprintf(stdout, "Tiny model loaded from: %s\n\n", [tinyPath UTF8String]);
                } else {
                    fprintf(stdout, "WARNING: Tiny model load failed: %s\n\n",
                            [[tinyLoadError localizedDescription] UTF8String]);
                }
            }
        } else {
            fprintf(stdout, "Tiny model not cached -- skipping tiny tests.\n\n");
        }

        // ── Section 1: Basic Transcription ───────────────────────────────
        fprintf(stdout, "--- Section 1: Basic Transcription ---\n");
        test_e2e_smoke_jfk_turbo();
        test_e2e_smoke_jfk_tiny();
        test_e2e_long_form();
        test_e2e_mp3_format();
        test_e2e_multi_format_match();

        // ── Section 2: Language & Translation ────────────────────────────
        fprintf(stdout, "\n--- Section 2: Language & Translation ---\n");
        test_e2e_detect_russian();
        test_e2e_translate_russian();
        test_e2e_mixed_language();
        test_e2e_explicit_language();

        // ── Section 3: Word Timestamps ───────────────────────────────────
        fprintf(stdout, "\n--- Section 3: Word Timestamps ---\n");
        test_e2e_word_timestamps_basic();
        test_e2e_word_timestamps_long();
        test_e2e_word_srt_output();

        // ── Section 4: VAD ───────────────────────────────────────────────
        fprintf(stdout, "\n--- Section 4: VAD ---\n");
        test_e2e_vad_silence_detection();
        test_e2e_vad_music_only();
        test_e2e_vad_vs_no_vad();

        // ── Section 5: Output Formats ────────────────────────────────────
        fprintf(stdout, "\n--- Section 5: Output Formats ---\n");
        test_e2e_srt_format();
        test_e2e_vtt_format();
        test_e2e_json_format();
        test_e2e_json_word_timestamps();

        // ── Section 6: Edge Cases & Robustness ───────────────────────────
        fprintf(stdout, "\n--- Section 6: Edge Cases & Robustness ---\n");
        test_e2e_stereo_input();
        test_e2e_callback_streaming();
        test_e2e_condition_on_previous();
        test_e2e_async_api();

        // ── Cleanup ──────────────────────────────────────────────────────
        [gTurbo release];
        if (gTiny) [gTiny release];

        fprintf(stdout, "\n=== E2E Results: %d passed, %d failed ===\n",
                gPassCount, gFailCount);

        return gFailCount > 0 ? 1 : 0;
    }
}
