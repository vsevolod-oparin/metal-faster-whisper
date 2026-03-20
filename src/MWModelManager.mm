// src/MWModelManager.mm -- Model downloading and caching for MetalWhisper
// Manual retain/release (-fno-objc-arc)

#import "MWModelManager.h"
#import "MWTranscriber.h"  // For MWErrorDomain and MWErrorCode

#include <sys/stat.h>

// ── Error codes for model manager ──────────────────────────────────────────

static const NSInteger kMWErrorModelDownloadFailed = 600;
static const NSInteger kMWErrorModelValidationFailed = 601;
static const NSInteger kMWErrorModelNotFound = 602;
static const NSInteger kMWErrorCacheDirectoryFailed = 603;

// ── Model alias map ────────────────────────────────────────────────────────

static NSDictionary<NSString *, NSString *> *modelAliasMap(void) {
    static NSDictionary *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = [@{
            @"tiny.en"           : @"Systran/faster-whisper-tiny.en",
            @"tiny"              : @"Systran/faster-whisper-tiny",
            @"base.en"           : @"Systran/faster-whisper-base.en",
            @"base"              : @"Systran/faster-whisper-base",
            @"small.en"          : @"Systran/faster-whisper-small.en",
            @"small"             : @"Systran/faster-whisper-small",
            @"medium.en"         : @"Systran/faster-whisper-medium.en",
            @"medium"            : @"Systran/faster-whisper-medium",
            @"large-v1"          : @"Systran/faster-whisper-large-v1",
            @"large-v2"          : @"Systran/faster-whisper-large-v2",
            @"large-v3"          : @"Systran/faster-whisper-large-v3",
            @"large"             : @"Systran/faster-whisper-large-v3",
            @"distil-large-v2"   : @"Systran/faster-distil-whisper-large-v2",
            @"distil-medium.en"  : @"Systran/faster-distil-whisper-medium.en",
            @"distil-small.en"   : @"Systran/faster-distil-whisper-small.en",
            @"distil-large-v3"   : @"Systran/faster-distil-whisper-large-v3",
            @"large-v3-turbo"    : @"mobiuslabsgmbh/faster-whisper-large-v3-turbo",
            @"turbo"             : @"mobiuslabsgmbh/faster-whisper-large-v3-turbo",
        } retain];
    });
    return map;
}

// ── Required model files ───────────────────────────────────────────────────

static NSArray<NSString *> *requiredModelFiles(void) {
    return @[@"model.bin", @"tokenizer.json", @"config.json"];
}

static NSArray<NSString *> *optionalModelFiles(void) {
    return @[@"preprocessor_config.json"];
}

static NSArray<NSString *> *vocabularyAlternatives(void) {
    return @[@"vocabulary.json", @"vocabulary.txt"];
}

static NSArray<NSString *> *allDownloadableFiles(void) {
    return @[
        @"model.bin",
        @"tokenizer.json",
        @"config.json",
        @"preprocessor_config.json",
        @"vocabulary.json",
        @"vocabulary.txt",
    ];
}

// ── Helpers ────────────────────────────────────────────────────────────────

static NSString *sanitizeRepoID(NSString *repoID) {
    return [repoID stringByReplacingOccurrencesOfString:@"/" withString:@"--"];
}

static NSString *defaultCacheDirectory(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES);
    NSString *caches = paths.firstObject ?: NSTemporaryDirectory();
    return [[caches stringByAppendingPathComponent:@"MetalWhisper"]
            stringByAppendingPathComponent:@"models"];
}

static BOOL isLocalModelDirectory(NSString *path) {
    BOOL isDir = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) {
        NSString *modelBin = [path stringByAppendingPathComponent:@"model.bin"];
        return [fm fileExistsAtPath:modelBin];
    }
    return NO;
}

static BOOL validateModelDirectory(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Check required files
    for (NSString *file in requiredModelFiles()) {
        NSString *filePath = [path stringByAppendingPathComponent:file];
        if (![fm fileExistsAtPath:filePath]) {
            return NO;
        }
    }

    // Check vocabulary (either .json or .txt)
    BOOL hasVocab = NO;
    for (NSString *vocabFile in vocabularyAlternatives()) {
        NSString *vocabPath = [path stringByAppendingPathComponent:vocabFile];
        if ([fm fileExistsAtPath:vocabPath]) {
            hasVocab = YES;
            break;
        }
    }

    return hasVocab;
}

