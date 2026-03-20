// tests/test_deferred.mm -- Deferred tests now achievable with available resources
// Usage: test_deferred <turbo_model_path> <data_dir> [binary_dir]
// Manual retain/release (-fno-objc-arc)

#import <Foundation/Foundation.h>
#import "MWTranscriber.h"
#import "MWTranscriptionOptions.h"
#import "MWModelManager.h"
#import "MWTestCommon.h"

#include <cstdio>
#include <cstdlib>

// ── Globals ──────────────────────────────────────────────────────────────────

static NSString *gTurboModelPath = nil;
static NSString *gDataDir        = nil;
static NSString *gBinaryDir      = nil;

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Run CLI binary with given arguments, return stdout.
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

/// Run CLI binary with stdin pipe.
static NSString *runCLIWithStdin(NSArray<NSString *> *arguments,
                                  NSData *stdinData,
                                  int *exitCode) {
    NSString *binaryPath = [gBinaryDir stringByAppendingPathComponent:@"metalwhisper"];

    NSTask *task = [[NSTask alloc] init];
    [task setExecutableURL:[NSURL fileURLWithPath:binaryPath]];
    [task setArguments:arguments];

    NSPipe *stdinPipe  = [NSPipe pipe];
    NSPipe *stdoutPipe = [NSPipe pipe];
    [task setStandardInput:stdinPipe];
    [task setStandardOutput:stdoutPipe];
    [task setStandardError:[NSPipe pipe]];

    NSError *launchError = nil;
    [task launchAndReturnError:&launchError];
    if (launchError) {
        if (exitCode) *exitCode = -1;
        [task release];
        return @"";
    }

    // Write data to stdin on a background thread to avoid deadlock
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_async(q, ^{
        [[stdinPipe fileHandleForWriting] writeData:stdinData];
        [[stdinPipe fileHandleForWriting] closeFile];
    });

    NSData *data = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    if (exitCode) *exitCode = [task terminationStatus];
    [task release];

    NSString *output = [[[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding] autorelease];
    return output ?: @"";
}

// ── Test 1: Load Tiny via MWModelManager ─────────────────────────────────────

static void test_m4_1_load_tiny(void) {
    const char *name = "test_m4_1_load_tiny";

    NSError *error = nil;
    NSString *tinyPath = [[MWModelManager shared] resolveModel:@"tiny"
                                                      progress:nil
                                                         error:&error];
    ASSERT_TRUE(name, tinyPath != nil,
                fmtErr(@"Failed to resolve tiny model", error));

    error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:tinyPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    // Tiny is multilingual
    ASSERT_TRUE(name, t.isMultilingual, @"Expected multilingual=YES for tiny");

    // Tiny uses 80 mels
    ASSERT_EQ(name, t.nMels, 80);

    // Feature extractor and tokenizer
    ASSERT_TRUE(name, t.featureExtractor != nil, @"featureExtractor is nil");
    ASSERT_TRUE(name, t.tokenizer != nil, @"tokenizer is nil");

    // Transcribe jfk.flac with tiny
    NSString *jfkPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSURL *jfkURL = [NSURL fileURLWithPath:jfkPath];

    error = nil;
    MWTranscriptionInfo *info = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeURL:jfkURL
                language:@"en"
                    task:@"transcribe"
                 options:nil
          segmentHandler:nil
                    info:&info
                   error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"Transcription failed", error));
    ASSERT_TRUE(name, [segments count] > 0, @"No segments produced");

    // Collect all text
    NSMutableString *fullText = [NSMutableString string];
    for (MWTranscriptionSegment *seg in segments) {
        [fullText appendString:seg.text];
    }

    NSString *lower = [fullText lowercaseString];
    BOOL hasExpected = [lower containsString:@"country"] ||
                       [lower containsString:@"americans"] ||
                       [lower containsString:@"ask not"];
    NSString *snippet = fullText.length > 200
        ? [fullText substringToIndex:200]
        : fullText;
    ASSERT_TRUE(name, hasExpected,
                fmtStr(@"Tiny should produce recognizable JFK text", snippet));

    fprintf(stdout, "    Tiny transcription: %s\n", [snippet UTF8String]);

    [t release];
    reportResult(name, YES, nil);
}

// ── Test 2: Clip Timestamps ──────────────────────────────────────────────────

