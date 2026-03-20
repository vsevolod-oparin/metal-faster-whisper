// tests/test_m8_cli.mm — CLI integration tests for metalwhisper binary
// Usage: test_m8_cli <model_path> <data_dir> [binary_dir]
// Manual retain/release (-fno-objc-arc)

#import <Foundation/Foundation.h>
#import "MWTestCommon.h"

#include <cstdio>
#include <cstdlib>

// ── Globals ────────────────────────────────────────────────────────────────

static NSString *gModelPath = nil;
static NSString *gDataDir   = nil;
static NSString *gBinaryDir = nil;

// ── Subprocess helper ──────────────────────────────────────────────────────

/// Run the CLI binary with the given arguments.
/// Returns stdout as a string. Sets *exitCode to the process exit code.
static NSString *runCLI(NSString *args, int *exitCode) {
    NSString *binaryPath = [gBinaryDir stringByAppendingPathComponent:@"metalwhisper"];
    NSString *cmd = [NSString stringWithFormat:@"\"%@\" %@", binaryPath, args];

    FILE *fp = popen([cmd UTF8String], "r");
    if (!fp) {
        if (exitCode) *exitCode = -1;
        return @"";
    }

    NSMutableData *data = [[NSMutableData alloc] init];
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) {
        [data appendBytes:buf length:n];
    }

    int status = pclose(fp);
    if (exitCode) {
        *exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }

    NSString *output = [[[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding] autorelease];
    [data release];
    return output ?: @"";
}

/// Run CLI with stderr captured.
static NSString *runCLIWithStderr(NSString *args, int *exitCode, NSString **stderrOut) {
    NSString *binaryPath = [gBinaryDir stringByAppendingPathComponent:@"metalwhisper"];
    NSString *stderrFile = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"metalwhisper_test_stderr.txt"];
    NSString *cmd = [NSString stringWithFormat:@"\"%@\" %@ 2>\"%@\"",
        binaryPath, args, stderrFile];

    FILE *fp = popen([cmd UTF8String], "r");
    if (!fp) {
        if (exitCode) *exitCode = -1;
        return @"";
    }

    NSMutableData *data = [[NSMutableData alloc] init];
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) {
        [data appendBytes:buf length:n];
    }

    int status = pclose(fp);
    if (exitCode) {
        *exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }

    NSString *output = [[[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding] autorelease];
    [data release];

    if (stderrOut) {
        *stderrOut = [NSString stringWithContentsOfFile:stderrFile
                                               encoding:NSUTF8StringEncoding
                                                  error:nil] ?: @"";
    }
    [[NSFileManager defaultManager] removeItemAtPath:stderrFile error:nil];

    return output ?: @"";
}

// ── Tests ──────────────────────────────────────────────────────────────────

static void test_m8_help(void) {
    const char *name = "test_m8_help";
    int code = -1;
    NSString *output = runCLI(@"--help", &code);

    NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
    ASSERT_TRUE(name, code == 0, msg);
    BOOL hasKeyword = [output containsString:@"metalwhisper"] || [output containsString:@"Usage"];
    ASSERT_TRUE(name, hasKeyword, @"Help output should contain 'metalwhisper' or 'Usage'");

    reportResult(name, YES, nil);
}

static void test_m8_basic(void) {
    const char *name = "test_m8_basic";
    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSString *args = [NSString stringWithFormat:@"--model \"%@\" \"%@\"", gModelPath, audioPath];

    int code = -1;
    NSString *output = runCLI(args, &code);

    NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
    ASSERT_TRUE(name, code == 0, msg);
    ASSERT_TRUE(name, output.length > 0, @"Output should not be empty");

    NSString *lower = [output lowercaseString];
    BOOL hasExpected = [lower containsString:@"americans"] ||
                       [lower containsString:@"country"] ||
                       [lower containsString:@"ask not"];
    NSString *snippet = [output substringToIndex:MIN(output.length, (NSUInteger)200)];
    msg = [NSString stringWithFormat:@"Output should contain JFK speech text, got: %@", snippet];
    ASSERT_TRUE(name, hasExpected, msg);

    reportResult(name, YES, nil);
}

static void test_m8_srt(void) {
    const char *name = "test_m8_srt";
    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSString *args = [NSString stringWithFormat:@"--model \"%@\" --output-format srt \"%@\"", gModelPath, audioPath];

    int code = -1;
    NSString *output = runCLI(args, &code);

    NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
    ASSERT_TRUE(name, code == 0, msg);

    NSString *prefix = [output substringToIndex:MIN(output.length, (NSUInteger)50)];
    msg = [NSString stringWithFormat:@"SRT should start with '1\\n', got: %@", prefix];
    ASSERT_TRUE(name, [output hasPrefix:@"1\n"], msg);
    ASSERT_TRUE(name, [output containsString:@"-->"], @"SRT should contain '-->'");
    ASSERT_TRUE(name, [output containsString:@"00:00:"], @"SRT should contain '00:00:'");

    reportResult(name, YES, nil);
}

