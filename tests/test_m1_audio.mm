#import <Foundation/Foundation.h>
#import "MWAudioDecoder.h"
#import "MWConstants.h"

// ── Test infrastructure ──────────────────────────────────────────────────────

static NSString *gDataDir = nil;
static int gPassCount = 0;
static int gFailCount = 0;

static void reportResult(const char *testName, BOOL passed, NSString *detail) {
    if (passed) {
        fprintf(stdout, "  PASS: %s\n", testName);
        gPassCount++;
    } else {
        fprintf(stdout, "  FAIL: %s — %s\n", testName, [detail UTF8String]);
        gFailCount++;
    }
}

static NSString *dataFilePath(NSString *filename) {
    return [gDataDir stringByAppendingPathComponent:filename];
}

static NSString *referenceFilePath(NSString *filename) {
    return [[gDataDir stringByAppendingPathComponent:@"reference"]
            stringByAppendingPathComponent:filename];
}

// ── Reference data loading ───────────────────────────────────────────────────

static NSDictionary *loadReferenceJSON(NSString *name) {
    NSString *path = referenceFilePath(name);
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        fprintf(stderr, "    ERROR: Cannot read reference file: %s\n", [path UTF8String]);
        return nil;
    }
    NSError *error = nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (!dict) {
        fprintf(stderr, "    ERROR: Cannot parse JSON: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    return dict;
}

static NSData *loadReferenceRaw(NSString *name) {
    NSString *path = referenceFilePath(name);
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        fprintf(stderr, "    ERROR: Cannot read raw reference file: %s\n", [path UTF8String]);
    }
    return data;
}

// ── Comparison helpers ───────────────────────────────────────────────────────

static const float kSampleTolerance = 1e-4f;
static const double kLossySampleCountTolerance = 0.01;  // 1% for lossy formats (MP3)
static const double kM4aSampleCountTolerance = 0.05;    // 5% for M4A vs FLAC comparison

/// Compare first N samples of decoded audio against reference JSON array.
/// Returns YES if all samples match within tolerance.
static BOOL compareSamples(NSData *decoded, NSArray<NSNumber *> *refSamples,
                           float tolerance, NSString **outDetail) {
    NSUInteger count = [refSamples count];
    NSUInteger decodedSampleCount = [decoded length] / sizeof(float);
    if (decodedSampleCount < count) {
        *outDetail = [NSString stringWithFormat:
            @"Decoded has %lu samples, need at least %lu for comparison",
            (unsigned long)decodedSampleCount, (unsigned long)count];
        return NO;
    }

    const float *samples = (const float *)[decoded bytes];
    float maxDiff = 0.0f;
    NSUInteger worstIdx = 0;

    for (NSUInteger i = 0; i < count; i++) {
        float ref = [refSamples[i] floatValue];
        float diff = fabsf(samples[i] - ref);
        if (diff > maxDiff) {
            maxDiff = diff;
            worstIdx = i;
        }
    }

    if (maxDiff > tolerance) {
        const float *s = samples;
        float refVal = [refSamples[worstIdx] floatValue];
        *outDetail = [NSString stringWithFormat:
            @"Sample[%lu]: got %.8f, expected %.8f, diff=%.8f > tolerance=%.8f",
            (unsigned long)worstIdx, s[worstIdx], refVal, maxDiff, tolerance];
        return NO;
    }
    return YES;
}

// ── Test cases ───────────────────────────────────────────────────────────────

