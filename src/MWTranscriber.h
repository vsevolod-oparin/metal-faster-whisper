#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for MetalWhisper errors.
extern NSErrorDomain const MWErrorDomain;

/// Error codes for MetalWhisper operations.
typedef NS_ENUM(NSInteger, MWErrorCode) {
    MWErrorCodeModelLoadFailed = 1,
    MWErrorCodeEncodeFailed    = 2,
};

/// Minimal M0 transcriber: loads a CTranslate2 Whisper model on Metal (MPS)
/// and exposes basic model properties and a smoke-test encode method.
@interface MWTranscriber : NSObject

/// Initialize with a CTranslate2 model directory path.
/// The directory must contain model.bin, vocabulary.json, etc.
/// Returns nil and sets *error on failure.
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                     error:(NSError **)error;

/// Whether the loaded model is multilingual (supports language detection).
@property (nonatomic, readonly) BOOL isMultilingual;

/// Number of mel frequency bins expected by the model (80 or 128).
@property (nonatomic, readonly) NSUInteger nMels;

/// Quick test: encode 30s of silence, return output shape as a string
/// (e.g. "[1, 1500, 512]"). Returns nil and sets *error on failure.
- (nullable NSString *)encodeSilenceTestWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
