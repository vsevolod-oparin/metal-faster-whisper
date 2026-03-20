// tests/test_m9_model_manager.mm -- Model downloading and caching tests
// Usage: test_m9_model_manager <model_path> <data_dir>
// Set MW_SKIP_NETWORK_TESTS=0 to run network-dependent tests
// Manual retain/release (-fno-objc-arc)

#import <Foundation/Foundation.h>
#import "MWTestCommon.h"
#import "MWModelManager.h"
#import "MWTranscriber.h"

#include <cstdio>
#include <cstdlib>

// ── Globals ────────────────────────────────────────────────────────────────

static NSString *gModelPath = nil;
static NSString *gDataDir   = nil;

// Helper to avoid macro comma issues with NSString stringWithFormat
#define FMT1(fmt, a)       [NSString stringWithFormat:(fmt), (a)]
#define FMT2(fmt, a, b)    [NSString stringWithFormat:(fmt), (a), (b)]
#define FMT3(fmt, a, b, c) [NSString stringWithFormat:(fmt), (a), (b), (c)]

// ── Test: availableModels returns all expected aliases ──────────────────────

static void test_m9_available_models(void) {
    @autoreleasepool {
        const char *name = "m9_available_models";

        NSArray<NSString *> *models = [MWModelManager availableModels];

        NSString *msg = FMT1(@"Expected >= 18 aliases, got %lu", (unsigned long)models.count);
        ASSERT_TRUE(name, models.count >= 18, msg);

        // Verify specific aliases are present
        NSSet<NSString *> *modelSet = [NSSet setWithArray:models];
        NSArray<NSString *> *expected = @[
            @"tiny", @"tiny.en", @"base", @"base.en",
            @"small", @"small.en", @"medium", @"medium.en",
            @"large-v1", @"large-v2", @"large-v3", @"large",
            @"distil-large-v2", @"distil-medium.en", @"distil-small.en", @"distil-large-v3",
            @"large-v3-turbo", @"turbo",
        ];

        for (NSString *alias in expected) {
            NSString *detail = FMT1(@"Missing alias: %@", alias);
            ASSERT_TRUE(name, [modelSet containsObject:alias], detail);
        }

        reportResult(name, YES, nil);
    }
}

// ── Test: repoIDForAlias lookups ───────────────────────────────────────────

static void test_m9_repo_id_lookup(void) {
    @autoreleasepool {
        const char *name = "m9_repo_id_lookup";

        NSDictionary<NSString *, NSString *> *checks = @{
            @"tiny"          : @"Systran/faster-whisper-tiny",
            @"tiny.en"       : @"Systran/faster-whisper-tiny.en",
            @"large-v3"      : @"Systran/faster-whisper-large-v3",
            @"large"         : @"Systran/faster-whisper-large-v3",
            @"turbo"         : @"mobiuslabsgmbh/faster-whisper-large-v3-turbo",
            @"large-v3-turbo": @"mobiuslabsgmbh/faster-whisper-large-v3-turbo",
            @"distil-large-v3": @"Systran/faster-distil-whisper-large-v3",
        };

        for (NSString *alias in checks) {
            NSString *expected = checks[alias];
            NSString *actual = [MWModelManager repoIDForAlias:alias];
            NSString *detail = FMT3(@"For '%@': expected '%@', got '%@'",
                                    alias, expected, actual ?: @"nil");
            ASSERT_TRUE(name, [actual isEqualToString:expected], detail);
        }

        // Unknown alias returns nil
        NSString *unknown = [MWModelManager repoIDForAlias:@"nonexistent"];
        NSString *unknownMsg = FMT1(@"Expected nil for unknown alias, got '%@'", unknown);
        ASSERT_TRUE(name, unknown == nil, unknownMsg);

        reportResult(name, YES, nil);
    }
}

// ── Test: local path passthrough ───────────────────────────────────────────

