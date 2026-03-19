#import "MWHelpers.h"
#import "MWConstants.h"

#include <compression.h>

// ── Debug logging flag ──────────────────────────────────────────────────────

BOOL MWDebugLoggingEnabled = NO;

// ── Error domain (shared, defined once) ─────────────────────────────────────

NSErrorDomain const MWErrorDomain = @"com.metalwhisper.error";

// ── Error helper ────────────────────────────────────────────────────────────

void MWSetError(NSError **error, NSInteger code, NSString *description) {
    if (error) {
        *error = [NSError errorWithDomain:MWErrorDomain
                                     code:code
                                 userInfo:@{
            NSLocalizedDescriptionKey: description
        }];
    }
}

// ── CT2 compute type mapping ────────────────────────────────────────────────
// (stays in MWTranscriber.mm since it uses CT2 headers)

// ── Standard Whisper language codes ─────────────────────────────────────────

NSArray<NSString *> *MWWhisperLanguageCodes(void) {
    static NSArray<NSString *> *codes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        codes = [@[
            @"en", @"zh", @"de", @"es", @"ru", @"ko", @"fr", @"ja", @"pt", @"tr",
            @"pl", @"ca", @"nl", @"ar", @"sv", @"it", @"id", @"hi", @"fi", @"vi",
            @"he", @"uk", @"el", @"ms", @"cs", @"ro", @"da", @"hu", @"ta", @"no",
            @"th", @"ur", @"hr", @"bg", @"lt", @"la", @"mi", @"ml", @"cy", @"sk",
            @"te", @"fa", @"lv", @"bn", @"sr", @"az", @"sl", @"kn", @"et", @"mk",
            @"br", @"eu", @"is", @"hy", @"ne", @"mn", @"bs", @"kk", @"sq", @"sw",
            @"gl", @"mr", @"pa", @"si", @"km", @"sn", @"yo", @"so", @"af", @"oc",
            @"ka", @"be", @"tg", @"sd", @"gu", @"am", @"yi", @"lo", @"uz", @"fo",
            @"ht", @"ps", @"tk", @"nn", @"mt", @"sa", @"lb", @"my", @"bo", @"tl",
            @"mg", @"as", @"tt", @"haw", @"ln", @"ha", @"ba", @"jw", @"su", @"yue"
        ] retain];
    });
    return codes;
}

// ── JSON loading helper ─────────────────────────────────────────────────────

NSDictionary *MWLoadJSONFromPath(NSString *path, NSError **error) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return nil;  // Caller handles missing file gracefully
    }

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;

    NSError *parseError = nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data
                                                        options:0
                                                          error:&parseError];
    if (!dict && error) {
        *error = parseError;
    }
    return dict;
}

// ── Mel pad/trim helper ─────────────────────────────────────────────────────

NSData *MWPadOrTrimMel(NSData *mel, NSUInteger nMels, NSUInteger nFrames, NSUInteger targetFrames) {
    if (nFrames == targetFrames) return mel;

    NSUInteger targetBytes = nMels * targetFrames * sizeof(float);
    NSMutableData *result = [NSMutableData dataWithLength:targetBytes]; // zero-filled
    const float *src = (const float *)[mel bytes];
    float *dst = (float *)[result mutableBytes];

    NSUInteger copyFrames = MIN(nFrames, targetFrames);
    for (NSUInteger row = 0; row < nMels; row++) {
        memcpy(dst + row * targetFrames,
               src + row * nFrames,
               copyFrames * sizeof(float));
    }
    return result;
}

// ── Mel slicing helper ───────────────────────────────────────────────────────

NSData *MWSliceMel(NSData *fullMel, NSUInteger nMels, NSUInteger totalFrames,
                   NSUInteger startFrame, NSUInteger numFrames) {
    NSMutableData *slice = [NSMutableData dataWithLength:nMels * numFrames * sizeof(float)];
    if (startFrame >= totalFrames) {
        return slice;
    }
    const float *src = (const float *)[fullMel bytes];
    float *dst = (float *)[slice mutableBytes];
    NSUInteger copyFrames = (startFrame + numFrames <= totalFrames)
                            ? numFrames : (totalFrames - startFrame);
    for (NSUInteger row = 0; row < nMels; row++) {
        if (copyFrames > 0) {
            memcpy(dst + row * numFrames,
                   src + row * totalFrames + startFrame,
                   copyFrames * sizeof(float));
        }
    }
    return slice;
}

// ── Compression ratio helper ─────────────────────────────────────────────────

float MWGetCompressionRatio(NSString *text) {
    NSData *textData = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!textData || [textData length] == 0) return 0.0f;

    NSUInteger srcLen = [textData length];
    size_t dstCapacity = srcLen + 1024;
    uint8_t *dstBuffer = (uint8_t *)malloc(dstCapacity);
    if (!dstBuffer) return 0.0f;

    size_t compressedSize = compression_encode_buffer(
        dstBuffer, dstCapacity,
        (const uint8_t *)[textData bytes], srcLen,
        NULL,
        COMPRESSION_ZLIB);

    free(dstBuffer);

    if (compressedSize == 0) return 0.0f;
    return (float)srcLen / (float)compressedSize;
}

// ── Word-level timestamp helpers ────────────────────────────────────────────

