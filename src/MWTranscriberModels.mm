#import "MWTranscriber.h"

// ── MWSegmentInfo ───────────────────────────────────────────────────────────

@implementation MWSegmentInfo {
    NSUInteger _seek;
    float _startTime;
    float _endTime;
    NSArray<NSNumber *> *_tokens;
}

- (instancetype)initWithSeek:(NSUInteger)seek
                   startTime:(float)startTime
                     endTime:(float)endTime
                      tokens:(NSArray<NSNumber *> *)tokens {
    self = [super init];
    if (!self) return nil;
    _seek = seek;
    _startTime = startTime;
    _endTime = endTime;
    _tokens = [tokens retain];
    return self;
}

- (NSUInteger)seek { return _seek; }
- (float)startTime { return _startTime; }
- (float)endTime { return _endTime; }
- (NSArray<NSNumber *> *)tokens { return _tokens; }

- (void)dealloc {
    [_tokens release];
    [super dealloc];
}

@end

// ── MWGenerateResult ────────────────────────────────────────────────────────

@implementation MWGenerateResult {
    NSArray<NSNumber *> *_tokenIDs;
    float _avgLogProb;
    float _temperature;
    float _compressionRatio;
    float _noSpeechProb;
    NSString *_text;
}

- (instancetype)initWithTokenIDs:(NSArray<NSNumber *> *)tokenIDs
                      avgLogProb:(float)avgLogProb
                     temperature:(float)temperature
                compressionRatio:(float)compressionRatio
                   noSpeechProb:(float)noSpeechProb
                            text:(NSString *)text {
    self = [super init];
    if (!self) return nil;
    _tokenIDs = [tokenIDs retain];
    _avgLogProb = avgLogProb;
    _temperature = temperature;
    _compressionRatio = compressionRatio;
    _noSpeechProb = noSpeechProb;
    _text = [text retain];
    return self;
}

- (NSArray<NSNumber *> *)tokenIDs { return _tokenIDs; }
- (float)avgLogProb { return _avgLogProb; }
- (float)temperature { return _temperature; }
- (float)compressionRatio { return _compressionRatio; }
- (float)noSpeechProb { return _noSpeechProb; }
- (NSString *)text { return _text; }

- (void)dealloc {
    [_tokenIDs release];
    [_text release];
    [super dealloc];
}

@end

// ── MWWord ────────────────────────────────────────────────────────────────────

@implementation MWWord {
    NSString *_word;
    float _start;
    float _end;
    float _probability;
}

- (instancetype)initWithWord:(NSString *)word
                       start:(float)start
                         end:(float)end
                 probability:(float)probability {
    self = [super init];
    if (!self) return nil;
    _word = [word retain];
    _start = start;
    _end = end;
    _probability = probability;
    return self;
}

- (NSString *)word { return _word; }
- (float)start { return _start; }
- (float)end { return _end; }
- (float)probability { return _probability; }

- (void)dealloc {
    [_word release];
    [super dealloc];
}

@end

// ── MWTranscriptionSegment ────────────────────────────────────────────────────

@implementation MWTranscriptionSegment {
    NSUInteger _segmentId;
    NSUInteger _seek;
    float _start;
    float _end;
    NSString *_text;
    NSArray<NSNumber *> *_tokens;
    float _temperature;
    float _avgLogProb;
    float _compressionRatio;
    float _noSpeechProb;
    NSArray<MWWord *> *_words;
}

- (instancetype)initWithSegmentId:(NSUInteger)segmentId
                             seek:(NSUInteger)seek
                            start:(float)start
                              end:(float)end
                             text:(NSString *)text
                           tokens:(NSArray<NSNumber *> *)tokens
                      temperature:(float)temperature
                       avgLogProb:(float)avgLogProb
                 compressionRatio:(float)compressionRatio
                    noSpeechProb:(float)noSpeechProb
                            words:(NSArray<MWWord *> *)words {
    self = [super init];
    if (!self) return nil;
    _segmentId = segmentId;
    _seek = seek;
    _start = start;
    _end = end;
    _text = [text retain];
    _tokens = [tokens retain];
    _temperature = temperature;
    _avgLogProb = avgLogProb;
    _compressionRatio = compressionRatio;
    _noSpeechProb = noSpeechProb;
    _words = [words retain];
    return self;
}

- (NSUInteger)segmentId { return _segmentId; }
- (NSUInteger)seek { return _seek; }
- (float)start { return _start; }
- (float)end { return _end; }
- (NSString *)text { return _text; }
- (NSArray<NSNumber *> *)tokens { return _tokens; }
- (float)temperature { return _temperature; }
- (float)avgLogProb { return _avgLogProb; }
- (float)compressionRatio { return _compressionRatio; }
- (float)noSpeechProb { return _noSpeechProb; }
- (NSArray<MWWord *> *)words { return _words; }

- (void)dealloc {
    [_text release];
    [_tokens release];
    [_words release];
    [super dealloc];
}

@end

// ── MWTranscriptionInfo ──────────────────────────────────────────────────────

@implementation MWTranscriptionInfo {
    NSString *_language;
    float _languageProbability;
    float _duration;
}

- (instancetype)initWithLanguage:(NSString *)language
             languageProbability:(float)languageProbability
                        duration:(float)duration {
    self = [super init];
    if (!self) return nil;
    _language = [language retain];
    _languageProbability = languageProbability;
    _duration = duration;
    return self;
}

- (NSString *)language { return _language; }
- (float)languageProbability { return _languageProbability; }
- (float)duration { return _duration; }

- (void)dealloc {
    [_language release];
    [super dealloc];
}

@end
