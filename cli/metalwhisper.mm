// cli/metalwhisper.mm — MetalWhisper command-line tool
// Manual retain/release (-fno-objc-arc)

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "MWTranscriber.h"
#import "MWAudioDecoder.h"
#import "MWVoiceActivityDetector.h"
#import "MWModelManager.h"
#import "MWConstants.h"

#include <cstdio>
#include <cstdlib>
#include <csignal>
#include <getopt.h>
#include <sys/stat.h>
#include <unistd.h>

// ── Version ────────────────────────────────────────────────────────────────

static const char *kVersion = "0.2.2";

// ── Signal handling for temp file cleanup ─────────────────────────────────

static char gStdinTempPathBuf[1024] = {0};

static void signalHandler(int sig) {
    // unlink is async-signal-safe per POSIX (IEEE Std 1003.1-2017, Section 2.4.3).
    // _exit is also async-signal-safe.
    if (gStdinTempPathBuf[0] != '\0') {
        unlink(gStdinTempPathBuf);
    }
    _exit(128 + sig);
}

// ── Known Whisper language codes ──────────────────────────────────────────

static BOOL isKnownLanguageCode(NSString *code) {
    static NSSet<NSString *> *known = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        known = [[NSSet setWithObjects:
            @"af", @"am", @"ar", @"as", @"az", @"ba", @"be", @"bg", @"bn", @"bo",
            @"br", @"bs", @"ca", @"cs", @"cy", @"da", @"de", @"el", @"en", @"es",
            @"et", @"eu", @"fa", @"fi", @"fo", @"fr", @"gl", @"gu", @"ha", @"haw",
            @"he", @"hi", @"hr", @"ht", @"hu", @"hy", @"id", @"is", @"it", @"ja",
            @"jw", @"ka", @"kk", @"km", @"kn", @"ko", @"la", @"lb", @"ln", @"lo",
            @"lt", @"lv", @"mg", @"mi", @"mk", @"ml", @"mn", @"mr", @"ms", @"mt",
            @"my", @"ne", @"nl", @"nn", @"no", @"oc", @"pa", @"pl", @"ps", @"pt",
            @"ro", @"ru", @"sa", @"sd", @"si", @"sk", @"sl", @"sn", @"so", @"sq",
            @"sr", @"su", @"sv", @"sw", @"ta", @"te", @"tg", @"th", @"tk", @"tl",
            @"tr", @"tt", @"uk", @"ur", @"uz", @"vi", @"yi", @"yo", @"zh", @"yue",
            nil] retain];
    });
    return [known containsObject:code];
}

// ── Output format ──────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, OutputFormat) {
    OutputFormatText,
    OutputFormatSRT,
    OutputFormatVTT,
    OutputFormatJSON,
};

// ── CLI options ────────────────────────────────────────────────────────────

struct CLIOptions {
    NSString *modelPath;
    NSString *language;
    NSString *task;
    OutputFormat outputFormat;
    NSString *outputDir;
    MWComputeType computeType;
    NSUInteger beamSize;
    BOOL wordTimestamps;
    BOOL vadFilter;
    NSString *vadModelPath;
    NSString *initialPrompt;
    NSString *hotwords;
    BOOL conditionOnPreviousText;
    NSArray<NSNumber *> *temperatures;
    BOOL verbose;
    BOOL progress;
    NSMutableArray<NSString *> *inputFiles;
    BOOL readStdin;
    BOOL listModels;
    BOOL downloadOnly;
};

// ── Progress bar ───────────────────────────────────────────────────────────

// Probe audio duration (seconds) without decoding — reads container metadata.
// Returns 0 on failure, in which case the caller should fall back to a
// percentage-less progress indicator.
static double probeAudioDuration(NSURL *url) {
    AVURLAsset *asset = [AVURLAsset assetWithURL:url];
    CMTime t = asset.duration;
    if (CMTIME_IS_INVALID(t) || CMTIME_IS_INDEFINITE(t) || t.timescale == 0) {
        return 0.0;
    }
    return CMTimeGetSeconds(t);
}

// Format seconds as H:MM:SS (drops hour if zero).
static NSString *formatElapsed(double seconds) {
    if (seconds < 0.0) seconds = 0.0;
    int total = (int)(seconds + 0.5);
    int h = total / 3600;
    int m = (total % 3600) / 60;
    int s = total % 60;
    if (h > 0) return [NSString stringWithFormat:@"%d:%02d:%02d", h, m, s];
    return [NSString stringWithFormat:@"%d:%02d", m, s];
}

