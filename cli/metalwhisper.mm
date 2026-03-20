// cli/metalwhisper.mm — MetalWhisper command-line tool
// Manual retain/release (-fno-objc-arc)

#import <Foundation/Foundation.h>
#import "MWTranscriber.h"
#import "MWAudioDecoder.h"
#import "MWVoiceActivityDetector.h"
#import "MWConstants.h"

#include <cstdio>
#include <cstdlib>
#include <csignal>
#include <getopt.h>
#include <sys/stat.h>
#include <unistd.h>

// ── Version ────────────────────────────────────────────────────────────────

static const char *kVersion = "0.1.0";

// ── Signal handling for temp file cleanup ─────────────────────────────────

static char gStdinTempPathBuf[1024] = {0};

static void signalHandler(int sig) {
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
    NSMutableArray<NSString *> *inputFiles;
    BOOL readStdin;
};

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

static NSString *formatText(NSArray<MWTranscriptionSegment *> *segments) {
    NSMutableString *out = [[NSMutableString alloc] init];
    for (MWTranscriptionSegment *seg in segments) {
        [out appendString:[seg.text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]]];
        [out appendString:@"\n"];
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
        "  --model <path>                Model directory path (required)\n"
        "  --language <code>             Language code (default: auto-detect)\n"
        "  --task <transcribe|translate>  Task (default: transcribe)\n"
        "  --output-format <text|srt|vtt|json>  Output format (default: text)\n"
        "  --output-dir <dir>            Write output files to directory\n"
        "  --compute-type <type>         Compute type: auto, float32, float16, int8,\n"
        "                                int8_float16, int8_float32 (default: auto)\n"
        "  --beam-size <n>               Beam size (default: 5)\n"
        "  --word-timestamps             Enable word-level timestamps\n"
        "  --vad-filter                  Enable voice activity detection\n"
        "  --vad-model <path>            Path to Silero VAD ONNX model\n"
        "  --initial-prompt <text>       Initial prompt text\n"
        "  --hotwords <text>             Hotwords to bias toward\n"
        "  --no-condition-on-previous-text  Disable conditioning on previous text\n"
        "                                (default: conditioning is ON)\n"
        "  --temperature <t1,t2,...>     Temperature(s) for fallback\n"
        "                                (default: 0.0,0.2,0.4,0.6,0.8,1.0)\n"
        "  --json                        Shorthand for --output-format json\n"
        "  --verbose                     Show progress and timing info on stderr\n"
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
    opts->beamSize = 5;
    opts->wordTimestamps = NO;
    opts->vadFilter = NO;
    opts->vadModelPath = nil;
    opts->initialPrompt = nil;
    opts->hotwords = nil;
    opts->conditionOnPreviousText = YES;
    opts->temperatures = @[@(0.0f), @(0.2f), @(0.4f), @(0.6f), @(0.8f), @(1.0f)];
    opts->verbose = NO;
    opts->inputFiles = [NSMutableArray array];
    opts->readStdin = NO;

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
                long val = strtol(argv[i], NULL, 10);
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
        if (opts.inputFiles.count == 0) {
            fprintf(stderr, "Error: No input files specified\n\n");
            printUsage();
            return 1;
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

            // Segment handler for verbose progress
            void (^segHandler)(MWTranscriptionSegment *, BOOL *) = nil;
            if (opts.verbose) {
                segHandler = ^(MWTranscriptionSegment *seg, BOOL *stop) {
                    fprintf(stderr, "[%s --> %s] %s\n",
                        [formatTimeSRT(seg.start) UTF8String],
                        [formatTimeSRT(seg.end) UTF8String],
                        [[seg.text stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]] UTF8String]);
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
                    output = formatText(segments);
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
