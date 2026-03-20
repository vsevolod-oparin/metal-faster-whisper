// src/MWModelManager.h -- Model downloading and caching for MetalWhisper
// Manual retain/release (-fno-objc-arc)

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Progress callback for model downloads.
/// @param bytesDownloaded Bytes downloaded so far
/// @param totalBytes Total expected bytes (-1 if unknown)
/// @param fileName Name of the file being downloaded
typedef void (^MWDownloadProgressBlock)(int64_t bytesDownloaded, int64_t totalBytes, NSString *fileName);

@interface MWModelManager : NSObject

/// Shared singleton instance.
+ (instancetype)shared;

/// The cache directory for downloaded models.
/// Default: ~/Library/Caches/MetalWhisper/models/
@property (nonatomic, copy) NSString *cacheDirectory;

/// Resolve a model alias or path to a local directory path.
/// If the model is already cached, returns the cached path immediately.
/// If the model needs downloading, downloads it first.
/// If sizeOrPath is a local directory path, returns it directly.
/// @param sizeOrPath Model size alias ("tiny", "large-v3", "turbo") or local path or HF repo ID
/// @param progress Progress callback (nil for no progress)
/// @param error Error output
/// @return Local path to model directory, or nil on failure
- (nullable NSString *)resolveModel:(NSString *)sizeOrPath
                           progress:(nullable MWDownloadProgressBlock)progress
                              error:(NSError **)error;

/// Check if a model is already cached locally.
- (BOOL)isModelCached:(NSString *)sizeOrPath;

/// List all cached models with their sizes.
/// @return Array of dictionaries with keys: "name", "path", "sizeBytes"
- (NSArray<NSDictionary *> *)listCachedModels;

/// Delete a cached model.
- (BOOL)deleteCachedModel:(NSString *)sizeOrPath error:(NSError **)error;

/// List available model aliases.
+ (NSArray<NSString *> *)availableModels;

/// Get the HuggingFace repo ID for a model alias.
+ (nullable NSString *)repoIDForAlias:(NSString *)alias;

@end

NS_ASSUME_NONNULL_END