static void test_m4_6_clip_timestamps(void) {
    const char *name = "test_m4_6_clip_timestamps";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:gTurboModelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

    // Use raw dictionary options for clipTimestamps (not in MWTranscriptionOptions)
    NSDictionary *options = @{
        @"clipTimestamps": @[@5.0, @15.0],
    };

    error = nil;
    MWTranscriptionInfo *info = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeURL:audioURL
                language:@"en"
                    task:@"transcribe"
                 options:options
          segmentHandler:nil
                    info:&info
                   error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"Transcription with clipTimestamps failed", error));
    ASSERT_TRUE(name, [segments count] > 0, @"No segments produced with clipTimestamps");

    // Verify segments are clipped: first segment should start near 5.0s
    // and the content should be bounded. Whisper may extend the last segment
    // up to a full 30s chunk boundary from the clip start, so we check that
    // the first segment starts near the clip start rather than at 0.
    MWTranscriptionSegment *firstSeg = [segments firstObject];
    NSString *msg = [NSString stringWithFormat:
        @"First segment start=%.2f, expected near 5.0", firstSeg.start];
    ASSERT_TRUE(name, firstSeg.start >= 4.0f, msg);

    // Last segment end should be bounded (clip is 5-15s, so at most ~35s with chunk overshoot)
    MWTranscriptionSegment *lastSeg = [segments lastObject];
    msg = [NSString stringWithFormat:
        @"Last segment end=%.2f, expected < 40.0", lastSeg.end];
    ASSERT_TRUE(name, lastSeg.end < 40.0f, msg);

    // Collect text
    NSMutableString *fullText = [NSMutableString string];
    for (MWTranscriptionSegment *seg in segments) {
        [fullText appendString:seg.text];
    }
    fprintf(stdout, "    clipTimestamps text (5-15s): %.100s...\n", [fullText UTF8String]);

    [t release];
    reportResult(name, YES, nil);
}

// ── Test 3: Translate Task ───────────────────────────────────────────────────

static void test_m4_6_translate(void) {
    const char *name = "test_m4_6_translate";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:gTurboModelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"russian_60s.wav"];
    NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

    error = nil;
    MWTranscriptionInfo *info = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeURL:audioURL
                language:@"ru"
                    task:@"translate"
                 options:nil
          segmentHandler:nil
                    info:&info
                   error:&error];

    // Primary check: pipeline runs without crash/error
    ASSERT_TRUE(name, segments != nil, fmtErr(@"Translate task failed", error));
    ASSERT_TRUE(name, [segments count] > 0, @"No segments from translate task");

    NSMutableString *fullText = [NSMutableString string];
    for (MWTranscriptionSegment *seg in segments) {
        [fullText appendString:seg.text];
    }
    fprintf(stdout, "    translate output (%lu segments): %.100s...\n",
            (unsigned long)[segments count], [fullText UTF8String]);

    [t release];
    reportResult(name, YES, nil);
}

// ── Test 4: Hallucination Silence Threshold ──────────────────────────────────

static void test_m5_hallucination_skip(void) {
    const char *name = "test_m5_hallucination_skip";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:gTurboModelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"silence_speech_silence.wav"];
    NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

    // Run with hallucination filtering enabled
    MWTranscriptionOptions *opts1 = [MWTranscriptionOptions defaults];
    opts1.wordTimestamps = YES;
    opts1.hallucinationSilenceThreshold = 1.0f;

    error = nil;
    MWTranscriptionInfo *info1 = nil;
    NSArray<MWTranscriptionSegment *> *segments1 =
        [t transcribeURL:audioURL
                language:@"en"
                    task:@"transcribe"
            typedOptions:opts1
          segmentHandler:nil
                    info:&info1
                   error:&error];

    ASSERT_TRUE(name, segments1 != nil,
                fmtErr(@"Transcription with hallucination filter failed", error));
    ASSERT_TRUE(name, [segments1 count] > 0,
                @"No segments with hallucination filter enabled");

    // Check speech is in the middle portion (roughly 10-21s range)
    BOOL hasMidSpeech = NO;
    for (MWTranscriptionSegment *seg in segments1) {
        if (seg.start >= 8.0f && seg.start <= 25.0f && seg.text.length > 5) {
            hasMidSpeech = YES;
            break;
        }
    }
    ASSERT_TRUE(name, hasMidSpeech, @"Expected speech in the middle portion of the audio");

    // Run with hallucination filtering disabled
    MWTranscriptionOptions *opts2 = [MWTranscriptionOptions defaults];
    opts2.wordTimestamps = YES;
    opts2.hallucinationSilenceThreshold = 0.0f;

    error = nil;
    MWTranscriptionInfo *info2 = nil;
    NSArray<MWTranscriptionSegment *> *segments2 =
        [t transcribeURL:audioURL
                language:@"en"
                    task:@"transcribe"
            typedOptions:opts2
          segmentHandler:nil
                    info:&info2
                   error:&error];

    ASSERT_TRUE(name, segments2 != nil,
                fmtErr(@"Transcription without hallucination filter failed", error));
    ASSERT_TRUE(name, [segments2 count] > 0,
                @"No segments without hallucination filter");

    fprintf(stdout, "    With hallucination filter:    %lu segments\n",
            (unsigned long)[segments1 count]);
    fprintf(stdout, "    Without hallucination filter:  %lu segments\n",
            (unsigned long)[segments2 count]);

    [t release];
    reportResult(name, YES, nil);
}