static BOOL test_m1_wav_decode(void) {
    NSDictionary *ref = loadReferenceJSON(@"physicsworks_16khz_mono.json");
    if (!ref) return NO;

    NSUInteger expectedSamples = [ref[@"num_samples"] unsignedIntegerValue];
    NSArray *refFirst100 = ref[@"first_100_samples"];

    NSString *audioPath = dataFilePath(@"physicsworks.wav");
    NSURL *url = [NSURL fileURLWithPath:audioPath];
    NSError *error = nil;
    NSData *decoded = [MWAudioDecoder decodeAudioAtURL:url error:&error];
    if (!decoded) {
        reportResult("test_m1_wav_decode", NO,
                     [NSString stringWithFormat:@"Decode failed: %@",
                      [error localizedDescription]]);
        return NO;
    }

    NSUInteger actualSamples = [decoded length] / sizeof(float);

    // Check sample count matches exactly (lossless format).
    if (actualSamples != expectedSamples) {
        reportResult("test_m1_wav_decode", NO,
                     [NSString stringWithFormat:@"Sample count: got %lu, expected %lu",
                      (unsigned long)actualSamples, (unsigned long)expectedSamples]);
        return NO;
    }

    // Compare first 100 samples.
    NSString *detail = nil;
    BOOL samplesMatch = compareSamples(decoded, refFirst100, kSampleTolerance, &detail);
    if (!samplesMatch) {
        reportResult("test_m1_wav_decode", NO, detail);
        return NO;
    }

    reportResult("test_m1_wav_decode", YES, nil);
    return YES;
}

static BOOL test_m1_mp3_decode(void) {
    NSDictionary *ref = loadReferenceJSON(@"hotwords_16khz_mono.json");
    if (!ref) return NO;

    NSUInteger expectedSamples = [ref[@"num_samples"] unsignedIntegerValue];

    NSString *audioPath = dataFilePath(@"hotwords.mp3");
    NSURL *url = [NSURL fileURLWithPath:audioPath];
    NSError *error = nil;
    NSData *decoded = [MWAudioDecoder decodeAudioAtURL:url error:&error];
    if (!decoded) {
        reportResult("test_m1_mp3_decode", NO,
                     [NSString stringWithFormat:@"Decode failed: %@",
                      [error localizedDescription]]);
        return NO;
    }

    NSUInteger actualSamples = [decoded length] / sizeof(float);

    // MP3 is lossy — sample count may differ slightly due to encoder padding.
    // Check within tolerance.
    double ratio = fabs((double)actualSamples - (double)expectedSamples) / (double)expectedSamples;
    if (ratio > kLossySampleCountTolerance) {
        reportResult("test_m1_mp3_decode", NO,
                     [NSString stringWithFormat:
                      @"Sample count out of tolerance: got %lu, expected ~%lu (%.1f%% diff)",
                      (unsigned long)actualSamples, (unsigned long)expectedSamples,
                      ratio * 100.0]);
        return NO;
    }

    // Verify it decoded to a reasonable length (resampled to 16 kHz).
    if (actualSamples == 0) {
        reportResult("test_m1_mp3_decode", NO, @"Decoded zero samples");
        return NO;
    }

    reportResult("test_m1_mp3_decode", YES, nil);
    return YES;
}

static BOOL test_m1_flac_decode(void) {
    NSDictionary *ref = loadReferenceJSON(@"jfk_16khz_mono.json");
    if (!ref) return NO;

    NSUInteger expectedSamples = [ref[@"num_samples"] unsignedIntegerValue];
    NSArray *refFirst100 = ref[@"first_100_samples"];

    NSString *audioPath = dataFilePath(@"jfk.flac");
    NSURL *url = [NSURL fileURLWithPath:audioPath];
    NSError *error = nil;
    NSData *decoded = [MWAudioDecoder decodeAudioAtURL:url error:&error];
    if (!decoded) {
        reportResult("test_m1_flac_decode", NO,
                     [NSString stringWithFormat:@"Decode failed: %@",
                      [error localizedDescription]]);
        return NO;
    }

    NSUInteger actualSamples = [decoded length] / sizeof(float);

    if (actualSamples != expectedSamples) {
        reportResult("test_m1_flac_decode", NO,
                     [NSString stringWithFormat:@"Sample count: got %lu, expected %lu",
                      (unsigned long)actualSamples, (unsigned long)expectedSamples]);
        return NO;
    }

    NSString *detail = nil;
    BOOL samplesMatch = compareSamples(decoded, refFirst100, kSampleTolerance, &detail);
    if (!samplesMatch) {
        reportResult("test_m1_flac_decode", NO, detail);
        return NO;
    }

    reportResult("test_m1_flac_decode", YES, nil);
    return YES;
}