// Render a progress line on stderr with \r to overwrite. Only called when
// stderr is a TTY. barWidth is the number of cells in the [████░░] bar.
static void renderProgress(double processedSec, double totalSec, double startTime) {
    const int barWidth = 24;
    double now = [[NSDate date] timeIntervalSince1970];
    double elapsed = now - startTime;
    double rtf = elapsed > 0.0 ? processedSec / elapsed : 0.0;  // audio sec per wall sec

    if (totalSec > 0.0) {
        double frac = processedSec / totalSec;
        if (frac < 0.0) frac = 0.0;
        if (frac > 1.0) frac = 1.0;
        int filled = (int)(frac * barWidth + 0.5);
        char bar[64];
        int i = 0;
        bar[i++] = '[';
        for (int k = 0; k < barWidth; k++) {
            bar[i++] = (k < filled) ? '#' : '-';
        }
        bar[i++] = ']';
        bar[i] = '\0';

        // Until we have a real RTF measurement (first segment), show "--:--"
        // for ETA instead of a bogus 0:00.
        NSString *etaStr;
        NSString *rtfStr;
        if (rtf > 0.001 && processedSec > 0.0) {
            double remaining = (totalSec - processedSec) / rtf;
            etaStr = formatElapsed(remaining);
            rtfStr = [NSString stringWithFormat:@"%.1fx", rtf];
        } else {
            etaStr = @"--:--";
            rtfStr = @"--";
        }
        fprintf(stderr, "\r%s %3d%% | %s / %s | %s | elapsed %s | ETA %s\033[K",
                bar,
                (int)(frac * 100.0 + 0.5),
                [formatElapsed(processedSec) UTF8String],
                [formatElapsed(totalSec) UTF8String],
                [rtfStr UTF8String],
                [formatElapsed(elapsed) UTF8String],
                [etaStr UTF8String]);
    } else {
        // Unknown total — show elapsed audio and realtime factor.
        fprintf(stderr, "\r%s processed | %.1fx realtime\033[K",
                [formatElapsed(processedSec) UTF8String], rtf);
    }
    fflush(stderr);
}

// ── Time formatting ────────────────────────────────────────────────────────

static NSString *formatTimeSRT(float seconds) {
    if (seconds < 0.0f) seconds = 0.0f;
    int totalMs = (int)(seconds * 1000.0f + 0.5f);
    int h = totalMs / 3600000;
    int m = (totalMs % 3600000) / 60000;
    int s = (totalMs % 60000) / 1000;
    int ms = totalMs % 1000;
    return [NSString stringWithFormat:@"%02d:%02d:%02d,%03d", h, m, s, ms];
}

static NSString *formatTimeVTT(float seconds) {
    if (seconds < 0.0f) seconds = 0.0f;
    int totalMs = (int)(seconds * 1000.0f + 0.5f);
    int h = totalMs / 3600000;
    int m = (totalMs % 3600000) / 60000;
    int s = (totalMs % 60000) / 1000;
    int ms = totalMs % 1000;
    return [NSString stringWithFormat:@"%02d:%02d:%02d.%03d", h, m, s, ms];
}

// ── Output formatters ──────────────────────────────────────────────────────

static NSString *formatText(NSArray<MWTranscriptionSegment *> *segments,
                            BOOL wordTimestamps) {
    NSMutableString *out = [[NSMutableString alloc] init];
    for (MWTranscriptionSegment *seg in segments) {
        if (wordTimestamps && seg.words) {
            for (MWWord *w in seg.words) {
                NSString *word = [w.word stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
                [out appendFormat:@"[%@ --> %@] %@\n",
                    formatTimeSRT(w.start), formatTimeSRT(w.end), word];
            }
        } else {
            [out appendString:[seg.text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]]];
            [out appendString:@"\n"];
        }
    }
    NSString *result = [[out copy] autorelease];
    [out release];
    return result;
}

static NSString *formatSRT(NSArray<MWTranscriptionSegment *> *segments, BOOL wordLevel) {
    NSMutableString *out = [[NSMutableString alloc] init];
    NSUInteger index = 1;

    if (wordLevel) {
        for (MWTranscriptionSegment *seg in segments) {
            if (seg.words) {
                for (MWWord *w in seg.words) {
                    [out appendFormat:@"%lu\n", (unsigned long)index++];
                    [out appendFormat:@"%@ --> %@\n",
                        formatTimeSRT(w.start), formatTimeSRT(w.end)];
                    [out appendFormat:@"%@\n\n",
                        [w.word stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]]];
                }
            } else {
                [out appendFormat:@"%lu\n", (unsigned long)index++];
                [out appendFormat:@"%@ --> %@\n",
                    formatTimeSRT(seg.start), formatTimeSRT(seg.end)];
                [out appendFormat:@"%@\n\n",
                    [seg.text stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]]];
            }
        }
    } else {
        for (MWTranscriptionSegment *seg in segments) {
            [out appendFormat:@"%lu\n", (unsigned long)index++];
            [out appendFormat:@"%@ --> %@\n",
                formatTimeSRT(seg.start), formatTimeSRT(seg.end)];
            [out appendFormat:@"%@\n\n",
                [seg.text stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]]];
        }
    }

    NSString *result = [[out copy] autorelease];
    [out release];
    return result;
}