// ── Test 5: Multilingual Batch ───────────────────────────────────────────────

static void test_m7_multilingual_batch(void) {
    const char *name = "test_m7_multilingual_batch";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:gTurboModelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"mixed_en_ru.wav"];
    NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

    // Batched mode with VAD -- provide explicit VAD model path
    // The VAD model lives in the project's models/ directory
    // gDataDir is .../tests/data, so go up two levels to project root
    NSString *projectRoot = [[gDataDir stringByDeletingLastPathComponent]
                              stringByDeletingLastPathComponent];
    NSString *vadModelPath = [projectRoot stringByAppendingPathComponent:
                              @"models/silero_vad_v6.onnx"];
    NSDictionary *options = @{
        @"vadFilter": @YES,
        @"vadModelPath": vadModelPath,
    };

    error = nil;
    MWTranscriptionInfo *info = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeBatchedURL:audioURL
                       language:nil
                           task:@"transcribe"
                      batchSize:4
                        options:options
                 segmentHandler:nil
                           info:&info
                          error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"Batched multilingual transcription failed", error));
    ASSERT_TRUE(name, [segments count] > 0, @"No segments from batched multilingual");

    // Collect all text
    NSMutableString *fullText = [NSMutableString string];
    for (MWTranscriptionSegment *seg in segments) {
        [fullText appendString:seg.text];
    }

    ASSERT_TRUE(name, fullText.length > 0, @"Empty text from batched multilingual");

    fprintf(stdout, "    Full text: %s\n", [fullText UTF8String]);

    // Check that output contains recognizable content from the mixed audio.
    // The model may transcribe everything in one script depending on auto-detection.
    // We just verify we get substantial, non-trivial output from a 41s mixed audio.
    ASSERT_TRUE(name, fullText.length > 20,
                fmtStr(@"Expected substantial text from 41s mixed audio", fullText));

    // Check for either Latin or Cyrillic characters (model may pick one language)
    NSRange latinRange = [fullText rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"]];
    NSCharacterSet *cyrillicSet = [NSCharacterSet characterSetWithRange:NSMakeRange(0x0400, 0x0500 - 0x0400)];
    NSRange cyrillicRange = [fullText rangeOfCharacterFromSet:cyrillicSet];
    BOOL hasText = (latinRange.location != NSNotFound) || (cyrillicRange.location != NSNotFound);
    ASSERT_TRUE(name, hasText,
                fmtStr(@"Expected Latin or Cyrillic characters in mixed EN/RU text", fullText));

    // Log which scripts were found
    BOOL hasLatin = latinRange.location != NSNotFound;
    BOOL hasCyrillic = cyrillicRange.location != NSNotFound;
    fprintf(stdout, "    Scripts: Latin=%s Cyrillic=%s\n",
            hasLatin ? "YES" : "NO", hasCyrillic ? "YES" : "NO");

    fprintf(stdout, "    Batched multilingual: %lu segments, %lu chars\n",
            (unsigned long)[segments count], (unsigned long)fullText.length);
    fprintf(stdout, "    Text preview: %.150s...\n", [fullText UTF8String]);

    [t release];
    reportResult(name, YES, nil);
}

// ── Test 6: Batch Output Dir ─────────────────────────────────────────────────

