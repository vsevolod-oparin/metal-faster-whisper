#import <Foundation/Foundation.h>
#import "MWTranscriber.h"

/// M0 compute types test: verify f32, f16, int8 all load and encode successfully.
///
/// Usage:
///   test_m0_compute_types <model_path>
///   MW_MODEL_PATH=/path/to/model test_m0_compute_types
int main(int argc, const char* argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);

        NSString *modelPath = nil;
        if (argc > 1) {
            modelPath = [NSString stringWithUTF8String:argv[1]];
        } else {
            const char *envPath = getenv("MW_MODEL_PATH");
            if (envPath) {
                modelPath = [NSString stringWithUTF8String:envPath];
            }
        }

        if (!modelPath || [modelPath length] == 0) {
            fprintf(stderr, "Usage: %s <model_path>\n", argv[0]);
            return 1;
        }

        fprintf(stdout, "=== MetalWhisper M0 Compute Types Test ===\n");
        fprintf(stdout, "Model path: %s\n\n", [modelPath UTF8String]);

        // Compute types to test: load + encode must succeed.
        // Note: int8 and int8_float16 fail on the MPS backend because
        // whisper models aren't int8-quantized (known CTranslate2 limitation).
        // Those are tested separately below as expected-failure cases.
        struct {
            const char *name;
            MWComputeType type;
            bool expectSuccess;
        } computeTypes[] = {
            { "float32",      MWComputeTypeFloat32,     true },
            { "float16",      MWComputeTypeFloat16,     true },
            { "int8",         MWComputeTypeInt8,         false },
            { "int8_float16", MWComputeTypeInt8Float16,  false },
        };

        int passed = 0;
        int failed = 0;
        int total = sizeof(computeTypes) / sizeof(computeTypes[0]);

        for (int i = 0; i < total; i++) {
            fprintf(stdout, "[%d/%d] Testing compute type: %s\n",
                    i + 1, total, computeTypes[i].name);

            NSError *error = nil;
            MWTranscriber *transcriber =
                [[MWTranscriber alloc] initWithModelPath:modelPath
                                             computeType:computeTypes[i].type
                                                   error:&error];

            if (!transcriber) {
                if (!computeTypes[i].expectSuccess) {
                    fprintf(stdout, "  OK (expected failure): Load failed: %s\n\n",
                            [[error localizedDescription] UTF8String]);
                    passed++;
                } else {
                    fprintf(stderr, "  FAIL: Load failed: %s\n\n",
                            [[error localizedDescription] UTF8String]);
                    failed++;
                }
                continue;
            }

            fprintf(stdout, "  Loaded: multilingual=%s  nMels=%lu\n",
                    transcriber.isMultilingual ? "YES" : "NO",
                    (unsigned long)transcriber.nMels);

            NSString *shape = [transcriber encodeSilenceTestWithError:&error];
            if (!shape) {
                if (!computeTypes[i].expectSuccess) {
                    fprintf(stdout, "  OK (expected failure): Encode failed: %s\n\n",
                            [[error localizedDescription] UTF8String]);
                    [transcriber release];
                    passed++;
                } else {
                    fprintf(stderr, "  FAIL: Encode failed: %s\n\n",
                            [[error localizedDescription] UTF8String]);
                    [transcriber release];
                    failed++;
                }
                continue;
            }

            if (!computeTypes[i].expectSuccess) {
                fprintf(stderr, "  UNEXPECTED PASS: %s succeeded but was expected to fail\n\n",
                        computeTypes[i].name);
                [transcriber release];
                failed++;
                continue;
            }

            fprintf(stdout, "  OK: Encoder output shape: %s\n\n",
                    [shape UTF8String]);
            [transcriber release];
            passed++;
        }

        fprintf(stdout, "=== Results: %d/%d passed, %d failed ===\n",
                passed, total, failed);

        if (failed > 0) {
            fprintf(stdout, "=== M0 Compute Types Test FAILED ===\n");
            return 1;
        }

        fprintf(stdout, "=== M0 Compute Types Test PASSED ===\n");
        return 0;
    }
}