static void test_m8_vtt(void) {
    const char *name = "test_m8_vtt";
    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSString *args = [NSString stringWithFormat:@"--model \"%@\" --output-format vtt \"%@\"", gModelPath, audioPath];

    int code = -1;
    NSString *output = runCLI(args, &code);

    NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
    ASSERT_TRUE(name, code == 0, msg);

    NSString *prefix = [output substringToIndex:MIN(output.length, (NSUInteger)50)];
    msg = [NSString stringWithFormat:@"VTT should start with 'WEBVTT', got: %@", prefix];
    ASSERT_TRUE(name, [output hasPrefix:@"WEBVTT"], msg);
    ASSERT_TRUE(name, [output containsString:@"-->"], @"VTT should contain '-->'");

    reportResult(name, YES, nil);
}

static void test_m8_json(void) {
    const char *name = "test_m8_json";
    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSString *args = [NSString stringWithFormat:@"--model \"%@\" --json \"%@\"", gModelPath, audioPath];

    int code = -1;
    NSString *output = runCLI(args, &code);

    NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
    ASSERT_TRUE(name, code == 0, msg);

    NSData *jsonData = [output dataUsingEncoding:NSUTF8StringEncoding];
    ASSERT_TRUE(name, jsonData != nil, @"Failed to convert output to data");

    NSError *parseErr = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&parseErr];
    msg = [NSString stringWithFormat:@"JSON parse failed: %@", [parseErr localizedDescription]];
    ASSERT_TRUE(name, json != nil, msg);
    ASSERT_TRUE(name, [json isKindOfClass:[NSDictionary class]], @"JSON root should be a dictionary");
    ASSERT_TRUE(name, json[@"segments"] != nil, @"JSON should have 'segments' key");
    ASSERT_TRUE(name, json[@"language"] != nil, @"JSON should have 'language' key");
    ASSERT_TRUE(name, json[@"duration"] != nil, @"JSON should have 'duration' key");

    NSArray *segs = json[@"segments"];
    ASSERT_TRUE(name, segs.count > 0, @"Should have at least one segment");

    NSDictionary *seg0 = segs[0];
    ASSERT_TRUE(name, seg0[@"text"] != nil, @"Segment should have 'text'");
    ASSERT_TRUE(name, seg0[@"start"] != nil, @"Segment should have 'start'");
    ASSERT_TRUE(name, seg0[@"end"] != nil, @"Segment should have 'end'");
    ASSERT_TRUE(name, seg0[@"tokens"] != nil, @"Segment should have 'tokens'");

    reportResult(name, YES, nil);
}

static void test_m8_exit_codes(void) {
    const char *name = "test_m8_exit_codes";

    // Test with nonexistent file
    NSString *args = [NSString stringWithFormat:@"--model \"%@\" /nonexistent/file.wav", gModelPath];

    int code = -1;
    NSString *stderrStr = nil;
    runCLIWithStderr(args, &code, &stderrStr);

    NSString *msg = [NSString stringWithFormat:@"Expected non-zero exit code, got %d", code];
    ASSERT_TRUE(name, code != 0, msg);
    ASSERT_TRUE(name, stderrStr.length > 0, @"Stderr should contain error message");

    // Test with no model
    int code2 = -1;
    NSString *stderr2 = nil;
    runCLIWithStderr(@"somefile.wav", &code2, &stderr2);
    msg = [NSString stringWithFormat:@"Expected non-zero exit for missing --model, got %d", code2];
    ASSERT_TRUE(name, code2 != 0, msg);

    reportResult(name, YES, nil);
}

static void test_m8_word_srt(void) {
    const char *name = "test_m8_word_srt";
    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSString *args = [NSString stringWithFormat:@"--model \"%@\" --word-timestamps --output-format srt \"%@\"", gModelPath, audioPath];

    int code = -1;
    NSString *output = runCLI(args, &code);

    NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
    ASSERT_TRUE(name, code == 0, msg);
    ASSERT_TRUE(name, [output containsString:@"-->"], @"Word SRT should contain '-->'");

    // Count SRT entries (lines that are just a number)
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

    msg = [NSString stringWithFormat:@"Word-level SRT should have >10 entries, got %lu", (unsigned long)entryCount];
    ASSERT_TRUE(name, entryCount > 10, msg);

    reportResult(name, YES, nil);
}

// ── Main ───────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "Usage: test_m8_cli <model_path> <data_dir> [binary_dir]\n");
            return 1;
        }

        gModelPath = [NSString stringWithUTF8String:argv[1]];
        gDataDir   = [NSString stringWithUTF8String:argv[2]];

        if (argc >= 4) {
            gBinaryDir = [NSString stringWithUTF8String:argv[3]];
        } else {
            // Derive from our own binary location
            NSString *selfPath = [NSString stringWithUTF8String:argv[0]];
            gBinaryDir = [selfPath stringByDeletingLastPathComponent];
            if (gBinaryDir.length == 0) {
                gBinaryDir = @".";
            }
        }

        fprintf(stdout, "=== M8 CLI Tests ===\n");
        fprintf(stdout, "Model:  %s\n", [gModelPath UTF8String]);
        fprintf(stdout, "Data:   %s\n", [gDataDir UTF8String]);
        fprintf(stdout, "Binary: %s\n\n", [gBinaryDir UTF8String]);

        test_m8_help();
        test_m8_basic();
        test_m8_srt();
        test_m8_vtt();
        test_m8_json();
        test_m8_exit_codes();
        test_m8_word_srt();

        fprintf(stdout, "\n=== Results: %d passed, %d failed ===\n",
            gPassCount, gFailCount);

        return gFailCount > 0 ? 1 : 0;
    }
}