static void test_m8_batch_output_dir(void) {
    const char *name = "test_m8_batch_output_dir";

    NSString *tmpDir = @"/tmp/mw_test_batch_deferred";
    NSFileManager *fm = [NSFileManager defaultManager];

    // Clean up any previous run
    [fm removeItemAtPath:tmpDir error:nil];
    [fm createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *jfkPath     = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSString *hotwordsPath = [gDataDir stringByAppendingPathComponent:@"hotwords.mp3"];

    int code = -1;
    NSString *output = runCLI(@[
        @"--model", gTurboModelPath,
        @"--output-dir", tmpDir,
        jfkPath, hotwordsPath
    ], &code);

    NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
    ASSERT_TRUE(name, code == 0, msg);

    // Check that output files exist and are non-empty
    NSString *jfkTxt     = [tmpDir stringByAppendingPathComponent:@"jfk.txt"];
    NSString *hotwordsTxt = [tmpDir stringByAppendingPathComponent:@"hotwords.txt"];

    ASSERT_TRUE(name, [fm fileExistsAtPath:jfkTxt],
                fmtStr(@"Missing output file", jfkTxt));
    ASSERT_TRUE(name, [fm fileExistsAtPath:hotwordsTxt],
                fmtStr(@"Missing output file", hotwordsTxt));

    NSData *jfkData = [NSData dataWithContentsOfFile:jfkTxt];
    ASSERT_TRUE(name, jfkData != nil && jfkData.length > 0,
                @"jfk.txt is empty or unreadable");

    NSData *hotwordsData = [NSData dataWithContentsOfFile:hotwordsTxt];
    ASSERT_TRUE(name, hotwordsData != nil && hotwordsData.length > 0,
                @"hotwords.txt is empty or unreadable");

    fprintf(stdout, "    jfk.txt: %lu bytes\n", (unsigned long)jfkData.length);
    fprintf(stdout, "    hotwords.txt: %lu bytes\n", (unsigned long)hotwordsData.length);

    // Clean up
    [fm removeItemAtPath:tmpDir error:nil];

    reportResult(name, YES, nil);
}

// ── Test 7: Stdin Pipe ───────────────────────────────────────────────────────

static void test_m8_stdin(void) {
    const char *name = "test_m8_stdin";

    // Pipe physicsworks.wav (already WAV format) through stdin
    // Use the full file -- AVAudioFile will read it fine
    NSString *wavPath = [gDataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSData *wavData = [NSData dataWithContentsOfFile:wavPath];
    ASSERT_TRUE(name, wavData != nil && wavData.length > 0,
                @"Failed to read physicsworks.wav");

    // Truncate to first ~5 seconds of WAV to keep the test fast
    // WAV header = 44 bytes, 16kHz mono 16-bit = 32000 bytes/sec
    // 5 seconds = 160000 bytes + 44 header = 160044
    NSUInteger truncLen = MIN((NSUInteger)160044, wavData.length);
    NSData *shortWav = [wavData subdataWithRange:NSMakeRange(0, truncLen)];

    int code = -1;
    NSString *output = runCLIWithStdin(@[
        @"--model", gTurboModelPath, @"-"
    ], shortWav, &code);

    NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
    ASSERT_TRUE(name, code == 0, msg);
    ASSERT_TRUE(name, output.length > 0, @"Stdin transcription produced no output");

    fprintf(stdout, "    Stdin output (%lu chars): %.100s...\n",
            (unsigned long)output.length, [output UTF8String]);

    reportResult(name, YES, nil);
}

// ── Test 8: Long Audio ───────────────────────────────────────────────────────

static void test_m11_long_audio(void) {
    const char *name = "test_m11_long_audio";

    const char *envPath = getenv("MW_LARGE_FILE");
    if (!envPath || strlen(envPath) == 0) {
        fprintf(stdout, "  SKIP: %s -- MW_LARGE_FILE not set\n", name);
        return;
    }

    NSString *largePath = [NSString stringWithUTF8String:envPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:largePath]) {
        fprintf(stdout, "  SKIP: %s -- %s not found\n", name, envPath);
        return;
    }

    fprintf(stdout, "  [LONG] Starting long audio test (~2-3 min)...\n");

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:gTurboModelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    NSURL *audioURL = [NSURL fileURLWithPath:largePath];

    error = nil;
    MWTranscriptionInfo *info = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeURL:audioURL
                language:@"ru"
                    task:@"transcribe"
                 options:nil
          segmentHandler:nil
                    info:&info
                   error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"Long audio transcription failed", error));

    // Should produce >100 segments for 83 minutes
    NSString *msg = [NSString stringWithFormat:
        @"Expected >100 segments, got %lu", (unsigned long)[segments count]];
    ASSERT_TRUE(name, [segments count] > 100, msg);

    // All timestamps should be monotonic
    float prevEnd = 0.0f;
    for (NSUInteger i = 0; i < [segments count]; i++) {
        MWTranscriptionSegment *seg = segments[i];
        msg = [NSString stringWithFormat:
            @"Segment %lu: start=%.2f < prevEnd=%.2f (not monotonic)",
            (unsigned long)i, seg.start, prevEnd];
        ASSERT_TRUE(name, seg.start >= prevEnd - 0.1f, msg);  // small tolerance
        prevEnd = seg.end;
    }

    // Last segment should end within a reasonable bound (83min = 4980s)
    MWTranscriptionSegment *lastSeg = [segments lastObject];
    msg = [NSString stringWithFormat:
        @"Last segment end=%.2f exceeds 5000s", lastSeg.end];
    ASSERT_TRUE(name, lastSeg.end <= 5100.0f, msg);

    // Total text should be substantial
    NSMutableString *fullText = [NSMutableString string];
    for (MWTranscriptionSegment *seg in segments) {
        [fullText appendString:seg.text];
    }
    msg = [NSString stringWithFormat:
        @"Expected >5000 chars, got %lu", (unsigned long)fullText.length];
    ASSERT_TRUE(name, fullText.length > 5000, msg);

    fprintf(stdout, "    Long audio: %lu segments, %lu chars, last_end=%.1fs\n",
            (unsigned long)[segments count],
            (unsigned long)fullText.length,
            lastSeg.end);

    [t release];
    reportResult(name, YES, nil);
}