static NSString *formatVTT(NSArray<MWTranscriptionSegment *> *segments, BOOL wordLevel) {
    NSMutableString *out = [[NSMutableString alloc] init];
    [out appendString:@"WEBVTT\n\n"];

    if (wordLevel) {
        for (MWTranscriptionSegment *seg in segments) {
            if (seg.words) {
                for (MWWord *w in seg.words) {
                    [out appendFormat:@"%@ --> %@\n",
                        formatTimeVTT(w.start), formatTimeVTT(w.end)];
                    [out appendFormat:@"%@\n\n",
                        [w.word stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]]];
                }
            } else {
                [out appendFormat:@"%@ --> %@\n",
                    formatTimeVTT(seg.start), formatTimeVTT(seg.end)];
                [out appendFormat:@"%@\n\n",
                    [seg.text stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]]];
            }
        }
    } else {
        for (MWTranscriptionSegment *seg in segments) {
            [out appendFormat:@"%@ --> %@\n",
                formatTimeVTT(seg.start), formatTimeVTT(seg.end)];
            [out appendFormat:@"%@\n\n",
                [seg.text stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]]];
        }
    }

    NSString *result = [[out copy] autorelease];
    [out release];
    return result;
}

static NSString *formatJSON(NSArray<MWTranscriptionSegment *> *segments,
                            MWTranscriptionInfo *info,
                            BOOL wordTimestamps) {
    NSMutableArray *segArray = [[NSMutableArray alloc] init];

    for (MWTranscriptionSegment *seg in segments) {
        NSMutableDictionary *d = [[NSMutableDictionary alloc] init];
        d[@"id"] = @(seg.segmentId);
        d[@"start"] = @(seg.start);
        d[@"end"] = @(seg.end);
        d[@"text"] = [seg.text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];

        // Convert tokens to JSON-safe array
        NSMutableArray *tokArr = [[NSMutableArray alloc] initWithCapacity:seg.tokens.count];
        for (NSNumber *t in seg.tokens) {
            [tokArr addObject:t];
        }
        d[@"tokens"] = tokArr;
        [tokArr release];

        d[@"temperature"] = @(seg.temperature);
        d[@"avg_logprob"] = @(seg.avgLogProb);
        d[@"compression_ratio"] = @(seg.compressionRatio);
        d[@"no_speech_prob"] = @(seg.noSpeechProb);

        if (wordTimestamps && seg.words) {
            NSMutableArray *wordsArr = [[NSMutableArray alloc] init];
            for (MWWord *w in seg.words) {
                [wordsArr addObject:@{
                    @"word": [w.word stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]],
                    @"start": @(w.start),
                    @"end": @(w.end),
                    @"probability": @(w.probability),
                }];
            }
            d[@"words"] = wordsArr;
            [wordsArr release];
        }

        [segArray addObject:d];
        [d release];
    }

    NSDictionary *root = @{
        @"language": info ? info.language : @"unknown",
        @"language_probability": info ? @(info.languageProbability) : @(0.0),
        @"duration": info ? @(info.duration) : @(0.0),
        @"segments": segArray,
    };

    NSError *jsonErr = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:root
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&jsonErr];
    [segArray release];

    if (!jsonData) {
        return @"{}";
    }

    return [[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] autorelease];
}

// ── Help ───────────────────────────────────────────────────────────────────

static void printUsage(void) {
    fprintf(stdout,
        "Usage: metalwhisper [OPTIONS] <input_file> [input_file2 ...]\n"
        "\n"
        "Options:\n"
        "  --model <path|alias>          Model path, alias, or HF repo ID (required)\n"
        "                                Aliases: tiny, base, small, medium, large-v3, turbo, ...\n"
        "  --language <code>             Language code (default: auto-detect)\n"
        "  --task <transcribe|translate>  Task (default: transcribe)\n"
        "  --output-format <text|srt|vtt|json>  Output format (default: text)\n"
        "  --output-dir <dir>            Write output files to directory\n"
        "  --compute-type <type>         Compute type: auto, float32, float16, int8,\n"
        "                                int8_float16, int8_float32 (default: auto)\n"
        "  --beam-size <n>               Beam size (default: 6)\n"
        "  --word-timestamps             Enable word-level timestamps\n"
        "  --vad-filter                  Enable voice activity detection\n"
        "  --vad-model <path>            Path to Silero VAD ONNX model\n"
        "  --initial-prompt <text>       Initial prompt text\n"
        "  --hotwords <text>             Hotwords to bias toward\n"
        "  --no-condition-on-previous-text  Disable conditioning on previous text\n"
        "                                (default: conditioning is ON)\n"
        "  --temperature <t1,t2,...>     Temperature(s) for fallback\n"
        "                                (default: 0.0,0.6)\n"
        "  --json                        Shorthand for --output-format json\n"
        "  --verbose                     Show per-segment output and timing on stderr\n"
        "  --progress                    Show a progress bar on stderr (TTY only)\n"
        "  --list-models                 List available model aliases\n"
        "  --download                    Download model without transcribing\n"
        "  --help                        Show help\n"
        "  --version                     Show version\n"
        "  -                             Read audio from stdin (WAV format)\n"
    );
}