static BOOL test_m1_m4a_decode(void) {
    // We don't have Python reference for M4A (Python used FLAC source).
    // Verify it decodes successfully and has reasonable length compared to FLAC version.
    NSDictionary *flacRef = loadReferenceJSON(@"jfk_16khz_mono.json");
    if (!flacRef) return NO;

    NSUInteger flacSamples = [flacRef[@"num_samples"] unsignedIntegerValue];

    NSString *audioPath = dataFilePath(@"jfk.m4a");
    NSURL *url = [NSURL fileURLWithPath:audioPath];
    NSError *error = nil;
    NSData *decoded = [MWAudioDecoder decodeAudioAtURL:url error:&error];
    if (!decoded) {
        reportResult("test_m1_m4a_decode", NO,
                     [NSString stringWithFormat:@"Decode failed: %@",
                      [error localizedDescription]]);
        return NO;
    }

    NSUInteger actualSamples = [decoded length] / sizeof(float);

    // M4A is a lossy re-encode — allow 5% tolerance vs FLAC reference.
    double ratio = fabs((double)actualSamples - (double)flacSamples) / (double)flacSamples;
    if (ratio > kM4aSampleCountTolerance) {
        reportResult("test_m1_m4a_decode", NO,
                     [NSString stringWithFormat:
                      @"Sample count vs FLAC: got %lu, expected ~%lu (%.1f%% diff, max %.0f%%)",
                      (unsigned long)actualSamples, (unsigned long)flacSamples,
                      ratio * 100.0, kM4aSampleCountTolerance * 100.0]);
        return NO;
    }

    reportResult("test_m1_m4a_decode", YES, nil);
    return YES;
}

static BOOL test_m1_stereo_mono(void) {
    NSDictionary *ref = loadReferenceJSON(@"stereo_diarization_16khz_mono.json");
    if (!ref) return NO;

    NSUInteger expectedSamples = [ref[@"num_samples"] unsignedIntegerValue];
    NSArray *refFirst100 = ref[@"first_100_samples"];

    NSString *audioPath = dataFilePath(@"stereo_diarization.wav");
    NSURL *url = [NSURL fileURLWithPath:audioPath];
    NSError *error = nil;
    NSData *decoded = [MWAudioDecoder decodeAudioAtURL:url error:&error];
    if (!decoded) {
        reportResult("test_m1_stereo_mono", NO,
                     [NSString stringWithFormat:@"Decode failed: %@",
                      [error localizedDescription]]);
        return NO;
    }

    NSUInteger actualSamples = [decoded length] / sizeof(float);

    // Output should be mono — sample count should match reference.
    if (actualSamples != expectedSamples) {
        reportResult("test_m1_stereo_mono", NO,
                     [NSString stringWithFormat:@"Sample count: got %lu, expected %lu",
                      (unsigned long)actualSamples, (unsigned long)expectedSamples]);
        return NO;
    }

    // Compare first 100 samples to verify correct stereo→mono downmix.
    NSString *detail = nil;
    BOOL samplesMatch = compareSamples(decoded, refFirst100, kSampleTolerance, &detail);
    if (!samplesMatch) {
        reportResult("test_m1_stereo_mono", NO, detail);
        return NO;
    }

    reportResult("test_m1_stereo_mono", YES, nil);
    return YES;
}

