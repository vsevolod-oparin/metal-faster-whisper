#import "MWTranscriber.h"

#include <memory>
#include <string>

#include <ctranslate2/models/whisper.h>
#include <ctranslate2/storage_view.h>
#include <ctranslate2/devices.h>
#include <ctranslate2/types.h>

NSErrorDomain const MWErrorDomain = @"com.metalwhisper.error";

// ── Private ivar block ──────────────────────────────────────────────────────
@implementation MWTranscriber {
    // Thread-safe replica pool that owns the model and a worker thread.
    std::unique_ptr<ctranslate2::models::Whisper> _whisper;
}

// ── Initializer ─────────────────────────────────────────────────────────────
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                     error:(NSError **)error {
    @autoreleasepool {
        self = [super init];
        if (!self) return nil;

        try {
            const std::string path = [modelPath UTF8String];

            // Create the Whisper replica pool on the MPS (Metal) device.
            // Uses default compute type and a single device index.
            _whisper = std::make_unique<ctranslate2::models::Whisper>(
                path,
                ctranslate2::Device::MPS,
                ctranslate2::ComputeType::DEFAULT,
                std::vector<int>{0},       // device_indices
                false                       // tensor_parallel
            );

            NSLog(@"[MetalWhisper] Model loaded: multilingual=%d  n_mels=%zu",
                  self.isMultilingual, (size_t)self.nMels);

        } catch (const std::exception& e) {
            if (error) {
                *error = [NSError errorWithDomain:MWErrorDomain
                                             code:MWErrorCodeModelLoadFailed
                                         userInfo:@{
                    NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"Failed to load model: %s", e.what()]
                }];
            }
            [self release];
            return nil;
        }

        return self;
    }
}

// ── Properties ──────────────────────────────────────────────────────────────
- (BOOL)isMultilingual {
    return _whisper->is_multilingual() ? YES : NO;
}

- (NSUInteger)nMels {
    return static_cast<NSUInteger>(_whisper->n_mels());
}

// ── Silence encode test ─────────────────────────────────────────────────────
- (nullable NSString *)encodeSilenceTestWithError:(NSError **)error {
    // Do NOT wrap the body in @autoreleasepool: the returned NSString is
    // autoreleased and must survive until the *caller's* pool drains.
    try {
        const size_t n_mels = _whisper->n_mels();

        // Create a zero-filled StorageView of shape [1, n_mels, 3000]
        // representing 30 seconds of silence as a mel spectrogram.
        ctranslate2::StorageView features(
            {1, static_cast<ctranslate2::dim_t>(n_mels), 3000},
            0.0f,
            ctranslate2::Device::CPU
        );

        // Encode via the replica pool (returns a future).
        auto future = _whisper->encode(features, /*to_cpu=*/true);
        ctranslate2::StorageView output = future.get();

        // Format the output shape as a string.
        const auto& shape = output.shape();
        NSMutableString *shapeStr = [[NSMutableString alloc] initWithString:@"["];
        for (size_t i = 0; i < shape.size(); ++i) {
            if (i > 0) [shapeStr appendString:@", "];
            [shapeStr appendFormat:@"%lld", (long long)shape[i]];
        }
        [shapeStr appendString:@"]"];

        NSString *result = [[shapeStr copy] autorelease];
        [shapeStr release];
        return result;

    } catch (const std::exception& e) {
        if (error) {
            *error = [NSError errorWithDomain:MWErrorDomain
                                         code:MWErrorCodeEncodeFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Encode failed: %s", e.what()]
            }];
        }
        return nil;
    }
}

// ── Manual memory management (no ARC) ───────────────────────────────────────
- (void)dealloc {
    _whisper.reset();
    [super dealloc];
}

@end