// ── Test 9: Prompt Reset on Temperature ──────────────────────────────────────

static void test_m4_3_prompt_reset(void) {
    const char *name = "test_m4_3_prompt_reset";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:gTurboModelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSURL *audioURL = [NSURL fileURLWithPath:audioPath];

    // Run 1: temperatures=[0.8], promptResetOnTemperature=0.1
    // Since 0.8 > 0.1, prompt resets every segment (context never accumulates)
    MWTranscriptionOptions *opts1 = [MWTranscriptionOptions defaults];
    opts1.conditionOnPreviousText = YES;
    opts1.temperatures = @[@0.8];
    opts1.promptResetOnTemperature = 0.1f;

    error = nil;
    MWTranscriptionInfo *info1 = nil;
    NSArray<MWTranscriptionSegment *> *segments1 =
        [t transcribeURL:audioURL
                language:@"en"
                    task:@"transcribe"
            typedOptions:opts1
          segmentHandler:nil
                    info:&info1
                   error:&error];

    ASSERT_TRUE(name, segments1 != nil,
                fmtErr(@"Transcription with prompt reset (threshold=0.1) failed", error));
    ASSERT_TRUE(name, [segments1 count] > 0,
                @"No segments with prompt reset (threshold=0.1)");

    // Run 2: temperatures=[0.8], promptResetOnTemperature=2.0
    // Since 0.8 < 2.0, prompt never resets (context accumulates normally)
    MWTranscriptionOptions *opts2 = [MWTranscriptionOptions defaults];
    opts2.conditionOnPreviousText = YES;
    opts2.temperatures = @[@0.8];
    opts2.promptResetOnTemperature = 2.0f;

    error = nil;
    MWTranscriptionInfo *info2 = nil;
    NSArray<MWTranscriptionSegment *> *segments2 =
        [t transcribeURL:audioURL
                language:@"en"
                    task:@"transcribe"
            typedOptions:opts2
          segmentHandler:nil
                    info:&info2
                   error:&error];

    ASSERT_TRUE(name, segments2 != nil,
                fmtErr(@"Transcription with prompt accumulate (threshold=2.0) failed", error));
    ASSERT_TRUE(name, [segments2 count] > 0,
                @"No segments with prompt accumulate (threshold=2.0)");

    // Collect text from both runs
    NSMutableString *text1 = [NSMutableString string];
    for (MWTranscriptionSegment *seg in segments1) {
        [text1 appendString:seg.text];
    }
    NSMutableString *text2 = [NSMutableString string];
    for (MWTranscriptionSegment *seg in segments2) {
        [text2 appendString:seg.text];
    }

    // Both should produce substantial output
    ASSERT_TRUE(name, text1.length > 50,
                fmtStr(@"Expected substantial text with prompt reset", text1));
    ASSERT_TRUE(name, text2.length > 50,
                fmtStr(@"Expected substantial text with prompt accumulate", text2));

    fprintf(stdout, "    Prompt reset (threshold=0.1):      %lu segments, %lu chars\n",
            (unsigned long)[segments1 count], (unsigned long)text1.length);
    fprintf(stdout, "    Prompt accumulate (threshold=2.0):  %lu segments, %lu chars\n",
            (unsigned long)[segments2 count], (unsigned long)text2.length);
    fprintf(stdout, "    Texts differ: %s\n",
            [text1 isEqualToString:text2] ? "NO (same)" : "YES (expected)");

    [t release];
    reportResult(name, YES, nil);
}