// ── Download delegate for progress tracking ────────────────────────────────

@interface MWDownloadDelegate : NSObject <NSURLSessionDataDelegate> {
    NSMutableData *_receivedData;
    int64_t _totalBytesExpected;
    int64_t _bytesReceived;
    MWDownloadProgressBlock _progressBlock;
    NSString *_fileName;
    NSError *_error;
    dispatch_semaphore_t _semaphore;
    NSInteger _statusCode;
}

@property (nonatomic, readonly) NSData *receivedData;
@property (nonatomic, readonly) NSError *error;
@property (nonatomic, readonly) NSInteger statusCode;

- (instancetype)initWithProgressBlock:(MWDownloadProgressBlock)progress
                             fileName:(NSString *)fileName
                            semaphore:(dispatch_semaphore_t)semaphore;
@end

@implementation MWDownloadDelegate

- (instancetype)initWithProgressBlock:(MWDownloadProgressBlock)progress
                             fileName:(NSString *)fileName
                            semaphore:(dispatch_semaphore_t)semaphore {
    self = [super init];
    if (self) {
        _receivedData = [[NSMutableData alloc] init];
        _totalBytesExpected = -1;
        _bytesReceived = 0;
        _progressBlock = [progress copy];
        _fileName = [fileName copy];
        _error = nil;
        _semaphore = semaphore;
        _statusCode = 0;
    }
    return self;
}

- (void)dealloc {
    [_receivedData release];
    [_progressBlock release];
    [_fileName release];
    [_error release];
    [super dealloc];
}

- (NSData *)receivedData { return _receivedData; }
- (NSError *)error { return _error; }
- (NSInteger)statusCode { return _statusCode; }

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        _statusCode = httpResponse.statusCode;
        if (_statusCode >= 400) {
            completionHandler(NSURLSessionResponseCancel);
            return;
        }
        _totalBytesExpected = httpResponse.expectedContentLength;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    [_receivedData appendData:data];
    _bytesReceived += (int64_t)data.length;

    if (_progressBlock) {
        _progressBlock(_bytesReceived, _totalBytesExpected, _fileName);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (error) {
        [_error release];
        _error = [error retain];
    }
    dispatch_semaphore_signal(_semaphore);
}

@end

// ── MWModelManager ─────────────────────────────────────────────────────────

@implementation MWModelManager {
    NSString *_cacheDirectory;
}

+ (instancetype)shared {
    static MWModelManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MWModelManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cacheDirectory = [defaultCacheDirectory() copy];
    }
    return self;
}

- (void)dealloc {
    [_cacheDirectory release];
    [super dealloc];
}

- (NSString *)cacheDirectory {
    return _cacheDirectory;
}

- (void)setCacheDirectory:(NSString *)cacheDirectory {
    if (_cacheDirectory != cacheDirectory) {
        [_cacheDirectory release];
        _cacheDirectory = [cacheDirectory copy];
    }
}

// ── Resolve model ──────────────────────────────────────────────────────────

- (nullable NSString *)resolveModel:(NSString *)sizeOrPath
                           progress:(nullable MWDownloadProgressBlock)progress
                              error:(NSError **)error {
    // 1. Check if it's a local directory with model.bin
    if (isLocalModelDirectory(sizeOrPath)) {
        return sizeOrPath;
    }

    // 2. Resolve alias to repo ID
    NSString *repoID = nil;
    NSString *alias = [modelAliasMap() objectForKey:sizeOrPath];
    if (alias) {
        repoID = alias;
    } else if ([sizeOrPath containsString:@"/"]) {
        // Treat as repo ID directly
        repoID = sizeOrPath;
    } else {
        // Not a known alias, not a path, not a repo ID
        if (error) {
            *error = [NSError errorWithDomain:MWErrorDomain
                                         code:kMWErrorModelNotFound
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Unknown model: '%@'. "
                     "Use a model alias (e.g., 'tiny', 'large-v3'), "
                     "a HuggingFace repo ID, or a local path.", sizeOrPath]
            }];
        }
        return nil;
    }

    // 3. Check cache
    NSString *sanitized = sanitizeRepoID(repoID);
    NSString *cachePath = [_cacheDirectory stringByAppendingPathComponent:sanitized];

    if (validateModelDirectory(cachePath)) {
        return cachePath;
    }

    // 4. Download
    return [self downloadModel:repoID toCachePath:cachePath progress:progress error:error];
}