// ── Argument parsing ───────────────────────────────────────────────────────

static NSArray<NSNumber *> *parseTemperatures(const char *str) {
    NSString *s = [NSString stringWithUTF8String:str];
    NSArray<NSString *> *parts = [s componentsSeparatedByString:@","];
    NSMutableArray<NSNumber *> *temps = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *part in parts) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length > 0) {
            // Validate it's a number: scanner check
            NSScanner *scanner = [NSScanner scannerWithString:trimmed];
            float val = 0.0f;
            if ([scanner scanFloat:&val] && [scanner isAtEnd]) {
                if (val < 0.0f) {
                    fprintf(stderr, "Warning: Negative temperature %.2f clamped to 0.0\n", val);
                    val = 0.0f;
                }
                [temps addObject:@(val)];
            } else {
                fprintf(stderr, "Warning: Ignoring non-numeric temperature value '%s'\n",
                        [trimmed UTF8String]);
            }
        }
    }
    if (temps.count == 0) {
        fprintf(stderr, "Warning: No valid temperatures parsed, using default 0.0\n");
        [temps addObject:@(0.0f)];
    }
    return temps;
}

static MWComputeType parseComputeType(const char *str) {
    NSString *s = [[NSString stringWithUTF8String:str] lowercaseString];
    if ([s isEqualToString:@"float32"] || [s isEqualToString:@"f32"]) {
        return MWComputeTypeFloat32;
    } else if ([s isEqualToString:@"float16"] || [s isEqualToString:@"f16"]) {
        return MWComputeTypeFloat16;
    } else if ([s isEqualToString:@"int8"]) {
        return MWComputeTypeInt8;
    } else if ([s isEqualToString:@"int8_float16"] || [s isEqualToString:@"int8_f16"]) {
        return MWComputeTypeInt8Float16;
    } else if ([s isEqualToString:@"int8_float32"] || [s isEqualToString:@"int8_f32"]) {
        return MWComputeTypeInt8Float32;
    }
    return MWComputeTypeDefault;
}

static OutputFormat parseOutputFormat(const char *str) {
    NSString *s = [[NSString stringWithUTF8String:str] lowercaseString];
    if ([s isEqualToString:@"srt"]) return OutputFormatSRT;
    if ([s isEqualToString:@"vtt"]) return OutputFormatVTT;
    if ([s isEqualToString:@"json"]) return OutputFormatJSON;
    if ([s isEqualToString:@"text"] || [s isEqualToString:@"txt"]) return OutputFormatText;
    fprintf(stderr, "Warning: Unknown output format '%s', using text\n", str);
    return OutputFormatText;
}