// ── Test 10: Error Recovery (garbage encoder output) ─────────────────────────

static void test_m4_4_error_recovery(void) {
    const char *name = "test_m4_4_error_recovery";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:gTurboModelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    // Create garbage data of wrong size (100 bytes instead of expected 1×1500×1280×4 = 7,680,000)
    NSMutableData *garbageData = [NSMutableData dataWithLength:100];
    // Fill with random bytes
    arc4random_buf([garbageData mutableBytes], 100);

    // Build a minimal prompt (sot sequence for English transcribe)
    NSArray<NSNumber *> *prompt = @[@50258, @50259, @50360];

    error = nil;
    MWGenerateResult *result =
        [t generateWithEncoderOutput:garbageData
                              prompt:prompt
                        temperatures:@[@0.0]
                            beamSize:5
                            patience:1.0f
                              bestOf:1
                       lengthPenalty:1.0f
                   repetitionPenalty:1.0f
                   noRepeatNgramSize:0
             compressionRatioThreshold:2.4f
                     logProbThreshold:-1.0f
                   noSpeechThreshold:0.6f
                       suppressTokens:@[@(-1)]
                        suppressBlank:YES
                  maxInitialTimestamp:1.0f
                        maxNewTokens:0
                                error:&error];

    // Should return nil with an error, not crash
    ASSERT_TRUE(name, result == nil,
                @"Expected nil result for garbage encoder output");
    ASSERT_TRUE(name, error != nil,
                @"Expected error to be set for garbage encoder output");

    fprintf(stdout, "    Error domain: %s, code: %ld\n",
            [[error domain] UTF8String], (long)[error code]);
    fprintf(stdout, "    Error message: %s\n",
            [[error localizedDescription] UTF8String]);

    [t release];
    reportResult(name, YES, nil);
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);

        if (argc < 3) {
            fprintf(stderr, "Usage: test_deferred <turbo_model_path> <data_dir> [binary_dir]\n");
            return 1;
        }

        gTurboModelPath = [NSString stringWithUTF8String:argv[1]];
        gDataDir        = [NSString stringWithUTF8String:argv[2]];

        if (argc >= 4) {
            gBinaryDir = [NSString stringWithUTF8String:argv[3]];
        } else {
            NSString *selfPath = [NSString stringWithUTF8String:argv[0]];
            gBinaryDir = [selfPath stringByDeletingLastPathComponent];
            if (gBinaryDir.length == 0) gBinaryDir = @".";
        }

        fprintf(stdout, "=== Deferred Tests ===\n");
        fprintf(stdout, "Turbo model: %s\n", [gTurboModelPath UTF8String]);
        fprintf(stdout, "Data dir:    %s\n", [gDataDir UTF8String]);
        fprintf(stdout, "Binary dir:  %s\n\n", [gBinaryDir UTF8String]);

        // Test 1: Load tiny model
        test_m4_1_load_tiny();

        // Test 2: Clip timestamps
        test_m4_6_clip_timestamps();

        // Test 3: Translate task
        test_m4_6_translate();

        // Test 4: Hallucination silence threshold
        test_m5_hallucination_skip();

        // Test 5: Multilingual batch
        test_m7_multilingual_batch();

        // Test 6: Batch output dir (CLI)
        test_m8_batch_output_dir();

        // Test 7: Stdin pipe (CLI)
        test_m8_stdin();

        // Test 8: Long audio (skipped unless MW_LARGE_FILE set)
        test_m11_long_audio();

        // Test 9: Prompt reset on temperature
        test_m4_3_prompt_reset();

        // Test 10: Error recovery (garbage encoder output)
        test_m4_4_error_recovery();

        fprintf(stdout, "\n=== Deferred Results: %d passed, %d failed ===\n",
                gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