// ── Download ───────────────────────────────────────────────────────────────

- (nullable NSString *)downloadModel:(NSString *)repoID
                         toCachePath:(NSString *)cachePath
                            progress:(nullable MWDownloadProgressBlock)progress
                               error:(NSError **)error {
    // Ensure cache directory exists
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:cachePath
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&dirError]) {
        if (error) {
            *error = [NSError errorWithDomain:MWErrorDomain
                                         code:kMWErrorCacheDirectoryFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Failed to create cache directory: %@",
                     [dirError localizedDescription]]
            }];
        }
        return nil;
    }

    // Download each file
    for (NSString *fileName in allDownloadableFiles()) {
        NSString *destPath = [cachePath stringByAppendingPathComponent:fileName];

        // Skip if already downloaded
        if ([fm fileExistsAtPath:destPath]) {
            continue;
        }

        NSString *urlStr = [NSString stringWithFormat:
            @"https://huggingface.co/%@/resolve/main/%@", repoID, fileName];
        NSURL *url = [NSURL URLWithString:urlStr];

        if (![self downloadFileFromURL:url toPath:destPath fileName:fileName
                              progress:progress error:error]) {
            // vocabulary.json/vocabulary.txt may not both exist -- that's OK
            BOOL isOptional = [vocabularyAlternatives() containsObject:fileName] ||
                              [optionalModelFiles() containsObject:fileName];
            if (isOptional) {
                if (error) *error = nil;
                continue;
            }
            // Required file failed -- abort
            return nil;
        }
    }

    // 5. Validate
    if (!validateModelDirectory(cachePath)) {
        if (error) {
            *error = [NSError errorWithDomain:MWErrorDomain
                                         code:kMWErrorModelValidationFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Downloaded model at %@ is incomplete. "
                     "Required files: model.bin, tokenizer.json, config.json, "
                     "and vocabulary.json or vocabulary.txt. "
                     "Optional: preprocessor_config.json",
                     cachePath]
            }];
        }
        return nil;
    }

    return cachePath;
}

- (BOOL)downloadFileFromURL:(NSURL *)url
                     toPath:(NSString *)destPath
                   fileName:(NSString *)fileName
                   progress:(nullable MWDownloadProgressBlock)progress
                      error:(NSError **)error {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    MWDownloadDelegate *delegate =
        [[[MWDownloadDelegate alloc] initWithProgressBlock:progress
                                                 fileName:fileName
                                                semaphore:semaphore] autorelease];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 120.0;   // 2 min between data chunks
    config.timeoutIntervalForResource = 7200.0;  // 2 hours for large models

    NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                          delegate:delegate
                                                     delegateQueue:nil];

    // Check for partial download to support resumption
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    NSString *partialPath = [destPath stringByAppendingString:@".partial"];
    NSFileManager *fm = [NSFileManager defaultManager];

    int64_t existingBytes = 0;
    if ([fm fileExistsAtPath:partialPath]) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:partialPath error:nil];
        existingBytes = [attrs fileSize];
        if (existingBytes > 0) {
            NSString *rangeHeader = [NSString stringWithFormat:@"bytes=%lld-", existingBytes];
            [request setValue:rangeHeader forHTTPHeaderField:@"Range"];
        }
    }

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    [task resume];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    [session invalidateAndCancel];

    // Check for errors
    if (delegate.error) {
        if (error) {
            *error = [NSError errorWithDomain:MWErrorDomain
                                         code:kMWErrorModelDownloadFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Failed to download %@ from %@: %@",
                     fileName, [url absoluteString], [delegate.error localizedDescription]]
            }];
        }
        return NO;
    }

    // Check HTTP status code
    if (delegate.statusCode >= 400) {
        if (error) {
            *error = [NSError errorWithDomain:MWErrorDomain
                                         code:kMWErrorModelDownloadFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"HTTP %ld downloading %@ from %@",
                     (long)delegate.statusCode, fileName, [url absoluteString]]
            }];
        }
        return NO;
    }

    // Write data
    NSData *data = delegate.receivedData;
    if (!data || data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:MWErrorDomain
                                         code:kMWErrorModelDownloadFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Empty response downloading %@", fileName]
            }];
        }
        return NO;
    }

    // If we had a partial download with Range request, append; otherwise write fresh
    if (existingBytes > 0 && delegate.statusCode == 206) {
        // Append to partial file
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:partialPath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        } else {
            // Partial file handle failed, write fresh
            [data writeToFile:partialPath atomically:YES];
        }
    } else {
        // Write fresh (full response)
        [data writeToFile:partialPath atomically:YES];
    }

    // Move partial to final destination
    NSError *moveError = nil;
    if ([fm fileExistsAtPath:destPath]) {
        [fm removeItemAtPath:destPath error:nil];
    }
    if (![fm moveItemAtPath:partialPath toPath:destPath error:&moveError]) {
        if (error) {
            *error = [NSError errorWithDomain:MWErrorDomain
                                         code:kMWErrorModelDownloadFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Failed to finalize %@: %@",
                     fileName, [moveError localizedDescription]]
            }];
        }
        return NO;
    }

    return YES;
}