static BOOL parseArgs(int argc, const char *argv[], CLIOptions *opts) {
    // Defaults
    opts->modelPath = nil;
    opts->language = nil;
    opts->task = @"transcribe";
    opts->outputFormat = OutputFormatText;
    opts->outputDir = nil;
    opts->computeType = MWComputeTypeDefault;
    opts->beamSize = 6;
    opts->wordTimestamps = NO;
    opts->vadFilter = NO;
    opts->vadModelPath = nil;
    opts->initialPrompt = nil;
    opts->hotwords = nil;
    opts->conditionOnPreviousText = YES;
    opts->temperatures = @[@(0.0f), @(0.6f)];
    opts->verbose = NO;
    opts->progress = NO;
    opts->inputFiles = [NSMutableArray array];
    opts->readStdin = NO;
    opts->listModels = NO;
    opts->downloadOnly = NO;

    int i = 1;
    while (i < argc) {
        const char *arg = argv[i];

        if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
            printUsage();
            exit(0);
        }
        if (strcmp(arg, "--version") == 0) {
            fprintf(stdout, "metalwhisper %s\n", kVersion);
            exit(0);
        }

        // Flags with values
        if (strcmp(arg, "--model") == 0) {
            if (++i >= argc) { fprintf(stderr, "Error: --model requires a value\n"); return NO; }
            opts->modelPath = [NSString stringWithUTF8String:argv[i]];
        } else if (strcmp(arg, "--language") == 0) {
            if (++i >= argc) { fprintf(stderr, "Error: --language requires a value\n"); return NO; }
            opts->language = [NSString stringWithUTF8String:argv[i]];
        } else if (strcmp(arg, "--task") == 0) {
            if (++i >= argc) { fprintf(stderr, "Error: --task requires a value\n"); return NO; }
            opts->task = [NSString stringWithUTF8String:argv[i]];
        } else if (strcmp(arg, "--output-format") == 0) {
            if (++i >= argc) { fprintf(stderr, "Error: --output-format requires a value\n"); return NO; }
            opts->outputFormat = parseOutputFormat(argv[i]);
        } else if (strcmp(arg, "--output-dir") == 0) {
            if (++i >= argc) { fprintf(stderr, "Error: --output-dir requires a value\n"); return NO; }
            opts->outputDir = [NSString stringWithUTF8String:argv[i]];
        } else if (strcmp(arg, "--compute-type") == 0) {
            if (++i >= argc) { fprintf(stderr, "Error: --compute-type requires a value\n"); return NO; }
            opts->computeType = parseComputeType(argv[i]);
        } else if (strcmp(arg, "--beam-size") == 0) {
            if (++i >= argc) { fprintf(stderr, "Error: --beam-size requires a value\n"); return NO; }
            {
                char *endptr = NULL;
                long val = strtol(argv[i], &endptr, 10);
                if (endptr == argv[i] || *endptr != '\0') {
                    fprintf(stderr, "Error: --beam-size requires a numeric value\n");
                    return NO;
                }
                if (val < 1 || val > 100) {
                    fprintf(stderr, "Error: --beam-size must be between 1 and 100\n");
                    return NO;
                }
                opts->beamSize = (NSUInteger)val;
            }
        } else if (strcmp(arg, "--vad-model") == 0) {
            if (++i >= argc) { fprintf(stderr, "Error: --vad-model requires a value\n"); return NO; }
            opts->vadModelPath = [NSString stringWithUTF8String:argv[i]];
        } else if (strcmp(arg, "--initial-prompt") == 0) {
            if (++i >= argc) { fprintf(stderr, "Error: --initial-prompt requires a value\n"); return NO; }
            opts->initialPrompt = [NSString stringWithUTF8String:argv[i]];
        } else if (strcmp(arg, "--hotwords") == 0) {
            if (++i >= argc) { fprintf(stderr, "Error: --hotwords requires a value\n"); return NO; }
            opts->hotwords = [NSString stringWithUTF8String:argv[i]];
        } else if (strcmp(arg, "--temperature") == 0) {
            if (++i >= argc) { fprintf(stderr, "Error: --temperature requires a value\n"); return NO; }
            opts->temperatures = parseTemperatures(argv[i]);
        }
        // Boolean flags
        else if (strcmp(arg, "--word-timestamps") == 0) {
            opts->wordTimestamps = YES;
        } else if (strcmp(arg, "--vad-filter") == 0) {
            opts->vadFilter = YES;
        } else if (strcmp(arg, "--condition-on-previous-text") == 0) {
            opts->conditionOnPreviousText = YES;  // explicit re-enable (for scripts)
        } else if (strcmp(arg, "--no-condition-on-previous-text") == 0) {
            opts->conditionOnPreviousText = NO;
        } else if (strcmp(arg, "--json") == 0) {
            opts->outputFormat = OutputFormatJSON;
        } else if (strcmp(arg, "--verbose") == 0) {
            opts->verbose = YES;
        } else if (strcmp(arg, "--progress") == 0) {
            opts->progress = YES;
        } else if (strcmp(arg, "--list-models") == 0) {
            opts->listModels = YES;
        } else if (strcmp(arg, "--download") == 0) {
            opts->downloadOnly = YES;
        }
        // Stdin marker
        else if (strcmp(arg, "-") == 0) {
            opts->readStdin = YES;
        }
        // Positional: input file
        else if (arg[0] == '-' && arg[1] != '\0') {
            fprintf(stderr, "Error: Unknown option: %s\n", arg);
            return NO;
        } else {
            [opts->inputFiles addObject:[NSString stringWithUTF8String:arg]];
        }

        i++;
    }

    return YES;
}

// ── Stdin reading ──────────────────────────────────────────────────────────

static const NSUInteger kMaxStdinBytes = 2UL * 1024 * 1024 * 1024; // 2 GB

static NSString *readStdinToTempFile(void) {
    NSMutableData *data = [[NSMutableData alloc] init];
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), stdin)) > 0) {
        [data appendBytes:buf length:n];
        if (data.length > kMaxStdinBytes) {
            fprintf(stderr, "Error: Stdin input exceeds 2 GB limit\n");
            [data release];
            return nil;
        }
    }
    if (data.length == 0) {
        [data release];
        return nil;
    }

    NSString *tmpPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"metalwhisper_stdin_%d_%@.wav",
                getpid(), [[NSUUID UUID] UUIDString]]];
    BOOL ok = [data writeToFile:tmpPath atomically:YES];
    [data release];
    return ok ? tmpPath : nil;
}

// ── Output extension ───────────────────────────────────────────────────────

static NSString *extensionForFormat(OutputFormat fmt) {
    switch (fmt) {
        case OutputFormatSRT:  return @"srt";
        case OutputFormatVTT:  return @"vtt";
        case OutputFormatJSON: return @"json";
        default:               return @"txt";
    }
}