float MWWordAnomalyScore(float probability, float duration) {
    float score = 0.0f;
    if (probability < 0.15f) {
        score += 1.0f;
    }
    if (duration < 0.133f) {
        score += (0.133f - duration) * 15.0f;
    }
    if (duration > 2.0f) {
        score += (duration - 2.0f);
    }
    return score;
}

BOOL MWIsSegmentAnomaly(NSArray<MWWord *> *words) {
    if (!words || [words count] == 0) return NO;

    float totalScore = 0.0f;
    NSUInteger wordCount = 0;
    for (MWWord *w in words) {
        NSString *stripped = [w.word stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([stripped length] == 0) continue;

        NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
        BOOL hasLetter = NO;
        for (NSUInteger i = 0; i < [stripped length]; i++) {
            if ([letters characterIsMember:[stripped characterAtIndex:i]]) {
                hasLetter = YES;
                break;
            }
        }
        if (!hasLetter) continue;

        float dur = w.end - w.start;
        totalScore += MWWordAnomalyScore(w.probability, dur);
        wordCount++;
        if (wordCount >= 8) break;
    }

    if (wordCount == 0) return NO;
    return (totalScore >= 3.0f) || (totalScore + 0.01f >= (float)wordCount);
}

void MWMergePunctuations(NSMutableArray<NSMutableDictionary *> *alignment,
                         NSString *prepended, NSString *appended) {
    if (!alignment || [alignment count] == 0) return;

    // Build character sets for quick lookup.
    NSMutableSet<NSString *> *prependSet = [[NSMutableSet alloc] init];
    for (NSUInteger i = 0; i < [prepended length]; i++) {
        [prependSet addObject:[NSString stringWithFormat:@"%C", [prepended characterAtIndex:i]]];
    }

    // Merge prepended punctuations (right to left).
    NSInteger i = (NSInteger)[alignment count] - 2;
    NSInteger j = (NSInteger)[alignment count] - 1;
    while (i >= 0) {
        NSMutableDictionary *previous = alignment[(NSUInteger)i];
        NSMutableDictionary *following = alignment[(NSUInteger)j];
        NSString *prevWord = previous[@"word"];
        NSString *stripped = [prevWord stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if ([prevWord hasPrefix:@" "] && [stripped length] > 0 && [prependSet containsObject:stripped]) {
            following[@"word"] = [prevWord stringByAppendingString:following[@"word"]];
            NSMutableArray *mergedTokens = [NSMutableArray arrayWithArray:previous[@"tokens"]];
            [mergedTokens addObjectsFromArray:following[@"tokens"]];
            following[@"tokens"] = mergedTokens;
            previous[@"word"] = @"";
            previous[@"tokens"] = [NSMutableArray array];
        } else {
            j = i;
        }
        i--;
    }
    [prependSet release];

    // Merge appended punctuations (left to right).
    i = 0;
    j = 1;
    while (j < (NSInteger)[alignment count]) {
        NSMutableDictionary *previous = alignment[(NSUInteger)i];
        NSMutableDictionary *following = alignment[(NSUInteger)j];
        NSString *prevWord = previous[@"word"];
        NSString *followWord = following[@"word"];
        if (![prevWord hasSuffix:@" "] && [prevWord length] > 0) {
            BOOL isAppended = NO;
            if ([followWord length] > 0) {
                for (NSUInteger k = 0; k < [appended length]; k++) {
                    NSString *ch = [NSString stringWithFormat:@"%C", [appended characterAtIndex:k]];
                    if ([followWord isEqualToString:ch]) {
                        isAppended = YES;
                        break;
                    }
                }
            }
            if (isAppended) {
                previous[@"word"] = [prevWord stringByAppendingString:followWord];
                NSMutableArray *mergedTokens = [NSMutableArray arrayWithArray:previous[@"tokens"]];
                [mergedTokens addObjectsFromArray:following[@"tokens"]];
                previous[@"tokens"] = mergedTokens;
                following[@"word"] = @"";
                following[@"tokens"] = [NSMutableArray array];
            } else {
                i = j;
            }
        } else {
            i = j;
        }
        j++;
    }
}

// ── Option parsing helpers (with type validation) ───────────────────────────

NSUInteger MWOptUInt(NSDictionary *opts, NSString *key, NSUInteger dflt) {
    if (!opts) return dflt;
    id val = opts[key];
    if (!val || ![val isKindOfClass:[NSNumber class]]) return dflt;
    return [val unsignedIntegerValue];
}

float MWOptFloat(NSDictionary *opts, NSString *key, float dflt) {
    if (!opts) return dflt;
    id val = opts[key];
    if (!val || ![val isKindOfClass:[NSNumber class]]) return dflt;
    return [val floatValue];
}

BOOL MWOptBool(NSDictionary *opts, NSString *key, BOOL dflt) {
    if (!opts) return dflt;
    id val = opts[key];
    if (!val || ![val isKindOfClass:[NSNumber class]]) return dflt;
    return [val boolValue];
}

NSString *MWOptString(NSDictionary *opts, NSString *key) {
    if (!opts) return nil;
    id val = opts[key];
    return ([val isKindOfClass:[NSString class]] && [val length] > 0) ? val : nil;
}
