#import <Foundation/Foundation.h>
#import "MWTokenizer.h"
#import "MWTestCommon.h"

// ── Test-local state ────────────────────────────────────────────────────────

static NSString *gModelPath = nil;

// ── Reference data loading ───────────────────────────────────────────────────

static NSDictionary *loadReferenceJSON(NSString *path) {
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

// ── Helper: compare arrays ───────────────────────────────────────────────────

static BOOL arraysEqual(NSArray<NSNumber *> *a, NSArray<NSNumber *> *b) {
    if ([a count] != [b count]) return NO;
    for (NSUInteger i = 0; i < [a count]; ++i) {
        if (![a[i] isEqualToNumber:b[i]]) return NO;
    }
    return YES;
}

// ── Tests ────────────────────────────────────────────────────────────────────

static void test_m3_load_vocab(MWTokenizer *tok, NSDictionary *ref) {
    NSUInteger expected = [ref[@"vocab_size"] unsignedIntegerValue];
    NSUInteger actual = [tok vocabSize];
    BOOL pass = (actual == expected);
    reportResult("test_m3_load_vocab",
                 pass,
                 [NSString stringWithFormat:@"expected %lu, got %lu",
                  (unsigned long)expected, (unsigned long)actual]);
}

static void test_m3_encode(MWTokenizer *tok, NSDictionary *ref) {
    NSDictionary *encodeRef = ref[@"encode"];
    BOOL allPass = YES;
    NSMutableString *failures = [[NSMutableString alloc] init];

    for (NSString *text in encodeRef) {
        NSArray<NSNumber *> *expected = encodeRef[text];
        NSArray<NSNumber *> *actual = [tok encode:text];

        if (!arraysEqual(expected, actual)) {
            allPass = NO;
            [failures appendFormat:@"\n    '%@': expected %@ got %@", text, expected, actual];
        }
    }

    reportResult("test_m3_encode", allPass, failures);
    [failures release];
}

static void test_m3_decode(MWTokenizer *tok, NSDictionary *ref) {
    NSDictionary *decodeRef = ref[@"decode"];
    BOOL allPass = YES;
    NSMutableString *failures = [[NSMutableString alloc] init];

    for (NSString *name in decodeRef) {
        NSDictionary *entry = decodeRef[name];
        NSArray<NSNumber *> *ids = entry[@"ids"];
        NSString *expected = entry[@"text"];
        NSString *actual = [tok decode:ids];

        if (![expected isEqualToString:actual]) {
            allPass = NO;
            [failures appendFormat:@"\n    '%@': expected '%@' got '%@'", name, expected, actual];
        }
    }

    reportResult("test_m3_decode", allPass, failures);
    [failures release];
}

static void test_m3_special_tokens(MWTokenizer *tok, NSDictionary *ref) {
    NSDictionary *special = ref[@"special_tokens"];
    BOOL allPass = YES;
    NSMutableString *failures = [[NSMutableString alloc] init];

    auto check = [&](const char *name, NSUInteger actual, NSUInteger expected) {
        if (actual != expected) {
            allPass = NO;
            [failures appendFormat:@"\n    %s: expected %lu got %lu",
             name, (unsigned long)expected, (unsigned long)actual];
        }
    };

    check("sot", [tok sot], [special[@"sot"] unsignedIntegerValue]);
    check("eot", [tok eot], [special[@"eot"] unsignedIntegerValue]);
    check("transcribe", [tok transcribeToken], [special[@"transcribe"] unsignedIntegerValue]);
    check("translate", [tok translateToken], [special[@"translate"] unsignedIntegerValue]);
    check("sot_lm", [tok sotLM], [special[@"sot_lm"] unsignedIntegerValue]);
    check("sot_prev", [tok sotPrev], [special[@"sot_prev"] unsignedIntegerValue]);
    check("no_speech", [tok noSpeech], [special[@"no_speech"] unsignedIntegerValue]);
    check("no_timestamps", [tok noTimestamps], [special[@"no_timestamps"] unsignedIntegerValue]);
    check("timestamp_begin", [tok timestampBegin], [special[@"timestamp_begin"] unsignedIntegerValue]);

    reportResult("test_m3_special_tokens", allPass, failures);
    [failures release];
}

static void test_m3_sot_sequence(MWTokenizer *tok, NSDictionary *ref) {
    NSArray<NSNumber *> *expected = ref[@"sot_sequence_en_transcribe"];
    NSArray<NSNumber *> *actual = [tok sotSequence];
    BOOL pass = arraysEqual(expected, actual);
    reportResult("test_m3_sot_sequence",
                 pass,
                 [NSString stringWithFormat:@"expected %@ got %@", expected, actual]);
}

static void test_m3_non_speech_tokens(MWTokenizer *tok, NSDictionary *ref) {
    NSArray<NSNumber *> *expected = ref[@"non_speech_tokens"];
    NSArray<NSNumber *> *actual = [tok nonSpeechTokens];

    // Compare as sets since order may differ
    NSSet<NSNumber *> *expectedSet = [NSSet setWithArray:expected];
    NSSet<NSNumber *> *actualSet = [NSSet setWithArray:actual];

    // Check that all expected tokens are present
    NSMutableSet<NSNumber *> *missing = [expectedSet mutableCopy];
    [missing minusSet:actualSet];

    NSMutableSet<NSNumber *> *extra = [actualSet mutableCopy];
    [extra minusSet:expectedSet];

    BOOL pass = ([missing count] == 0);
    NSString *detail = [NSString stringWithFormat:
        @"expected %lu tokens, got %lu. missing: %lu, extra: %lu. Missing: %@",
        (unsigned long)[expected count], (unsigned long)[actual count],
        (unsigned long)[missing count], (unsigned long)[extra count],
        missing];

    reportResult("test_m3_non_speech_tokens", pass, detail);
    [missing release];
    [extra release];
}

static void test_m3_word_split_english(MWTokenizer *tok, NSDictionary *ref) {
    NSDictionary *splitRef = ref[@"word_split_english"];
    NSArray<NSNumber *> *inputIDs = splitRef[@"input_ids"];
    NSArray<NSString *> *expectedWords = splitRef[@"words"];
    NSArray<NSArray<NSNumber *> *> *expectedTokens = splitRef[@"word_tokens"];

    NSArray<NSString *> *words = nil;
    NSArray<NSArray<NSNumber *> *> *wordTokens = nil;
    [tok splitToWordTokens:inputIDs words:&words wordTokens:&wordTokens];

    BOOL wordsMatch = [expectedWords isEqualToArray:words];
    BOOL tokensMatch = [expectedTokens isEqualToArray:wordTokens];

    BOOL pass = wordsMatch && tokensMatch;
    NSString *detail = @"";
    if (!pass) {
        detail = [NSString stringWithFormat:
            @"words match: %@, tokens match: %@\n    expected words: %@\n    got words: %@\n    expected tokens: %@\n    got tokens: %@",
            wordsMatch ? @"YES" : @"NO",
            tokensMatch ? @"YES" : @"NO",
            expectedWords, words,
            expectedTokens, wordTokens];
    }
    reportResult("test_m3_word_split_english", pass, detail);
}

static void test_m3_word_split_cjk(NSDictionary *ref) {
    // Create a CJK-language tokenizer using the global model path
    if (!gModelPath) {
        reportResult("test_m3_word_split_cjk", NO, @"model path not set");
        return;
    }
    NSString *modelPath = gModelPath;

    NSError *error = nil;
    MWTokenizer *jaTok = [[MWTokenizer alloc] initWithModelPath:modelPath
                                                    multilingual:YES
                                                            task:@"transcribe"
                                                        language:@"ja"
                                                           error:&error];
    if (!jaTok) {
        reportResult("test_m3_word_split_cjk", NO,
                     [NSString stringWithFormat:@"Failed to load ja tokenizer: %@",
                      [error localizedDescription]]);
        return;
    }

    NSDictionary *splitRef = ref[@"word_split_cjk"];
    NSArray<NSNumber *> *inputIDs = splitRef[@"input_ids"];
    NSArray<NSString *> *expectedWords = splitRef[@"words"];
    NSArray<NSArray<NSNumber *> *> *expectedTokens = splitRef[@"word_tokens"];

    NSArray<NSString *> *words = nil;
    NSArray<NSArray<NSNumber *> *> *wordTokens = nil;
    [jaTok splitToWordTokens:inputIDs words:&words wordTokens:&wordTokens];

    BOOL wordsMatch = [expectedWords isEqualToArray:words];
    BOOL tokensMatch = [expectedTokens isEqualToArray:wordTokens];

    BOOL pass = wordsMatch && tokensMatch;
    NSString *detail = @"";
    if (!pass) {
        detail = [NSString stringWithFormat:
            @"words match: %@, tokens match: %@\n    expected words: %@\n    got words: %@\n    expected tokens: %@\n    got tokens: %@",
            wordsMatch ? @"YES" : @"NO",
            tokensMatch ? @"YES" : @"NO",
            expectedWords, words,
            expectedTokens, wordTokens];
    }
    reportResult("test_m3_word_split_cjk", pass, detail);
    [jaTok release];
}

static void test_m3_roundtrip(MWTokenizer *tok, NSDictionary *ref) {
    NSDictionary *roundtripRef = ref[@"roundtrip"];
    BOOL allPass = YES;
    NSMutableString *failures = [[NSMutableString alloc] init];

    for (NSString *text in roundtripRef) {
        NSDictionary *entry = roundtripRef[text];
        NSArray<NSNumber *> *expectedIDs = entry[@"ids"];
        NSString *expectedDecoded = entry[@"decoded"];

        // Encode
        NSArray<NSNumber *> *actualIDs = [tok encode:text];
        if (!arraysEqual(expectedIDs, actualIDs)) {
            allPass = NO;
            [failures appendFormat:@"\n    encode '%@': expected %@ got %@",
             text, expectedIDs, actualIDs];
            continue;
        }

        // Decode
        NSString *actualDecoded = [tok decode:actualIDs];
        if (![expectedDecoded isEqualToString:actualDecoded]) {
            allPass = NO;
            [failures appendFormat:@"\n    decode '%@': expected '%@' got '%@'",
             text, expectedDecoded, actualDecoded];
        }
    }

    reportResult("test_m3_roundtrip", allPass, failures);
    [failures release];
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        fprintf(stdout, "=== M3 Tokenizer Tests ===\n\n");

        // Resolve model path
        NSString *modelPath = nil;
        if (argc > 1) {
            modelPath = [NSString stringWithUTF8String:argv[1]];
        } else {
            const char *envPath = getenv("MW_MODEL_PATH");
            if (envPath) {
                modelPath = [NSString stringWithUTF8String:envPath];
            }
        }

        if (!modelPath) {
            fprintf(stderr, "Usage: %s <model_path>\n"
                    "  Or set MW_MODEL_PATH environment variable.\n", argv[0]);
            return 1;
        }
        gModelPath = modelPath;

        // Resolve reference data path
        NSString *refPath = nil;
        if (argc > 2) {
            refPath = [NSString stringWithUTF8String:argv[2]];
        } else {
            const char *envRef = getenv("MW_REFERENCE_PATH");
            if (envRef) {
                refPath = [NSString stringWithUTF8String:envRef];
            } else {
                // Default: relative to executable
                NSString *execDir = [[[NSProcessInfo processInfo] arguments][0] stringByDeletingLastPathComponent];
                // Try project-relative path
                refPath = [execDir stringByAppendingPathComponent:
                    @"../tests/data/reference/tokenizer_reference.json"];
                if (![[NSFileManager defaultManager] fileExistsAtPath:refPath]) {
                    // Try source-tree path
                    refPath = @"tests/data/reference/tokenizer_reference.json";
                }
            }
        }

        fprintf(stdout, "Model path: %s\n", [modelPath UTF8String]);
        fprintf(stdout, "Reference:  %s\n\n", [refPath UTF8String]);

        // Load reference data
        NSDictionary *ref = loadReferenceJSON(refPath);
        if (!ref) {
            fprintf(stderr, "ERROR: Failed to load reference data from: %s\n", [refPath UTF8String]);
            return 1;
        }

        // Load tokenizer (English, multilingual, transcribe)
        fprintf(stdout, "Loading tokenizer...\n");
        NSError *error = nil;
        MWTokenizer *tok = [[MWTokenizer alloc] initWithModelPath:modelPath
                                                      multilingual:YES
                                                              task:@"transcribe"
                                                          language:@"en"
                                                             error:&error];
        if (!tok) {
            fprintf(stderr, "ERROR: Failed to load tokenizer: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
        }

        fprintf(stdout, "Tokenizer loaded. Vocab size: %lu\n\n", (unsigned long)[tok vocabSize]);

        // Run tests
        test_m3_load_vocab(tok, ref);
        test_m3_encode(tok, ref);
        test_m3_decode(tok, ref);
        test_m3_special_tokens(tok, ref);
        test_m3_sot_sequence(tok, ref);
        test_m3_non_speech_tokens(tok, ref);
        test_m3_word_split_english(tok, ref);
        test_m3_word_split_cjk(ref);
        test_m3_roundtrip(tok, ref);

        [tok release];

        // Summary
        fprintf(stdout, "\n=== Results: %d passed, %d failed ===\n",
                gPassCount, gFailCount);
        return (gFailCount > 0) ? 1 : 0;
    }
}