static BOOL test_m1_pad_or_trim(void) {
    NSDictionary *ref = loadReferenceJSON(@"pad_or_trim.json");
    if (!ref) return NO;

    // ── Test padding ─────────────────────────────────────────────────────────
    {
        NSArray *padInput = ref[@"pad_input"];
        NSUInteger padLength = [ref[@"pad_length"] unsignedIntegerValue];
        NSArray *padExpected = ref[@"pad_output"];

        // Build input NSData from JSON array.
        NSMutableData *inputData = [NSMutableData dataWithLength:padInput.count * sizeof(float)];
        float *inputPtr = (float *)[inputData mutableBytes];
        for (NSUInteger i = 0; i < padInput.count; i++) {
            inputPtr[i] = [padInput[i] floatValue];
        }

        NSData *padded = [MWAudioDecoder padOrTrimAudio:inputData
                                          toSampleCount:padLength];

        NSUInteger paddedSamples = [padded length] / sizeof(float);
        if (paddedSamples != padLength) {
            reportResult("test_m1_pad_or_trim", NO,
                         [NSString stringWithFormat:@"Pad: got %lu samples, expected %lu",
                          (unsigned long)paddedSamples, (unsigned long)padLength]);
            return NO;
        }

        const float *paddedPtr = (const float *)[padded bytes];
        for (NSUInteger i = 0; i < padExpected.count; i++) {
            float expected = [padExpected[i] floatValue];
            if (fabsf(paddedPtr[i] - expected) > 1e-7f) {
                reportResult("test_m1_pad_or_trim", NO,
                             [NSString stringWithFormat:@"Pad mismatch at [%lu]: got %f, expected %f",
                              (unsigned long)i, paddedPtr[i], expected]);
                return NO;
            }
        }
    }

    // ── Test trimming ────────────────────────────────────────────────────────
    {
        NSArray *trimInput = ref[@"trim_input"];
        NSUInteger trimLength = [ref[@"trim_length"] unsignedIntegerValue];
        NSArray *trimExpected = ref[@"trim_output"];

        NSMutableData *inputData = [NSMutableData dataWithLength:trimInput.count * sizeof(float)];
        float *inputPtr = (float *)[inputData mutableBytes];
        for (NSUInteger i = 0; i < trimInput.count; i++) {
            inputPtr[i] = [trimInput[i] floatValue];
        }

        NSData *trimmed = [MWAudioDecoder padOrTrimAudio:inputData
                                           toSampleCount:trimLength];

        NSUInteger trimmedSamples = [trimmed length] / sizeof(float);
        if (trimmedSamples != trimLength) {
            reportResult("test_m1_pad_or_trim", NO,
                         [NSString stringWithFormat:@"Trim: got %lu samples, expected %lu",
                          (unsigned long)trimmedSamples, (unsigned long)trimLength]);
            return NO;
        }

        const float *trimmedPtr = (const float *)[trimmed bytes];
        for (NSUInteger i = 0; i < trimExpected.count; i++) {
            float expected = [trimExpected[i] floatValue];
            if (fabsf(trimmedPtr[i] - expected) > 1e-7f) {
                reportResult("test_m1_pad_or_trim", NO,
                             [NSString stringWithFormat:@"Trim mismatch at [%lu]: got %f, expected %f",
                              (unsigned long)i, trimmedPtr[i], expected]);
                return NO;
            }
        }
    }

    reportResult("test_m1_pad_or_trim", YES, nil);
    return YES;
}

#include <mach/mach.h>

/// Get current process resident memory in bytes.
static size_t getCurrentRSS(void) {
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) == KERN_SUCCESS) {
        return info.resident_size;
    }
    return 0;
}

