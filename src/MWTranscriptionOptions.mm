// MWTranscriptionOptions.mm — Typed transcription options.
// Manual retain/release (-fno-objc-arc).

#import "MWTranscriptionOptions.h"

@implementation MWTranscriptionOptions

// ── Lifecycle ───────────────────────────────────────────────────────────────

- (instancetype)init {
    self = [super init];
    if (self) {
        _beamSize = 5;
        _bestOf = 5;
        _patience = 1.0f;
        _lengthPenalty = 1.0f;
        _repetitionPenalty = 1.0f;
        _noRepeatNgramSize = 0;
        _temperatures = [@[@0.0, @0.2, @0.4, @0.6, @0.8, @1.0] retain];

        _compressionRatioThreshold = 2.4f;
        _logProbThreshold = -1.0f;
        _noSpeechThreshold = 0.6f;

        _conditionOnPreviousText = YES;
        _promptResetOnTemperature = 0.5f;
        _withoutTimestamps = NO;
        _maxInitialTimestamp = 1.0f;
        _suppressBlank = YES;
        _suppressTokens = [@[@(-1)] retain];

        _wordTimestamps = NO;
        _prependPunctuations = nil;
        _appendPunctuations = nil;
        _hallucinationSilenceThreshold = 0.0f;

        _initialPrompt = nil;
        _hotwords = nil;
        _prefix = nil;

        _languageDetectionSegments = 1;
        _languageDetectionThreshold = 0.5f;

        _multilingual = NO;

        _maxNewTokens = 0;

        _vadFilter = NO;
        _vadModelPath = nil;
    }
    return self;
}

- (void)dealloc {
    [_temperatures release];
    [_suppressTokens release];
    [_prependPunctuations release];
    [_appendPunctuations release];
    [_initialPrompt release];
    [_hotwords release];
    [_prefix release];
    [_vadModelPath release];
    [super dealloc];
}

+ (instancetype)defaults {
    return [[[self alloc] init] autorelease];
}

// ── Property setters (copy semantics, manual retain/release) ────────────────

- (void)setTemperatures:(NSArray<NSNumber *> *)temperatures {
    if (_temperatures != temperatures) {
        [_temperatures release];
        _temperatures = [temperatures copy];
    }
}

- (void)setSuppressTokens:(NSArray<NSNumber *> *)suppressTokens {
    if (_suppressTokens != suppressTokens) {
        [_suppressTokens release];
        _suppressTokens = [suppressTokens copy];
    }
}

- (void)setPrependPunctuations:(NSString *)prependPunctuations {
    if (_prependPunctuations != prependPunctuations) {
        [_prependPunctuations release];
        _prependPunctuations = [prependPunctuations copy];
    }
}

- (void)setAppendPunctuations:(NSString *)appendPunctuations {
    if (_appendPunctuations != appendPunctuations) {
        [_appendPunctuations release];
        _appendPunctuations = [appendPunctuations copy];
    }
}

- (void)setInitialPrompt:(NSString *)initialPrompt {
    if (_initialPrompt != initialPrompt) {
        [_initialPrompt release];
        _initialPrompt = [initialPrompt copy];
    }
}

- (void)setHotwords:(NSString *)hotwords {
    if (_hotwords != hotwords) {
        [_hotwords release];
        _hotwords = [hotwords copy];
    }
}

- (void)setPrefix:(NSString *)prefix {
    if (_prefix != prefix) {
        [_prefix release];
        _prefix = [prefix copy];
    }
}

- (void)setVadModelPath:(NSString *)vadModelPath {
    if (_vadModelPath != vadModelPath) {
        [_vadModelPath release];
        _vadModelPath = [vadModelPath copy];
    }
}

// ── NSCopying ───────────────────────────────────────────────────────────────

