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

// ── Subprocess helper (NSTask — no shell injection) ──────────────────────

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

// ── Tests ──────────────────────────────────────────────────────────────────

static void test_m8_help(void) {
    const char *name = "test_m8_help";
    int code = -1;
    NSString *output = runCLI(@[@"--help"], &code);

    NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
    ASSERT_TRUE(name, code == 0, msg);

    BOOL hasKeyword = [output containsString:@"metalwhisper"] || [output containsString:@"Usage"];
    ASSERT_TRUE(name, hasKeyword, @"Help output should contain 'metalwhisper' or 'Usage'");

    reportResult(name, YES, nil);
}

static void test_m8_basic(void) {
    const char *name = "test_m8_basic";
    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];

    int code = -1;
    NSString *output = runCLI(@[@"--model", gModelPath, audioPath], &code);

    NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
    ASSERT_TRUE(name, code == 0, msg);
    ASSERT_TRUE(name, output.length > 0, @"Output should not be empty");

    NSString *lower = [output lowercaseString];
    BOOL hasExpected = [lower containsString:@"americans"] ||
                       [lower containsString:@"country"];
    NSString *snippet = [output substringToIndex:MIN(output.length, (NSUInteger)200)];
    msg = [NSString stringWithFormat:@"Output should contain JFK speech text, got: %@", snippet];
    ASSERT_TRUE(name, hasExpected, msg);

    reportResult(name, YES, nil);
}

static void test_m8_srt(void) {
    const char *name = "test_m8_srt";
    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];

    int code = -1;
    NSString *output = runCLI(@[@"--model", gModelPath,
                                @"--output-format", @"srt", audioPath], &code);

    NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
    ASSERT_TRUE(name, code == 0, msg);
    ASSERT_TRUE(name, [output hasPrefix:@"1\n"], @"SRT should start with '1\\n'");
    ASSERT_TRUE(name, [output containsString:@"-->"], @"SRT should contain '-->'");

    reportResult(name, YES, nil);
}

static void test_m8_vtt(void) {
    const char *name = "test_m8_vtt";
    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];

    int code = -1;
    NSString *output = runCLI(@[@"--model", gModelPath,
                                @"--output-format", @"vtt", audioPath], &code);

    NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
    ASSERT_TRUE(name, code == 0, msg);
    ASSERT_TRUE(name, [output hasPrefix:@"WEBVTT"], @"VTT should start with 'WEBVTT'");
    ASSERT_TRUE(name, [output containsString:@"-->"], @"VTT should contain '-->'");

    reportResult(name, YES, nil);
}

static void test_m8_json(void) {
    const char *name = "test_m8_json";
    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];

    int code = -1;
    NSString *output = runCLI(@[@"--model", gModelPath, @"--json", audioPath], &code);

    NSString *msg = [NSString stringWithFormat:@"Expected exit code 0, got %d", code];
    ASSERT_TRUE(name, code == 0, msg);

    NSData *jsonData = [output dataUsingEncoding:NSUTF8StringEncoding];
    ASSERT_TRUE(name, jsonData != nil, @"Failed to convert output to data");

    NSError *parseErr = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&parseErr];
    msg = [NSString stringWithFormat:@"JSON parse failed: %@", [parseErr localizedDescription]];
    ASSERT_TRUE(name, json != nil, msg);
    ASSERT_TRUE(name, json[@"segments"] != nil, @"JSON should have 'segments' key");
    ASSERT_TRUE(name, json[@"language"] != nil, @"JSON should have 'language' key");

    reportResult(name, YES, nil);
}

static void test_m8_exit_codes(void) {
    const char *name = "test_m8_exit_codes";

    // Nonexistent file
    int code = -1;
    NSString *stderrStr = nil;
    runCLICapturingStderr(@[@"--model", gModelPath, @"/nonexistent/file.wav"],
                          &code, &stderrStr);

    NSString *msg = [NSString stringWithFormat:@"Expected non-zero exit code, got %d", code];
    ASSERT_TRUE(name, code != 0, msg);
    ASSERT_TRUE(name, stderrStr.length > 0, @"Stderr should contain error message");

    // Missing --model
    int code2 = -1;
    runCLICapturingStderr(@[@"somefile.wav"], &code2, nil);
    msg = [NSString stringWithFormat:@"Expected non-zero for missing --model, got %d", code2];
    ASSERT_TRUE(name, code2 != 0, msg);

    reportResult(name, YES, nil);
}

static void test_m8_word_srt(void) {
    const char *name = "test_m8_word_srt";
    NSString *audioPath = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];

    int code = -1;
    NSString *output = runCLI(@[@"--model", gModelPath,
                                @"--word-timestamps",
                                @"--output-format", @"srt", audioPath], &code);

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

    msg = [NSString stringWithFormat:@"Word SRT should have >10 entries, got %lu",
           (unsigned long)entryCount];
    ASSERT_TRUE(name, entryCount > 10, msg);

    reportResult(name, YES, nil);
}

// ── Main ───────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);

        if (argc < 3) {
            fprintf(stderr, "Usage: test_m8_cli <model_path> <data_dir> [binary_dir]\n");
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