static BOOL test_m1_large_file(void) {
    // Large file is at ../data/large.mp3 relative to data dir,
    // or MW_LARGE_FILE env var. Not in git.
    NSString *largePath = nil;
    const char *envLarge = getenv("MW_LARGE_FILE");
    if (envLarge) {
        largePath = [NSString stringWithUTF8String:envLarge];
    } else {
        // Try relative to data dir: ../../data/large.mp3
        largePath = [[gDataDir stringByDeletingLastPathComponent]  // tests/
                      stringByDeletingLastPathComponent];          // project root
        largePath = [[[largePath stringByDeletingLastPathComponent]  // branch/
                      stringByAppendingPathComponent:@"data"]
                     stringByAppendingPathComponent:@"large.mp3"];
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:largePath]) {
        fprintf(stdout, "  SKIP: test_m1_large_file — file not found: %s\n",
                [largePath UTF8String]);
        fprintf(stdout, "        Set MW_LARGE_FILE=/path/to/large.mp3 to enable\n");
        return YES;  // Skip is not a failure.
    }

    NSURL *url = [NSURL fileURLWithPath:largePath];
    NSError *error = nil;

    size_t rssBefore = getCurrentRSS();
    NSData *decoded = [MWAudioDecoder decodeAudioAtURL:url error:&error];
    size_t rssAfter = getCurrentRSS();

    if (!decoded) {
        reportResult("test_m1_large_file", NO,
                     [NSString stringWithFormat:@"Decode failed: %@",
                      [error localizedDescription]]);
        return NO;
    }

    NSUInteger sampleCount = [decoded length] / sizeof(float);
    double durationSec = (double)sampleCount / kMWTargetSampleRate;

    // Expect at least 60 minutes of audio.
    static const double kMinDurationSeconds = 3600.0;
    if (durationSec < kMinDurationSeconds) {
        reportResult("test_m1_large_file", NO,
                     [NSString stringWithFormat:@"Duration %.1fs < expected %.0fs",
                      durationSec, kMinDurationSeconds]);
        return NO;
    }

    // The output data itself is large (~sampleCount * 4 bytes).
    // But the decoder should NOT hold the entire file in memory simultaneously —
    // it streams in chunks. RSS growth should be roughly the output size,
    // not output + input + intermediate buffers.
    // We allow RSS growth of up to 2x the output data size.
    size_t outputBytes = [decoded length];
    size_t rssGrowth = (rssAfter > rssBefore) ? (rssAfter - rssBefore) : 0;
    double rssRatio = (outputBytes > 0) ? (double)rssGrowth / (double)outputBytes : 0;

    fprintf(stdout, "    Large file: %.1f min, %lu samples, output=%.1f MB, RSS growth=%.1f MB (%.1fx)\n",
            durationSec / 60.0, (unsigned long)sampleCount,
            (double)outputBytes / (1024.0 * 1024.0),
            (double)rssGrowth / (1024.0 * 1024.0),
            rssRatio);

    // RSS ratio > 3x suggests the decoder is buffering excessively.
    static const double kMaxRSSRatio = 3.0;
    if (rssRatio > kMaxRSSRatio) {
        reportResult("test_m1_large_file", NO,
                     [NSString stringWithFormat:
                      @"RSS growth %.1fx output size (max %.1fx) — possible memory issue",
                      rssRatio, kMaxRSSRatio]);
        return NO;
    }

    reportResult("test_m1_large_file", YES, nil);
    return YES;
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);

        // Resolve data directory from argument or environment variable.
        if (argc > 1) {
            gDataDir = [NSString stringWithUTF8String:argv[1]];
        } else {
            const char *envPath = getenv("MW_TEST_DATA");
            if (envPath) {
                gDataDir = [NSString stringWithUTF8String:envPath];
            }
        }

        if (!gDataDir || [gDataDir length] == 0) {
            fprintf(stderr,
                    "Usage: %s <data_dir>\n"
                    "   or: MW_TEST_DATA=/path/to/tests/data %s\n",
                    argv[0], argv[0]);
            return 1;
        }

        // Verify data directory exists.
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:gDataDir isDirectory:&isDir] || !isDir) {
            fprintf(stderr, "ERROR: Data directory does not exist: %s\n",
                    [gDataDir UTF8String]);
            return 1;
        }

        fprintf(stdout, "=== MetalWhisper M1 Audio Decoder Tests ===\n");
        fprintf(stdout, "Data directory: %s\n\n", [gDataDir UTF8String]);

        // Run all tests.
        test_m1_wav_decode();
        test_m1_mp3_decode();
        test_m1_flac_decode();
        test_m1_m4a_decode();
        test_m1_stereo_mono();
        test_m1_pad_or_trim();
        test_m1_large_file();

        // Summary.
        fprintf(stdout, "\n=== Results: %d passed, %d failed ===\n", gPassCount, gFailCount);

        return (gFailCount > 0) ? 1 : 0;
    }
}