static void test_m9_local_path(void) {
    @autoreleasepool {
        const char *name = "m9_local_path";

        MWModelManager *mgr = [MWModelManager shared];
        NSError *error = nil;

        // gModelPath should be a valid local model directory
        NSString *resolved = [mgr resolveModel:gModelPath progress:nil error:&error];

        NSString *failMsg = FMT1(@"resolveModel failed: %@",
                                 error ? [error localizedDescription] : @"nil");
        ASSERT_TRUE(name, resolved != nil, failMsg);

        NSString *matchMsg = FMT2(@"Expected '%@', got '%@'", gModelPath, resolved);
        ASSERT_TRUE(name, [resolved isEqualToString:gModelPath], matchMsg);

        reportResult(name, YES, nil);
    }
}

// ── Test: default cache directory ──────────────────────────────────────────

static void test_m9_cache_directory(void) {
    @autoreleasepool {
        const char *name = "m9_cache_directory";

        MWModelManager *mgr = [MWModelManager shared];
        NSString *cacheDir = mgr.cacheDirectory;

        ASSERT_TRUE(name, cacheDir != nil, @"cacheDirectory is nil");

        NSString *cachesMsg = FMT1(@"Expected cache dir under Library/Caches, got: %@", cacheDir);
        ASSERT_TRUE(name, [cacheDir containsString:@"Library/Caches"], cachesMsg);

        NSString *mwMsg = FMT1(@"Expected 'MetalWhisper' in path, got: %@", cacheDir);
        ASSERT_TRUE(name, [cacheDir containsString:@"MetalWhisper"], mwMsg);

        reportResult(name, YES, nil);
    }
}

// ── Test: list cached models ───────────────────────────────────────────────

static void test_m9_list_cached(void) {
    @autoreleasepool {
        const char *name = "m9_list_cached";

        MWModelManager *mgr = [MWModelManager shared];
        NSArray<NSDictionary *> *cached = [mgr listCachedModels];

        // Result is an array (may be empty if nothing cached)
        ASSERT_TRUE(name, cached != nil, @"listCachedModels returned nil");

        // If there are cached models, verify structure
        for (NSDictionary *entry in cached) {
            ASSERT_TRUE(name, entry[@"name"] != nil, @"Missing 'name' key");
            ASSERT_TRUE(name, entry[@"path"] != nil, @"Missing 'path' key");
            ASSERT_TRUE(name, entry[@"sizeBytes"] != nil, @"Missing 'sizeBytes' key");
        }

        reportResult(name, YES, nil);
    }
}

// ── Test: isModelCached ────────────────────────────────────────────────────

static void test_m9_is_cached(void) {
    @autoreleasepool {
        const char *name = "m9_is_cached";

        MWModelManager *mgr = [MWModelManager shared];

        // Local model path should be recognized as "cached" (local override)
        BOOL isCached = [mgr isModelCached:gModelPath];
        NSString *cachedMsg = FMT1(@"Expected local path '%@' to be recognized", gModelPath);
        ASSERT_TRUE(name, isCached, cachedMsg);

        // Unknown alias should not be cached
        BOOL unknownCached = [mgr isModelCached:@"nonexistent-model-xyz"];
        ASSERT_TRUE(name, !unknownCached, @"Expected unknown model to not be cached");

        reportResult(name, YES, nil);
    }
}

// ── Test: unknown model error ──────────────────────────────────────────────

static void test_m9_unknown_model_error(void) {
    @autoreleasepool {
        const char *name = "m9_unknown_model_error";

        MWModelManager *mgr = [MWModelManager shared];
        NSError *error = nil;
        NSString *result = [mgr resolveModel:@"nonexistent-model" progress:nil error:&error];

        ASSERT_TRUE(name, result == nil, @"Expected nil for unknown model");
        ASSERT_TRUE(name, error != nil, @"Expected error for unknown model");

        NSString *errMsg = FMT1(@"Unexpected error: %@", [error localizedDescription]);
        ASSERT_TRUE(name, [[error localizedDescription] containsString:@"Unknown model"], errMsg);

        reportResult(name, YES, nil);
    }
}

// ── Test: repo ID injection rejected ────────────────────────────────────────