- (id)copyWithZone:(NSZone *)zone {
    MWTranscriptionOptions *copy = [[MWTranscriptionOptions alloc] init];

    copy->_beamSize = _beamSize;
    copy->_bestOf = _bestOf;
    copy->_patience = _patience;
    copy->_lengthPenalty = _lengthPenalty;
    copy->_repetitionPenalty = _repetitionPenalty;
    copy->_noRepeatNgramSize = _noRepeatNgramSize;
    [copy->_temperatures release];
    copy->_temperatures = [_temperatures copy];

    copy->_compressionRatioThreshold = _compressionRatioThreshold;
    copy->_logProbThreshold = _logProbThreshold;
    copy->_noSpeechThreshold = _noSpeechThreshold;

    copy->_conditionOnPreviousText = _conditionOnPreviousText;
    copy->_promptResetOnTemperature = _promptResetOnTemperature;
    copy->_withoutTimestamps = _withoutTimestamps;
    copy->_maxInitialTimestamp = _maxInitialTimestamp;
    copy->_suppressBlank = _suppressBlank;
    [copy->_suppressTokens release];
    copy->_suppressTokens = [_suppressTokens copy];

    copy->_wordTimestamps = _wordTimestamps;
    [copy->_prependPunctuations release];
    copy->_prependPunctuations = [_prependPunctuations copy];
    [copy->_appendPunctuations release];
    copy->_appendPunctuations = [_appendPunctuations copy];
    copy->_hallucinationSilenceThreshold = _hallucinationSilenceThreshold;

    [copy->_initialPrompt release];
    copy->_initialPrompt = [_initialPrompt copy];
    [copy->_hotwords release];
    copy->_hotwords = [_hotwords copy];
    [copy->_prefix release];
    copy->_prefix = [_prefix copy];

    copy->_languageDetectionSegments = _languageDetectionSegments;
    copy->_languageDetectionThreshold = _languageDetectionThreshold;

    copy->_multilingual = _multilingual;

    copy->_maxNewTokens = _maxNewTokens;

    copy->_vadFilter = _vadFilter;
    [copy->_vadModelPath release];
    copy->_vadModelPath = [_vadModelPath copy];

    return copy;
}

// ── toDictionary ────────────────────────────────────────────────────────────

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];

    // Fix 12 (MEDIUM): Clamp numeric fields to valid ranges.
    NSUInteger beamSize = MAX(1u, MIN(_beamSize, 100u));
    NSUInteger bestOf = MAX(1u, MIN(_bestOf, 100u));
    float patience = MAX(0.0f, MIN(_patience, 10.0f));
    float lengthPenalty = MAX(0.0f, MIN(_lengthPenalty, 10.0f));
    float repetitionPenalty = MAX(0.0f, MIN(_repetitionPenalty, 10.0f));

    dict[@"beamSize"] = @(beamSize);
    dict[@"bestOf"] = @(bestOf);
    dict[@"patience"] = @(patience);
    dict[@"lengthPenalty"] = @(lengthPenalty);
    dict[@"repetitionPenalty"] = @(repetitionPenalty);
    dict[@"noRepeatNgramSize"] = @(_noRepeatNgramSize);
    if (_temperatures) {
        dict[@"temperatures"] = _temperatures;
    }

    dict[@"compressionRatioThreshold"] = @(_compressionRatioThreshold);
    dict[@"logProbThreshold"] = @(_logProbThreshold);
    dict[@"noSpeechThreshold"] = @(_noSpeechThreshold);

    dict[@"conditionOnPreviousText"] = @(_conditionOnPreviousText);
    dict[@"promptResetOnTemperature"] = @(_promptResetOnTemperature);
    dict[@"withoutTimestamps"] = @(_withoutTimestamps);
    dict[@"maxInitialTimestamp"] = @(_maxInitialTimestamp);
    dict[@"suppressBlank"] = @(_suppressBlank);
    if (_suppressTokens) {
        dict[@"suppressTokens"] = _suppressTokens;
    }

    dict[@"wordTimestamps"] = @(_wordTimestamps);
    if (_prependPunctuations) {
        dict[@"prependPunctuations"] = _prependPunctuations;
    }
    if (_appendPunctuations) {
        dict[@"appendPunctuations"] = _appendPunctuations;
    }
    dict[@"hallucinationSilenceThreshold"] = @(_hallucinationSilenceThreshold);

    if (_initialPrompt) {
        dict[@"initialPrompt"] = _initialPrompt;
    }
    if (_hotwords) {
        dict[@"hotwords"] = _hotwords;
    }
    if (_prefix) {
        dict[@"prefix"] = _prefix;
    }

    dict[@"languageDetectionSegments"] = @(_languageDetectionSegments);
    dict[@"languageDetectionThreshold"] = @(_languageDetectionThreshold);

    dict[@"multilingual"] = @(_multilingual);

    dict[@"maxNewTokens"] = @(_maxNewTokens);

    dict[@"vadFilter"] = @(_vadFilter);
    if (_vadModelPath) {
        dict[@"vadModelPath"] = _vadModelPath;
    }

    return [NSDictionary dictionaryWithDictionary:dict];
}

@end