// ── Main ───────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Line-buffered stdout
        setvbuf(stdout, NULL, _IOLBF, 0);

        if (argc < 2) {
            printUsage();
            return 1;
        }

        CLIOptions opts;
        if (!parseArgs(argc, argv, &opts)) {
            return 1;
        }

        // Handle --list-models
        if (opts.listModels) {
            NSArray<NSString *> *models = [MWModelManager availableModels];
            fprintf(stdout, "Available model aliases:\n");
            for (NSString *alias in models) {
                NSString *repoID = [MWModelManager repoIDForAlias:alias];
                fprintf(stdout, "  %-20s  %s\n", [alias UTF8String], [repoID UTF8String]);
            }

            // Also list cached models
            MWModelManager *mgr = [MWModelManager shared];
            NSArray<NSDictionary *> *cached = [mgr listCachedModels];
            if (cached.count > 0) {
                fprintf(stdout, "\nCached models:\n");
                for (NSDictionary *m in cached) {
                    unsigned long long sizeBytes = [m[@"sizeBytes"] unsignedLongLongValue];
                    double sizeMB = (double)sizeBytes / (1024.0 * 1024.0);
                    fprintf(stdout, "  %-30s  %.1f MB\n",
                            [m[@"name"] UTF8String], sizeMB);
                }
            }
            return 0;
        }

        // Validate --task
        if (![opts.task isEqualToString:@"transcribe"] &&
            ![opts.task isEqualToString:@"translate"]) {
            fprintf(stderr, "Error: --task must be 'transcribe' or 'translate'\n");
            return 1;
        }

        // Validate --language
        if (opts.language && !isKnownLanguageCode(opts.language)) {
            fprintf(stderr, "Warning: Unknown language code '%s'. "
                    "See https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes\n",
                    [opts.language UTF8String]);
            // Continue anyway — the transcriber may handle it or auto-detect will override
        }

        // Validate --vad-filter requires --vad-model
        if (opts.vadFilter && !opts.vadModelPath) {
            fprintf(stderr, "Error: --vad-filter requires --vad-model <path>\n");
            return 1;
        }

        // Handle stdin
        NSString *stdinTempPath = nil;
        if (opts.readStdin) {
            stdinTempPath = readStdinToTempFile();
            if (!stdinTempPath) {
                fprintf(stderr, "Error: Failed to read audio from stdin\n");
                return 1;
            }
            [opts.inputFiles addObject:stdinTempPath];
            // Register signal handlers to clean up temp file on interrupt
            strlcpy(gStdinTempPathBuf, [stdinTempPath UTF8String], sizeof(gStdinTempPathBuf));
            signal(SIGINT, signalHandler);
            signal(SIGTERM, signalHandler);
        }

        // Validate required args
        if (!opts.modelPath) {
            fprintf(stderr, "Error: --model is required\n\n");
            printUsage();
            return 1;
        }
        if (!opts.downloadOnly && opts.inputFiles.count == 0) {
            fprintf(stderr, "Error: No input files specified\n\n");
            printUsage();
            return 1;
        }

        // Resolve model path via MWModelManager (supports aliases, repo IDs, local paths)
        {
            MWModelManager *mgr = [MWModelManager shared];
            NSError *resolveError = nil;
            MWDownloadProgressBlock progressBlock = nil;
            if (opts.verbose) {
                progressBlock = ^(int64_t bytesDownloaded, int64_t totalBytes, NSString *fileName) {
                    if (totalBytes > 0) {
                        double pct = (double)bytesDownloaded / (double)totalBytes * 100.0;
                        fprintf(stderr, "\rDownloading %s: %.1f%% (%.1f / %.1f MB)",
                                [fileName UTF8String], pct,
                                (double)bytesDownloaded / (1024.0 * 1024.0),
                                (double)totalBytes / (1024.0 * 1024.0));
                    } else {
                        fprintf(stderr, "\rDownloading %s: %.1f MB",
                                [fileName UTF8String],
                                (double)bytesDownloaded / (1024.0 * 1024.0));
                    }
                };
            }

            NSString *resolvedPath = [mgr resolveModel:opts.modelPath
                                              progress:progressBlock
                                                 error:&resolveError];
            if (!resolvedPath) {
                fprintf(stderr, "Error: %s\n",
                        [[resolveError localizedDescription] UTF8String]);
                return 1;
            }

            if (opts.verbose && ![resolvedPath isEqualToString:opts.modelPath]) {
                fprintf(stderr, "\nModel resolved to: %s\n", [resolvedPath UTF8String]);
            }

            opts.modelPath = resolvedPath;
        }

        // Handle --download (download only, no transcription)
        if (opts.downloadOnly) {
            fprintf(stdout, "Model ready at: %s\n", [opts.modelPath UTF8String]);
            return 0;
        }

        // Create output dir if needed
        if (opts.outputDir) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSError *dirErr = nil;
            if (![fm createDirectoryAtPath:opts.outputDir
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:&dirErr]) {
                fprintf(stderr, "Error: Cannot create output directory: %s\n",
                    [[dirErr localizedDescription] UTF8String]);
                return 1;
            }
        }

        // Load model
        if (opts.verbose) {
            fprintf(stderr, "Loading model from %s...\n", [opts.modelPath UTF8String]);
        }

        NSError *error = nil;
        MWTranscriber *transcriber = [[MWTranscriber alloc] initWithModelPath:opts.modelPath
                                                                  computeType:opts.computeType
                                                                        error:&error];
        if (!transcriber) {
            fprintf(stderr, "Error: Failed to load model: %s\n",
                [[error localizedDescription] UTF8String]);
            return 1;
        }

        if (opts.verbose) {
            fprintf(stderr, "Model loaded. Multilingual: %s, Mels: %lu\n",
                transcriber.isMultilingual ? "yes" : "no",
                (unsigned long)transcriber.nMels);
        }

        // Build options dictionary
        NSMutableDictionary *transcribeOpts = [[NSMutableDictionary alloc] init];
        transcribeOpts[@"beamSize"] = @(opts.beamSize);
        transcribeOpts[@"wordTimestamps"] = @(opts.wordTimestamps);
        transcribeOpts[@"conditionOnPreviousText"] = @(opts.conditionOnPreviousText);
        transcribeOpts[@"temperatures"] = opts.temperatures;

        if (opts.initialPrompt) {
            transcribeOpts[@"initialPrompt"] = opts.initialPrompt;
        }
        if (opts.hotwords) {
            transcribeOpts[@"hotwords"] = opts.hotwords;
        }
        if (opts.vadFilter && opts.vadModelPath) {
            transcribeOpts[@"vadModelPath"] = opts.vadModelPath;
        }

        int exitCode = 0;
        BOOL multiFileJSON = (!opts.outputDir &&
                              opts.outputFormat == OutputFormatJSON &&
                              opts.inputFiles.count > 1);
        if (multiFileJSON) {
            fprintf(stdout, "[\n");
        }

        // Process each file
        for (NSUInteger fi = 0; fi < opts.inputFiles.count; fi++) {
            NSString *inputPath = opts.inputFiles[fi];

            // Check file exists
            if (![[NSFileManager defaultManager] fileExistsAtPath:inputPath]) {
                fprintf(stderr, "Error: File not found: %s\n", [inputPath UTF8String]);
                exitCode = 1;
                continue;
            }

            if (opts.verbose) {
                fprintf(stderr, "Processing: %s\n", [inputPath UTF8String]);
            }

            NSURL *inputURL = [NSURL fileURLWithPath:inputPath];
            MWTranscriptionInfo *info = nil;
            NSError *transcribeError = nil;
            NSArray<MWTranscriptionSegment *> *segments = nil;

            // Progress bar only renders when stderr is a TTY — avoids spamming
            // control codes into log files, CI output, etc.
            BOOL progressActive = opts.progress && isatty(fileno(stderr));
            double progressTotal = progressActive ? probeAudioDuration(inputURL) : 0.0;
            double progressStart = [[NSDate date] timeIntervalSince1970];

            // Serial queue for all progress output so the segmentHandler
            // (transcriber thread) and the ticker timer don't interleave
            // writes to stderr.
            dispatch_queue_t progressQueue = NULL;
            dispatch_source_t progressTimer = NULL;
            __block double lastProcessedSec = 0.0;

            if (progressActive) {
                // Draw an initial 0% bar immediately so the user sees the bar
                // before any segments arrive (model setup + first-chunk decode
                // can take several seconds).
                renderProgress(0.0, progressTotal, progressStart);

                progressQueue = dispatch_queue_create("mw.cli.progress", DISPATCH_QUEUE_SERIAL);
                progressTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, progressQueue);
                // Tick every 200 ms — keeps elapsed/ETA/RTF live between segments.
                dispatch_source_set_timer(progressTimer,
                    dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                    200 * NSEC_PER_MSEC,
                    50 * NSEC_PER_MSEC);  // 50ms leeway
                dispatch_source_set_event_handler(progressTimer, ^{
                    renderProgress(lastProcessedSec, progressTotal, progressStart);
                });
                dispatch_resume(progressTimer);
            }

            // Segment handler: --verbose prints each segment; --progress draws
            // a live bar keyed off the latest seg.end. Both can be active.
            void (^segHandler)(MWTranscriptionSegment *, BOOL *) = nil;
            if (opts.verbose || progressActive) {
                segHandler = ^(MWTranscriptionSegment *seg, BOOL *stop) {
                    if (opts.verbose) {
                        // Serialize the verbose line with the ticker so the
                        // bar doesn't interleave with segment text.
                        if (progressActive) {
                            dispatch_sync(progressQueue, ^{
                                fprintf(stderr, "\r\033[K[%s --> %s] %s\n",
                                    [formatTimeSRT(seg.start) UTF8String],
                                    [formatTimeSRT(seg.end) UTF8String],
                                    [[seg.text stringByTrimmingCharactersInSet:
                                        [NSCharacterSet whitespaceCharacterSet]] UTF8String]);
                            });
                        } else {
                            fprintf(stderr, "[%s --> %s] %s\n",
                                [formatTimeSRT(seg.start) UTF8String],
                                [formatTimeSRT(seg.end) UTF8String],
                                [[seg.text stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceCharacterSet]] UTF8String]);
                        }
                    }
                    if (progressActive) {
                        // Advance the shared counter; the timer will pick it up
                        // on its next tick. Also render immediately so the jump
                        // doesn't wait for the next tick.
                        lastProcessedSec = seg.end;
                        dispatch_async(progressQueue, ^{
                            renderProgress(lastProcessedSec, progressTotal, progressStart);
                        });
                    }
                };
            }

            if (opts.vadFilter) {
                segments = [transcriber transcribeBatchedURL:inputURL
                                                   language:opts.language
                                                       task:opts.task
                                                  batchSize:8
                                                    options:transcribeOpts
                                             segmentHandler:segHandler
                                                       info:&info
                                                      error:&transcribeError];
            } else {
                segments = [transcriber transcribeURL:inputURL
                                            language:opts.language
                                                task:opts.task
                                             options:transcribeOpts
                                      segmentHandler:segHandler
                                                info:&info
                                               error:&transcribeError];
            }

            // Finalize the progress line with a newline so subsequent output
            // (error messages, verbose info, actual transcription) isn't
            // overwritten by lingering \r behavior.
            if (progressActive) {
                // Stop the ticker and drain any pending renders before the
                // final line, so the timer can't race with our completion draw.
                if (progressTimer) {
                    dispatch_source_cancel(progressTimer);
                    dispatch_sync(progressQueue, ^{ /* barrier */ });
                    dispatch_release(progressTimer);
                    progressTimer = NULL;
                }
                if (segments) {
                    renderProgress(progressTotal, progressTotal, progressStart);
                }
                fprintf(stderr, "\n");
                if (progressQueue) {
                    dispatch_release(progressQueue);
                    progressQueue = NULL;
                }
            }

            if (!segments) {
                fprintf(stderr, "Error: Transcription failed for %s: %s\n",
                    [inputPath UTF8String],
                    [[transcribeError localizedDescription] UTF8String]);
                exitCode = 1;
                continue;
            }

            if (opts.verbose && info) {
                fprintf(stderr, "Detected language: %s (probability: %.2f)\n",
                    [info.language UTF8String], info.languageProbability);
                fprintf(stderr, "Duration: %.1f seconds, %lu segments\n",
                    info.duration, (unsigned long)segments.count);
            }

            // Format output
            NSString *output = nil;
            switch (opts.outputFormat) {
                case OutputFormatText:
                    output = formatText(segments, opts.wordTimestamps);
                    break;
                case OutputFormatSRT:
                    output = formatSRT(segments, opts.wordTimestamps);
                    break;
                case OutputFormatVTT:
                    output = formatVTT(segments, opts.wordTimestamps);
                    break;
                case OutputFormatJSON:
                    output = formatJSON(segments, info, opts.wordTimestamps);
                    break;
            }

            // Write output
            if (opts.outputDir) {
                NSString *baseName = [[inputPath lastPathComponent]
                    stringByDeletingPathExtension];
                NSString *ext = extensionForFormat(opts.outputFormat);
                NSString *outPath = [[opts.outputDir
                    stringByAppendingPathComponent:baseName]
                    stringByAppendingPathExtension:ext];

                NSError *writeError = nil;
                BOOL wrote = [output writeToFile:outPath
                                      atomically:YES
                                        encoding:NSUTF8StringEncoding
                                           error:&writeError];
                if (!wrote) {
                    fprintf(stderr, "Error: Failed to write %s: %s\n",
                        [outPath UTF8String],
                        [[writeError localizedDescription] UTF8String]);
                    exitCode = 1;
                } else if (opts.verbose) {
                    fprintf(stderr, "Wrote: %s\n", [outPath UTF8String]);
                }
            } else {
                fprintf(stdout, "%s", [output UTF8String]);
                if (multiFileJSON && fi + 1 < opts.inputFiles.count) {
                    fprintf(stdout, ",\n");
                }
            }
        }

        if (multiFileJSON) {
            fprintf(stdout, "\n]\n");
        }

        // Cleanup
        [transcribeOpts release];
        [transcriber release];

        if (stdinTempPath) {
            [[NSFileManager defaultManager] removeItemAtPath:stdinTempPath error:nil];
        }

        return exitCode;
    }
}