static void test_m9_repo_id_injection(void) {
    @autoreleasepool {
        const char *name = "m9_repo_id_injection";

        MWModelManager *mgr = [MWModelManager shared];

        // These should all be rejected — invalid repo ID format
        NSArray<NSString *> *malicious = @[
            @"../../etc/passwd",
            @"owner/repo/../../evil",
            @"owner repo",
            @"owner/repo name with spaces",
            @"owner/<script>alert(1)</script>",
            @"/absolute/path/with/slash",
            @"owner/repo?query=1",
            @"owner/repo#fragment",
            @"owner/repo%00null",
        ];

        for (NSString *badID in malicious) {
            NSError *error = nil;
            NSString *result = [mgr resolveModel:badID progress:nil error:&error];
            if (result != nil) {
                NSString *msg = FMT1(@"Expected nil for malicious repo ID '%@'", badID);
                ASSERT_TRUE(name, NO, msg);
                return;
            }
            if (error == nil) {
                NSString *msg = FMT1(@"Expected error for malicious repo ID '%@'", badID);
                ASSERT_TRUE(name, NO, msg);
                return;
            }
        }

        // These should be accepted — valid repo ID format
        NSArray<NSString *> *valid = @[
            @"Systran/faster-whisper-tiny",
            @"mobiuslabsgmbh/faster-whisper-large-v3-turbo",
            @"user123/model_name.v2",
            @"org-name/model-name",
        ];

        for (NSString *goodID in valid) {
            NSError *error = nil;
            // resolveModel will fail (model not cached/downloadable) but should NOT
            // fail with "Invalid repo ID format" — it should get past the validation
            NSString *result = [mgr resolveModel:goodID progress:nil error:&error];
            if (error && [[error localizedDescription] containsString:@"Invalid repo ID"]) {
                NSString *msg = FMT1(@"Valid repo ID '%@' was rejected", goodID);
                ASSERT_TRUE(name, NO, msg);
                return;
            }
        }

        reportResult(name, YES, nil);
    }
}

// ── Test: delete non-existent cached model ─────────────────────────────────

static void test_m9_delete_nonexistent(void) {
    @autoreleasepool {
        const char *name = "m9_delete_nonexistent";

        MWModelManager *mgr = [MWModelManager shared];
        NSError *error = nil;

        // Deleting a valid alias that isn't cached should succeed (nothing to delete)
        BOOL result = [mgr deleteCachedModel:@"tiny" error:&error];
        // This may succeed (nothing to delete) or the directory may not exist
        // Either way, it should not crash
        (void)result;
        (void)error;

        reportResult(name, YES, nil);
    }
}

// ── Test: custom cache directory ───────────────────────────────────────────

static void test_m9_custom_cache_dir(void) {
    @autoreleasepool {
        const char *name = "m9_custom_cache_dir";

        MWModelManager *mgr = [[MWModelManager alloc] init];
        NSString *customDir = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"mw_test_cache"];
        mgr.cacheDirectory = customDir;

        NSString *detail = FMT2(@"Expected '%@', got '%@'", customDir, mgr.cacheDirectory);
        ASSERT_TRUE(name, [mgr.cacheDirectory isEqualToString:customDir], detail);

        [mgr release];
        reportResult(name, YES, nil);
    }
}

// ── NETWORK TEST: Download tiny model ──────────────────────────────────────

