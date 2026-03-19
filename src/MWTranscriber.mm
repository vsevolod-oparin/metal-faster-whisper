#import "MWTranscriber.h"
#import "MWConstants.h"

#include <memory>
#include <string>

#include <ctranslate2/models/whisper.h>
#include <ctranslate2/storage_view.h>
#include <ctranslate2/devices.h>
#include <ctranslate2/types.h>

NSErrorDomain const MWErrorDomain = @"com.metalwhisper.error";

static ctranslate2::ComputeType mwComputeTypeToCT2(MWComputeType type) {
    switch (type) {
        case MWComputeTypeFloat32:     return ctranslate2::ComputeType::FLOAT32;
        case MWComputeTypeFloat16:     return ctranslate2::ComputeType::FLOAT16;
        case MWComputeTypeInt8:        return ctranslate2::ComputeType::INT8;
        case MWComputeTypeInt8Float16: return ctranslate2::ComputeType::INT8_FLOAT16;
        case MWComputeTypeInt8Float32: return ctranslate2::ComputeType::INT8_FLOAT32;
        case MWComputeTypeDefault:
        default:                       return ctranslate2::ComputeType::DEFAULT;
    }
}

// ── Private ivar block ──────────────────────────────────────────────────────
@implementation MWTranscriber {
    std::unique_ptr<ctranslate2::models::Whisper> _whisper;
}

// ── Initializers ────────────────────────────────────────────────────────────
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                     error:(NSError **)error {
    return [self initWithModelPath:modelPath
                       computeType:MWComputeTypeDefault
                             error:error];
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                               computeType:(MWComputeType)computeType
                                     error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    try {
        const std::string path = [modelPath UTF8String];
        const auto ct2Type = mwComputeTypeToCT2(computeType);

        _whisper = std::make_unique<ctranslate2::models::Whisper>(
            path,
            ctranslate2::Device::MPS,
            ct2Type,
            std::vector<int>{0},
            false
        );

        NSLog(@"[MetalWhisper] Model loaded: multilingual=%d  n_mels=%zu  compute_type=%s",
              self.isMultilingual, (size_t)self.nMels,
              ctranslate2::compute_type_to_str(ct2Type).c_str());

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

// ── Properties ──────────────────────────────────────────────────────────────
- (BOOL)isMultilingual {
    return _whisper->is_multilingual() ? YES : NO;
}

- (NSUInteger)nMels {
    return static_cast<NSUInteger>(_whisper->n_mels());
}

// ── Silence encode test ─────────────────────────────────────────────────────
- (nullable NSString *)encodeSilenceTestWithError:(NSError **)error {
    try {
        const auto n_mels = static_cast<ctranslate2::dim_t>(_whisper->n_mels());

        // Zero-filled mel spectrogram: [1, n_mels, chunk_frames] (30s of silence).
        ctranslate2::StorageView features(
            {1, n_mels, kMWDefaultChunkFrames},
            0.0f,
            ctranslate2::Device::CPU
        );

        auto future = _whisper->encode(features, /*to_cpu=*/true);
        ctranslate2::StorageView output = future.get();

        // Build shape string using std::string (RAII — no leak on exception).
        const auto& shape = output.shape();
        std::string shapeStr = "[";
        for (size_t i = 0; i < shape.size(); ++i) {
            if (i > 0) shapeStr += ", ";
            shapeStr += std::to_string(shape[i]);
        }
        shapeStr += "]";

        return [NSString stringWithUTF8String:shapeStr.c_str()];

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
