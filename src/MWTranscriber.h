#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for MetalWhisper errors.
extern NSErrorDomain const MWErrorDomain;

/// Error codes for MetalWhisper operations.
typedef NS_ENUM(NSInteger, MWErrorCode) {
    MWErrorCodeModelLoadFailed = 1,
    MWErrorCodeEncodeFailed    = 2,
    MWErrorCodeAudioDecodeFailed = 100,
    MWErrorCodeAudioFileNotFound = 101,
    MWErrorCodeAudioTempFileFailed = 102,
};

/// Compute type for model inference.
typedef NS_ENUM(NSInteger, MWComputeType) {
    MWComputeTypeDefault = 0,
    MWComputeTypeFloat32,
    MWComputeTypeFloat16,
    MWComputeTypeInt8,
    MWComputeTypeInt8Float16,
    MWComputeTypeInt8Float32,
};

/// Minimal M0 transcriber: loads a CTranslate2 Whisper model on Metal (MPS)
/// and exposes basic model properties and a smoke-test encode method.
@interface MWTranscriber : NSObject

/// Initialize with a CTranslate2 model directory path and default compute type.
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                     error:(NSError **)error;

/// Initialize with a CTranslate2 model directory path and explicit compute type.
/// This is the designated initializer.
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                               computeType:(MWComputeType)computeType
                                     error:(NSError **)error NS_DESIGNATED_INITIALIZER;

/// Unavailable — use initWithModelPath:error: or initWithModelPath:computeType:error:.
- (instancetype)init NS_UNAVAILABLE;

/// Whether the loaded model is multilingual (supports language detection).
@property (nonatomic, readonly) BOOL isMultilingual;

/// Number of mel frequency bins expected by the model (80 or 128).
@property (nonatomic, readonly) NSUInteger nMels;

/// Quick test: encode 30s of silence, return output shape as a string
/// (e.g. "[1, 1500, 512]"). Returns nil and sets *error on failure.
- (nullable NSString *)encodeSilenceTestWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