static void test_m9_download_tiny(void) {
    @autoreleasepool {
        const char *name = "m9_download_tiny";

        // Check skip flag
        const char *skipEnv = getenv("MW_SKIP_NETWORK_TESTS");
        if (!skipEnv || strcmp(skipEnv, "0") != 0) {
            fprintf(stdout, "  SKIP: %s (set MW_SKIP_NETWORK_TESTS=0 to run)\n", name);
            return;
        }

        fprintf(stdout, "  Running network test (downloading tiny model)...\n");

        // Use a temporary cache directory to avoid polluting the real cache
        MWModelManager *mgr = [[MWModelManager alloc] init];
        NSString *tmpCache = [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                FMT1(@"mw_test_%@", [[NSUUID UUID] UUIDString])];
        mgr.cacheDirectory = tmpCache;

        __block int64_t lastBytes = 0;
        MWDownloadProgressBlock progress = ^(int64_t bytesDownloaded, int64_t totalBytes,
                                             NSString *fileName) {
            if (bytesDownloaded - lastBytes > 5 * 1024 * 1024) {
                fprintf(stderr, "  [%s] %.1f MB downloaded\n",
                        [fileName UTF8String],
                        (double)bytesDownloaded / (1024.0 * 1024.0));
                lastBytes = bytesDownloaded;
            }
        };

        NSError *error = nil;
        NSString *modelPath = [mgr resolveModel:@"tiny" progress:progress error:&error];

        NSString *dlMsg = FMT1(@"Download failed: %@",
                                error ? [error localizedDescription] : @"unknown error");
        ASSERT_TRUE(name, modelPath != nil, dlMsg);

        // Verify all required files
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *requiredFiles = @[
            @"model.bin", @"tokenizer.json", @"config.json", @"preprocessor_config.json"
        ];
        for (NSString *file in requiredFiles) {
            NSString *filePath = [modelPath stringByAppendingPathComponent:file];
            NSString *fileMsg = FMT1(@"Missing required file: %@", file);
            ASSERT_TRUE(name, [fm fileExistsAtPath:filePath], fileMsg);
        }

        // Check vocabulary
        NSString *vocabJson = [modelPath stringByAppendingPathComponent:@"vocabulary.json"];
        NSString *vocabTxt = [modelPath stringByAppendingPathComponent:@"vocabulary.txt"];
        BOOL hasVocab = [fm fileExistsAtPath:vocabJson] || [fm fileExistsAtPath:vocabTxt];
        ASSERT_TRUE(name, hasVocab, @"Missing vocabulary file (json or txt)");

        // Verify model loads
        NSError *loadError = nil;
        MWTranscriber *transcriber = [[MWTranscriber alloc] initWithModelPath:modelPath
                                                                  computeType:MWComputeTypeDefault
                                                                        error:&loadError];
        NSString *loadMsg = FMT1(@"Model load failed: %@",
                                  loadError ? [loadError localizedDescription] : @"unknown");
        ASSERT_TRUE(name, transcriber != nil, loadMsg);
        [transcriber release];

        // Verify isModelCached returns YES
        ASSERT_TRUE(name, [mgr isModelCached:@"tiny"],
                    @"isModelCached should return YES after download");

        // Verify listCachedModels includes it
        NSArray<NSDictionary *> *cached = [mgr listCachedModels];
        ASSERT_TRUE(name, cached.count >= 1, @"listCachedModels should have >= 1 entry");

        // Clean up
        [[NSFileManager defaultManager] removeItemAtPath:tmpCache error:nil];
        [mgr release];

        reportResult(name, YES, nil);
    }
}

// ── Main ───────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "Usage: test_m9_model_manager <model_path> <data_dir>\n");
            return 1;
        }

        gModelPath = [NSString stringWithUTF8String:argv[1]];
        gDataDir   = [NSString stringWithUTF8String:argv[2]];

        fprintf(stdout, "=== M9 Model Manager Tests ===\n");
        fprintf(stdout, "Model path: %s\n", [gModelPath UTF8String]);
        fprintf(stdout, "Data dir:   %s\n\n", [gDataDir UTF8String]);

        // Offline tests (no network required)
        test_m9_available_models();
        test_m9_repo_id_lookup();
        test_m9_local_path();
        test_m9_cache_directory();
        test_m9_list_cached();
        test_m9_is_cached();
        test_m9_unknown_model_error();
        test_m9_repo_id_injection();
        test_m9_delete_nonexistent();
        test_m9_custom_cache_dir();

        // Network test (skipped by default)
        test_m9_download_tiny();

        fprintf(stdout, "\n=== Results: %d passed, %d failed ===\n", gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
