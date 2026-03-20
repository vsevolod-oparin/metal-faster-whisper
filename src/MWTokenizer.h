#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// BPE tokenizer for Whisper models.
/// Loads tokenizer.json directly and implements GPT-2 style byte-level BPE.
@interface MWTokenizer : NSObject

/// Load tokenizer from a model directory containing tokenizer.json.
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                              multilingual:(BOOL)multilingual
                                      task:(nullable NSString *)task
                                  language:(nullable NSString *)language
                                     error:(NSError **)error NS_DESIGNATED_INITIALIZER;

/// Unavailable — use initWithModelPath:multilingual:task:language:error:.
- (instancetype)init NS_UNAVAILABLE;

// --- Encode/Decode ---

/// Encode text to token IDs using byte-level BPE.
- (NSArray<NSNumber *> *)encode:(NSString *)text;

/// Decode token IDs to text (filters out tokens >= eot).
- (NSString *)decode:(NSArray<NSNumber *> *)tokenIDs;

/// Decode with timestamps: interleave text and <|0.00|> markers.
- (NSString *)decodeWithTimestamps:(NSArray<NSNumber *> *)tokenIDs;

// --- Special Token Properties ---

@property (nonatomic, readonly) NSUInteger sot;
@property (nonatomic, readonly) NSUInteger eot;
@property (nonatomic, readonly) NSUInteger sotPrev;
@property (nonatomic, readonly) NSUInteger sotLM;
@property (nonatomic, readonly) NSUInteger noTimestamps;
@property (nonatomic, readonly) NSUInteger noSpeech;
@property (nonatomic, readonly) NSUInteger timestampBegin;
@property (nonatomic, readonly) NSUInteger transcribeToken;
@property (nonatomic, readonly) NSUInteger translateToken;

/// Language token ID (e.g., 50259 for English).
@property (nonatomic, readonly) NSUInteger languageToken;

/// The language code string (e.g., "en").
@property (nonatomic, readonly, copy) NSString *languageCode;

/// sot_sequence: [sot, language?, task?]
@property (nonatomic, readonly) NSArray<NSNumber *> *sotSequence;

/// Vocab size (including added/special tokens).
@property (nonatomic, readonly) NSUInteger vocabSize;

/// Look up a token string (e.g. "<|en|>") and return its ID, or NSNotFound if missing.
- (NSUInteger)tokenIDForString:(NSString *)tokenString;

// --- Word splitting ---

/// Split tokens into words (space-based for most languages, character-based for CJK).
- (void)splitToWordTokens:(NSArray<NSNumber *> *)tokenIDs
                    words:(NSArray<NSString *> * _Nonnull * _Nonnull)outWords
               wordTokens:(NSArray<NSArray<NSNumber *> *> * _Nonnull * _Nonnull)outWordTokens;

// --- Suppression ---

/// Token IDs to suppress (non-speech annotations, symbols).
@property (nonatomic, readonly) NSArray<NSNumber *> *nonSpeechTokens;

@end

NS_ASSUME_NONNULL_END