// ── Cache queries ──────────────────────────────────────────────────────────

- (BOOL)isModelCached:(NSString *)sizeOrPath {
    // Check local path
    if (isLocalModelDirectory(sizeOrPath)) {
        return YES;
    }

    // Resolve alias
    NSString *repoID = [modelAliasMap() objectForKey:sizeOrPath];
    if (!repoID) {
        if ([sizeOrPath containsString:@"/"]) {
            repoID = sizeOrPath;
        } else {
            return NO;
        }
    }

    NSString *sanitized = sanitizeRepoID(repoID);
    NSString *cachePath = [_cacheDirectory stringByAppendingPathComponent:sanitized];
    return validateModelDirectory(cachePath);
}

- (NSArray<NSDictionary *> *)listCachedModels {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *results = [NSMutableArray array];

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:_cacheDirectory isDirectory:&isDir] || !isDir) {
        return results;
    }

    NSError *listError = nil;
    NSArray<NSString *> *contents = [fm contentsOfDirectoryAtPath:_cacheDirectory
                                                           error:&listError];
    if (!contents) {
        return results;
    }

    for (NSString *dirName in contents) {
        NSString *fullPath = [_cacheDirectory stringByAppendingPathComponent:dirName];
        BOOL isDirEntry = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDirEntry] || !isDirEntry) {
            continue;
        }
        if (!validateModelDirectory(fullPath)) {
            continue;
        }

        // Calculate total size
        unsigned long long totalSize = 0;
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:fullPath];
        NSString *file = nil;
        while ((file = [enumerator nextObject])) {
            NSString *filePath = [fullPath stringByAppendingPathComponent:file];
            NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
            if (attrs) {
                totalSize += [attrs fileSize];
            }
        }

        [results addObject:@{
            @"name": dirName,
            @"path": fullPath,
            @"sizeBytes": @(totalSize),
        }];
    }

    return results;
}

- (BOOL)deleteCachedModel:(NSString *)sizeOrPath error:(NSError **)error {
    NSString *repoID = [modelAliasMap() objectForKey:sizeOrPath];
    if (!repoID) {
        if ([sizeOrPath containsString:@"/"]) {
            repoID = sizeOrPath;
        } else {
            if (error) {
                *error = [NSError errorWithDomain:MWErrorDomain
                                             code:kMWErrorModelNotFound
                                         userInfo:@{
                    NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"Unknown model: '%@'", sizeOrPath]
                }];
            }
            return NO;
        }
    }

    NSString *sanitized = sanitizeRepoID(repoID);
    NSString *cachePath = [_cacheDirectory stringByAppendingPathComponent:sanitized];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:cachePath]) {
        return YES;  // Nothing to delete
    }

    return [fm removeItemAtPath:cachePath error:error];
}

// ── Class methods ──────────────────────────────────────────────────────────

+ (NSArray<NSString *> *)availableModels {
    return [[modelAliasMap() allKeys]
            sortedArrayUsingSelector:@selector(compare:)];
}

+ (nullable NSString *)repoIDForAlias:(NSString *)alias {
    return [modelAliasMap() objectForKey:alias];
}

@end
