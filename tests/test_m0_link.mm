#import <Foundation/Foundation.h>
#import "MWTranscriber.h"

/// M0 link test: load a Whisper model on Metal, print properties, encode silence.
///
/// Usage:
///   test_m0_link <model_path>
///   MW_MODEL_PATH=/path/to/model test_m0_link
int main(int argc, const char* argv[]) {
    @autoreleasepool {
        // Ensure stdout is line-buffered so output appears immediately.
        setvbuf(stdout, NULL, _IOLBF, 0);

        // Resolve model path from argument or environment variable.
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
            fprintf(stderr,
                    "Usage: %s <model_path>\n"
                    "   or: MW_MODEL_PATH=/path/to/model %s\n",
                    argv[0], argv[0]);
            return 1;
        }

        fprintf(stdout, "=== MetalWhisper M0 Link Test ===\n");
        fprintf(stdout, "Model path: %s\n", [modelPath UTF8String]);

        // 1. Load the model.
        NSError *error = nil;
        MWTranscriber *transcriber = [[MWTranscriber alloc] initWithModelPath:modelPath
                                                                        error:&error];
        if (!transcriber) {
            fprintf(stderr, "FAIL: Model load failed: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
        }

        fprintf(stdout, "OK: Model loaded successfully.\n");

        // 2. Print model properties.
        fprintf(stdout, "  isMultilingual: %s\n",
                transcriber.isMultilingual ? "YES" : "NO");
        fprintf(stdout, "  nMels:          %lu\n",
                (unsigned long)transcriber.nMels);

        // 3. Run the silence encode test.
        fprintf(stdout, "Running encode silence test...\n");
        NSString *shape = [transcriber encodeSilenceTestWithError:&error];
        if (!shape) {
            fprintf(stderr, "FAIL: Encode silence failed: %s\n",
                    [[error localizedDescription] UTF8String]);
            [transcriber release];
            return 1;
        }

        fprintf(stdout, "OK: Encoder output shape: %s\n", [shape UTF8String]);

        // 4. Cleanup.
        [transcriber release];

        fprintf(stdout, "=== M0 Link Test PASSED ===\n");
        return 0;
    }
}
