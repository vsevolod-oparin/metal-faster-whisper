#import "MWTokenizer.h"
#import "MWHelpers.h"
#import "MWTranscriber.h"  // For MWErrorDomain, MWErrorCode, MWErrorCodeTokenizerLoadFailed

#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <algorithm>
#include <numeric>
#include <cstdint>
#include <climits>
#include <sstream>

// ── Named constants ──────────────────────────────────────────────────────────

/// Timestamp precision in seconds per token.
static const double kTimestampPrecision = 0.02;

/// Unicode codepoint where unmapped bytes start in GPT-2 byte encoding.
static const int kGPT2ByteRemapOffset = 256;

// ── GPT-2 byte-level BPE helpers ─────────────────────────────────────────────

/// Build the GPT-2 bytes_to_unicode mapping.
/// Returns a map from byte value (0-255) to unicode codepoint.
static std::unordered_map<uint8_t, char32_t> buildBytesToUnicode() {
    std::unordered_map<uint8_t, char32_t> result;
    std::unordered_set<int> direct;

    // Printable ASCII except space: 33-126
    for (int b = '!'; b <= '~'; ++b) direct.insert(b);
    // Latin-1 supplement ranges: 161-172, 174-255
    for (int b = 0xA1; b <= 0xAC; ++b) direct.insert(b);
    for (int b = 0xAE; b <= 0xFF; ++b) direct.insert(b);

    // Direct-mapped bytes
    for (int b : direct) {
        result[static_cast<uint8_t>(b)] = static_cast<char32_t>(b);
    }

    // Remaining bytes get mapped starting at codepoint 256
    int n = 0;
    for (int b = 0; b < 256; ++b) {
        if (direct.find(b) == direct.end()) {
            result[static_cast<uint8_t>(b)] = static_cast<char32_t>(kGPT2ByteRemapOffset + n);
            ++n;
        }
    }

    return result;
}

/// Build reverse mapping: unicode codepoint -> byte value.
static std::unordered_map<char32_t, uint8_t> buildUnicodeToBytes() {
    auto b2u = buildBytesToUnicode();
    std::unordered_map<char32_t, uint8_t> result;
    for (auto &[byte, cp] : b2u) {
        result[cp] = byte;
    }
    return result;
}

/// Encode a single Unicode codepoint as UTF-8 bytes appended to output.
static void appendCodepointAsUTF8(char32_t cp, std::string &output) {
    if (cp < 0x80) {
        output += static_cast<char>(cp);
    } else if (cp < 0x800) {
        output += static_cast<char>(0xC0 | (cp >> 6));
        output += static_cast<char>(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        output += static_cast<char>(0xE0 | (cp >> 12));
        output += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        output += static_cast<char>(0x80 | (cp & 0x3F));
    } else {
        output += static_cast<char>(0xF0 | (cp >> 18));
        output += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
        output += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        output += static_cast<char>(0x80 | (cp & 0x3F));
    }
}

/// Convert a BPE token string (using GPT-2 unicode mapping) back to raw bytes.
static std::string tokenStringToBytes(
    const std::string &tokenStr,
    const std::unordered_map<char32_t, uint8_t> &u2b)
{
    std::string result;
    // Decode UTF-8 codepoints from tokenStr, map each through u2b
    const uint8_t *p = reinterpret_cast<const uint8_t *>(tokenStr.data());
    const uint8_t *end = p + tokenStr.size();

    while (p < end) {
        char32_t cp = 0;
        int len = 0;
        uint8_t c = *p;
        if (c < 0x80) {
            cp = c; len = 1;
        } else if ((c & 0xE0) == 0xC0) {
            cp = c & 0x1F; len = 2;
        } else if ((c & 0xF0) == 0xE0) {
            cp = c & 0x0F; len = 3;
        } else if ((c & 0xF8) == 0xF0) {
            cp = c & 0x07; len = 4;
        } else {
            // Invalid UTF-8 byte — skip
            ++p;
            continue;
        }
        // Guard against truncated UTF-8 sequences at buffer end.
        if (p + len > end) {
            break;  // Truncated sequence, stop decoding
        }
        for (int i = 1; i < len; ++i) {
            cp = (cp << 6) | (p[i] & 0x3F);
        }
        p += len;

        auto it = u2b.find(cp);
        if (it != u2b.end()) {
            result += static_cast<char>(it->second);
        } else {
            // Not in GPT-2 mapping — pass through as UTF-8
            appendCodepointAsUTF8(cp, result);
        }
    }
    return result;
}

/// Convert raw UTF-8 text to GPT-2 byte-level unicode string.
static std::string bytesToTokenString(
    const std::string &text,
    const std::unordered_map<uint8_t, char32_t> &b2u)
{
    std::string result;
    for (uint8_t byte : text) {
        auto it = b2u.find(byte);
        if (it != b2u.end()) {
            appendCodepointAsUTF8(it->second, result);
        }
    }
    return result;
}

// ── BPE merge implementation ─────────────────────────────────────────────────

/// Find the pair with the lowest merge rank in the token list.
/// Returns the index of the first element of the pair, or -1 if no merge found.
static int findBestMergePair(
    const std::vector<std::string> &tokens,
    const std::unordered_map<std::string, int> &mergeRanks)
{
    int bestRank = INT_MAX;
    int bestIdx = -1;

    for (size_t i = 0; i + 1 < tokens.size(); ++i) {
        std::string key = tokens[i] + " " + tokens[i + 1];
        auto it = mergeRanks.find(key);
        if (it != mergeRanks.end() && it->second < bestRank) {
            bestRank = it->second;
            bestIdx = static_cast<int>(i);
        }
    }
    return bestIdx;
}

/// Apply BPE merges to a list of character-level tokens until no more merges apply.
static std::vector<std::string> applyBPEMerges(
    std::vector<std::string> tokens,
    const std::unordered_map<std::string, int> &mergeRanks)
{
    while (tokens.size() > 1) {
        int idx = findBestMergePair(tokens, mergeRanks);
        if (idx < 0) break;

        // Merge tokens[idx] and tokens[idx+1]
        std::string merged = tokens[idx] + tokens[idx + 1];
        tokens[idx] = std::move(merged);
        tokens.erase(tokens.begin() + idx + 1);
    }
    return tokens;
}

// ── UTF-8 iteration helpers ──────────────────────────────────────────────────

/// Decode one UTF-8 codepoint from a string at position pos.
/// Advances pos past the decoded codepoint. Returns the codepoint.
static char32_t decodeUTF8Codepoint(const std::string &s, size_t &pos) {
    char32_t cp = 0;
    uint8_t c = static_cast<uint8_t>(s[pos]);
    int len = 1;

    if (c < 0x80) {
        cp = c;
    } else if ((c & 0xE0) == 0xC0) {
        cp = c & 0x1F; len = 2;
    } else if ((c & 0xF0) == 0xE0) {
        cp = c & 0x0F; len = 3;
    } else if ((c & 0xF8) == 0xF0) {
        cp = c & 0x07; len = 4;
    }

    // Clamp to prevent reading past end of string.
    if (pos + len > s.size()) {
        pos = s.size();
        return 0xFFFD;  // Replacement character for truncated sequence
    }
    for (int i = 1; i < len; ++i) {
        cp = (cp << 6) | (static_cast<uint8_t>(s[pos + i]) & 0x3F);
    }
    pos += len;
    return cp;
}

/// Split a GPT-2 byte-level token string into individual UTF-8 characters.
static std::vector<std::string> splitToUTF8Chars(const std::string &s) {
    std::vector<std::string> result;
    size_t pos = 0;
    while (pos < s.size()) {
        size_t start = pos;
        uint8_t c = static_cast<uint8_t>(s[pos]);
        int len = 1;
        if ((c & 0xE0) == 0xC0) len = 2;
        else if ((c & 0xF0) == 0xE0) len = 3;
        else if ((c & 0xF8) == 0xF0) len = 4;
        pos += len;
        result.push_back(s.substr(start, len));
    }
    return result;
}

// ── CJK detection ────────────────────────────────────────────────────────────

/// Languages that use character-based word splitting.
static bool isCJKLanguage(const std::string &lang) {
    static const std::unordered_set<std::string> cjkLangs = {
        "zh", "ja", "th", "lo", "my", "yue"
    };
    return cjkLangs.find(lang) != cjkLangs.end();
}

/// Check if a Unicode codepoint is a CJK character, Hiragana, Katakana, etc.
static bool isCJKCodepoint(char32_t cp) {
    // CJK Unified Ideographs
    if (cp >= 0x4E00 && cp <= 0x9FFF) return true;
    // CJK Extension A
    if (cp >= 0x3400 && cp <= 0x4DBF) return true;
    // CJK Extension B
    if (cp >= 0x20000 && cp <= 0x2A6DF) return true;
    // CJK Compatibility Ideographs
    if (cp >= 0xF900 && cp <= 0xFAFF) return true;
    // Hiragana
    if (cp >= 0x3040 && cp <= 0x309F) return true;
    // Katakana
    if (cp >= 0x30A0 && cp <= 0x30FF) return true;
    // Katakana Phonetic Extensions
    if (cp >= 0x31F0 && cp <= 0x31FF) return true;
    // Hangul Syllables
    if (cp >= 0xAC00 && cp <= 0xD7AF) return true;
    // Thai
    if (cp >= 0x0E00 && cp <= 0x0E7F) return true;
    // Lao
    if (cp >= 0x0E80 && cp <= 0x0EFF) return true;
    // Myanmar
    if (cp >= 0x1000 && cp <= 0x109F) return true;
    return false;
}

// ── Non-speech token symbols ─────────────────────────────────────────────────

/// Regular symbols for non-speech suppression.
/// From faster-whisper tokenizer.py non_speech_tokens property.
/// Only tokens that encode to a SINGLE token are included for these.
static const std::vector<std::string> &nonSpeechRegularSymbols() {
    static const std::vector<std::string> symbols = {
        "\"", "#", "(", ")", "*", "+", "/", ":", ";", "<", "=", ">", "@",
        "[", "\\", "]", "^", "_", "`", "{", "|", "}", "~",
        "\xe3\x80\x8c",   // U+300C 「
        "\xe3\x80\x8d",   // U+300D 」
        "\xe3\x80\x8e",   // U+300E 『
        "\xe3\x80\x8f",   // U+300F 』
        "<<", ">>", "<<<", ">>>", "--", "---",
        "-(", "-[", "('", "(\"",
        "((", "))", "(((", ")))", "[[", "]]", "{{", "}}",
        "\xe2\x99\xaa\xe2\x99\xaa",       // ♪♪
        "\xe2\x99\xaa\xe2\x99\xaa\xe2\x99\xaa",  // ♪♪♪
    };
    return symbols;
}

/// Miscellaneous symbols (U+2640 to U+267F range) for non-speech suppression.
/// For these, the FIRST token is always suppressed even for multi-token encodings.
static const std::vector<std::string> &nonSpeechMiscSymbols() {
    static const std::vector<std::string> symbols = {
        "\xe2\x99\xa9",   // U+2669 ♩
        "\xe2\x99\xaa",   // U+266A ♪
        "\xe2\x99\xab",   // U+266B ♫
        "\xe2\x99\xac",   // U+266C ♬
        "\xe2\x99\xad",   // U+266D ♭
        "\xe2\x99\xae",   // U+266E ♮
        "\xe2\x99\xaf",   // U+266F ♯
    };
    return symbols;
}

// ── Private ivar struct ──────────────────────────────────────────────────────

struct MWTokenizerImpl {
    // Vocab: token string <-> id
    std::unordered_map<std::string, size_t> tokenToID;
    std::unordered_map<size_t, std::string> idToToken;

    // BPE merge ranks
    std::unordered_map<std::string, int> mergeRanks;

    // GPT-2 byte mapping
    std::unordered_map<uint8_t, char32_t> b2u;
    std::unordered_map<char32_t, uint8_t> u2b;

    // Special token IDs (SIZE_MAX = unresolved sentinel)
    size_t sot = SIZE_MAX;
    size_t eot = SIZE_MAX;
    size_t sotPrev = SIZE_MAX;
    size_t sotLM = SIZE_MAX;
    size_t noTimestamps = SIZE_MAX;
    size_t noSpeech = SIZE_MAX;
    size_t timestampBegin = SIZE_MAX;
    size_t transcribeToken = SIZE_MAX;
    size_t translateToken = SIZE_MAX;
    size_t languageToken = SIZE_MAX;

    std::string languageCode;
    bool multilingual = false;

    size_t vocabSize = 0;

    // Cached non-speech tokens
    std::vector<size_t> nonSpeechTokenIDs;

    // sot sequence
    std::vector<size_t> sotSequence;
};

// ── MWTokenizer implementation ───────────────────────────────────────────────

@implementation MWTokenizer {
    MWTokenizerImpl *_impl;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                              multilingual:(BOOL)multilingual
                                      task:(nullable NSString *)task
                                  language:(nullable NSString *)language
                                     error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    _impl = new MWTokenizerImpl();

    @try {
        if (![self _loadTokenizerJSON:modelPath error:error]) {
            delete _impl;
            _impl = nullptr;
            [self release];
            return nil;
        }

        _impl->multilingual = multilingual;

        // Resolve language code
        if (language) {
            _impl->languageCode = [language UTF8String];
        } else {
            _impl->languageCode = multilingual ? "en" : "";
        }

        // Resolve language token
        if (multilingual && _impl->languageCode.size() > 0) {
            std::string langTokenStr = "<|" + _impl->languageCode + "|>";
            auto it = _impl->tokenToID.find(langTokenStr);
            if (it != _impl->tokenToID.end()) {
                _impl->languageToken = it->second;
            }
        }

        // Build sot sequence
        _impl->sotSequence.push_back(_impl->sot);
        if (multilingual) {
            _impl->sotSequence.push_back(_impl->languageToken);
            if (task) {
                std::string taskStr = [task UTF8String];
                if (taskStr == "translate") {
                    _impl->sotSequence.push_back(_impl->translateToken);
                } else {
                    _impl->sotSequence.push_back(_impl->transcribeToken);
                }
            } else {
                _impl->sotSequence.push_back(_impl->transcribeToken);
            }
        }

        // Build non-speech token set
        [self _buildNonSpeechTokens];

    } @catch (NSException *exception) {
        delete _impl;
        _impl = nullptr;
        MWSetError(error, MWErrorCodeTokenizerLoadFailed,
                   [NSString stringWithFormat:@"Exception loading tokenizer: %@", exception.reason]);
        [self release];
        return nil;
    }

    return self;
}

- (void)dealloc {
    delete _impl;
    _impl = nullptr;
    [super dealloc];
}

// ── JSON loading ─────────────────────────────────────────────────────────────

- (BOOL)_loadTokenizerJSON:(NSString *)modelPath error:(NSError **)error {
    NSString *tokenizerPath = [modelPath stringByAppendingPathComponent:@"tokenizer.json"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:tokenizerPath]) {
        MWSetError(error, MWErrorCodeTokenizerLoadFailed,
                   [NSString stringWithFormat:@"tokenizer.json not found at: %@", tokenizerPath]);
        return NO;
    }

    NSData *jsonData = [NSData dataWithContentsOfFile:tokenizerPath];
    if (!jsonData) {
        MWSetError(error, MWErrorCodeTokenizerLoadFailed,
                   @"Failed to read tokenizer.json");
        return NO;
    }

    NSError *parseError = nil;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:jsonData
                                                        options:0
                                                          error:&parseError];
    if (!root) {
        MWSetError(error, MWErrorCodeTokenizerLoadFailed,
                   [NSString stringWithFormat:@"JSON parse error: %@",
                    [parseError localizedDescription]]);
        return NO;
    }

    // Build byte mappings
    _impl->b2u = buildBytesToUnicode();
    _impl->u2b = buildUnicodeToBytes();

    // Parse model.vocab
    NSDictionary *model = root[@"model"];
    if (!model) {
        MWSetError(error, MWErrorCodeTokenizerLoadFailed, @"Missing 'model' key in tokenizer.json");
        return NO;
    }

    NSDictionary *vocab = model[@"vocab"];
    if (!vocab) {
        MWSetError(error, MWErrorCodeTokenizerLoadFailed, @"Missing 'model.vocab' key");
        return NO;
    }

    for (NSString *key in vocab) {
        @autoreleasepool {
            NSNumber *val = vocab[key];
            std::string tokenStr = [key UTF8String];
            size_t tokenID = [val unsignedIntegerValue];
            _impl->tokenToID[tokenStr] = tokenID;
            _impl->idToToken[tokenID] = tokenStr;
        }
    }

    // Parse model.merges
    NSArray *merges = model[@"merges"];
    if (!merges) {
        MWSetError(error, MWErrorCodeTokenizerLoadFailed, @"Missing 'model.merges' key");
        return NO;
    }

    for (NSUInteger i = 0; i < [merges count]; ++i) {
        @autoreleasepool {
            NSString *merge = merges[i];
            _impl->mergeRanks[[merge UTF8String]] = static_cast<int>(i);
        }
    }

    // Parse added_tokens
    NSArray *addedTokens = root[@"added_tokens"];
    if (addedTokens) {
        for (NSDictionary *tokenInfo in addedTokens) {
            NSString *content = tokenInfo[@"content"];
            NSNumber *tokenID = tokenInfo[@"id"];
            if (content && tokenID) {
                std::string tokenStr = [content UTF8String];
                size_t id = [tokenID unsignedIntegerValue];
                _impl->tokenToID[tokenStr] = id;
                _impl->idToToken[id] = tokenStr;
            }
        }
    }

    _impl->vocabSize = _impl->tokenToID.size();

    // Extract special token IDs from added_tokens
    if (![self _resolveSpecialTokens]) {
        MWSetError(error, MWErrorCodeTokenizerLoadFailed,
                   @"Critical special tokens (eot, sot) not found in tokenizer vocabulary");
        return NO;
    }

    return YES;
}

/// Resolve special token IDs from vocab.
/// Returns NO if critical tokens (eot, sot) are missing.
- (BOOL)_resolveSpecialTokens {
    auto lookup = [&](const std::string &name) -> size_t {
        auto it = _impl->tokenToID.find(name);
        if (it != _impl->tokenToID.end()) return it->second;
        return SIZE_MAX;  // Sentinel for not-found
    };

    _impl->eot = lookup("<|endoftext|>");
    _impl->sot = lookup("<|startoftranscript|>");
    _impl->translateToken = lookup("<|translate|>");
    _impl->transcribeToken = lookup("<|transcribe|>");
    _impl->sotLM = lookup("<|startoflm|>");
    _impl->sotPrev = lookup("<|startofprev|>");
    _impl->noSpeech = lookup("<|nospeech|>");
    _impl->noTimestamps = lookup("<|notimestamps|>");

    // timestamp_begin is <|0.00|>
    _impl->timestampBegin = lookup("<|0.00|>");

    // Validate critical tokens — eot and sot must be resolved.
    if (_impl->eot == SIZE_MAX || _impl->sot == SIZE_MAX) {
        return NO;
    }
    return YES;
}

// ── Non-speech tokens ────────────────────────────────────────────────────────

- (void)_buildNonSpeechTokens {
    std::unordered_set<size_t> result;

    // Step 1: Allow hyphens and single quotes between words, but not at word start.
    // Add the space-prefixed versions of "-" and "'".
    auto dashIDs = [self _encodeInternal:" -"];
    if (!dashIDs.empty()) result.insert(dashIDs[0]);

    auto quoteIDs = [self _encodeInternal:" '"];
    if (!quoteIDs.empty()) result.insert(quoteIDs[0]);

    // Step 2: Regular symbols — only add first token when encoding produces exactly 1 token.
    const auto &regular = nonSpeechRegularSymbols();
    for (const auto &symbol : regular) {
        auto idsPlain = [self _encodeInternal:symbol];
        if (idsPlain.size() == 1) {
            result.insert(idsPlain[0]);
        }

        std::string withSpace = " " + symbol;
        auto idsSpace = [self _encodeInternal:withSpace];
        if (idsSpace.size() == 1) {
            result.insert(idsSpace[0]);
        }
    }

    // Step 3: Miscellaneous symbols (♩♪♫♬♭♮♯) — always add first token,
    // even when encoding produces multiple tokens. These share the same
    // UTF-8 prefix bytes (U+2640-U+267F range).
    const auto &misc = nonSpeechMiscSymbols();
    for (const auto &symbol : misc) {
        auto idsPlain = [self _encodeInternal:symbol];
        if (!idsPlain.empty()) {
            result.insert(idsPlain[0]);
        }

        std::string withSpace = " " + symbol;
        auto idsSpace = [self _encodeInternal:withSpace];
        if (!idsSpace.empty()) {
            result.insert(idsSpace[0]);
        }
    }

    _impl->nonSpeechTokenIDs.assign(result.begin(), result.end());
    std::sort(_impl->nonSpeechTokenIDs.begin(), _impl->nonSpeechTokenIDs.end());
}

// ── BPE Encode ───────────────────────────────────────────────────────────────

- (std::vector<size_t>)_encodeInternal:(const std::string &)text {
    std::vector<size_t> result;
    if (text.empty()) return result;

    // Step 1: Convert raw UTF-8 bytes to GPT-2 byte-level unicode string
    std::string bpeInput = bytesToTokenString(text, _impl->b2u);

    // Step 2: Split into individual UTF-8 characters (each is a potential BPE token)
    std::vector<std::string> tokens = splitToUTF8Chars(bpeInput);

    // Step 3: Apply BPE merges
    tokens = applyBPEMerges(std::move(tokens), _impl->mergeRanks);

    // Step 4: Look up each BPE piece in vocab
    for (const auto &piece : tokens) {
        auto it = _impl->tokenToID.find(piece);
        if (it != _impl->tokenToID.end()) {
            result.push_back(it->second);
        }
        // Unknown tokens are silently dropped (should not happen with byte-level BPE)
    }

    return result;
}

- (NSArray<NSNumber *> *)encode:(NSString *)text {
    @try {
        std::string utf8Text = text ? [text UTF8String] : "";
        auto ids = [self _encodeInternal:utf8Text];

        NSMutableArray<NSNumber *> *result = [[NSMutableArray alloc] initWithCapacity:ids.size()];
        for (size_t id : ids) {
            [result addObject:@(id)];
        }
        return [result autorelease];
    } @catch (...) {
        return @[];
    }
}

// ── BPE Decode ───────────────────────────────────────────────────────────────

- (std::string)_decodeInternal:(const std::vector<size_t> &)ids {
    std::string tokenStr;
    for (size_t id : ids) {
        // Skip special tokens >= eot
        if (id >= _impl->eot) continue;

        auto it = _impl->idToToken.find(id);
        if (it != _impl->idToToken.end()) {
            tokenStr += it->second;
        }
    }

    // Convert GPT-2 unicode back to raw bytes
    return tokenStringToBytes(tokenStr, _impl->u2b);
}

- (NSString *)decode:(NSArray<NSNumber *> *)tokenIDs {
    @try {
        std::vector<size_t> ids;
        ids.reserve([tokenIDs count]);
        for (NSNumber *n in tokenIDs) {
            ids.push_back([n unsignedIntegerValue]);
        }

        std::string text = [self _decodeInternal:ids];
        return [NSString stringWithUTF8String:text.c_str()];
    } @catch (...) {
        return @"";
    }
}

- (NSString *)decodeWithTimestamps:(NSArray<NSNumber *> *)tokenIDs {
    @try {
        NSMutableString *result = [[NSMutableString alloc] init];
        std::vector<size_t> pending;

        for (NSNumber *n in tokenIDs) {
            size_t id = [n unsignedIntegerValue];

            if (id >= _impl->timestampBegin) {
                // Flush pending text tokens
                if (!pending.empty()) {
                    std::string text = [self _decodeInternal:pending];
                    [result appendString:[NSString stringWithUTF8String:text.c_str()]];
                    pending.clear();
                }

                // Emit timestamp marker
                double timestamp = (double)(id - _impl->timestampBegin) * kTimestampPrecision;
                [result appendFormat:@"<|%.2f|>", timestamp];
            } else if (id == _impl->noTimestamps || id == _impl->sot) {
                // Skip these special tokens
                continue;
            } else if (id >= _impl->eot) {
                // Skip other special tokens
                continue;
            } else {
                pending.push_back(id);
            }
        }

        // Flush remaining
        if (!pending.empty()) {
            std::string text = [self _decodeInternal:pending];
            [result appendString:[NSString stringWithUTF8String:text.c_str()]];
        }

        return [result autorelease];
    } @catch (...) {
        return @"";
    }
}

// ── Word splitting ───────────────────────────────────────────────────────────

- (void)splitToWordTokens:(NSArray<NSNumber *> *)tokenIDs
                    words:(NSArray<NSString *> * _Nonnull * _Nonnull)outWords
               wordTokens:(NSArray<NSArray<NSNumber *> *> * _Nonnull * _Nonnull)outWordTokens {
    @try {
        if (isCJKLanguage(_impl->languageCode)) {
            [self _splitOnUnicode:tokenIDs words:outWords wordTokens:outWordTokens];
        } else {
            [self _splitOnSpaces:tokenIDs words:outWords wordTokens:outWordTokens];
        }
    } @catch (...) {
        *outWords = @[];
        *outWordTokens = @[];
    }
}

/// Split tokens on spaces (for Latin-script languages).
/// Each token that starts with the GPT-2 space character (Ġ) begins a new word,
/// except we also split punctuation into its own word.
- (void)_splitOnSpaces:(NSArray<NSNumber *> *)tokenIDs
                 words:(NSArray<NSString *> * _Nonnull * _Nonnull)outWords
            wordTokens:(NSArray<NSArray<NSNumber *> *> * _Nonnull * _Nonnull)outWordTokens {
    NSMutableArray<NSString *> *words = [[NSMutableArray alloc] init];
    NSMutableArray<NSArray<NSNumber *> *> *wordToks = [[NSMutableArray alloc] init];

    for (NSNumber *tokenNum in tokenIDs) {
        size_t tokenID = [tokenNum unsignedIntegerValue];
        if (tokenID >= _impl->eot) continue;

        auto it = _impl->idToToken.find(tokenID);
        if (it == _impl->idToToken.end()) continue;

        const std::string &tokenStr = it->second;

        // Decode to actual text
        std::string decoded = tokenStringToBytes(tokenStr, _impl->u2b);
        NSString *text = [NSString stringWithUTF8String:decoded.c_str()];

        // Each token is its own word for space-based splitting
        // (Whisper tokens rarely span word boundaries)
        [words addObject:text];
        [wordToks addObject:@[tokenNum]];
    }

    *outWords = [words autorelease];
    *outWordTokens = [wordToks autorelease];
}

/// Split tokens on unicode characters (for CJK languages).
/// Decode each token to text, then split the text into individual unicode characters.
/// Characters from the same token that are adjacent CJK stay grouped as one word
/// only when they come from the same token.
///
/// The Python reference (split_tokens_on_unicode) decodes each token individually
/// and treats each token's decoded text as one word.
- (void)_splitOnUnicode:(NSArray<NSNumber *> *)tokenIDs
                  words:(NSArray<NSString *> * _Nonnull * _Nonnull)outWords
             wordTokens:(NSArray<NSArray<NSNumber *> *> * _Nonnull * _Nonnull)outWordTokens {
    NSMutableArray<NSString *> *words = [[NSMutableArray alloc] init];
    NSMutableArray<NSArray<NSNumber *> *> *wordToks = [[NSMutableArray alloc] init];

    for (NSNumber *tokenNum in tokenIDs) {
        size_t tokenID = [tokenNum unsignedIntegerValue];
        if (tokenID >= _impl->eot) continue;

        auto it = _impl->idToToken.find(tokenID);
        if (it == _impl->idToToken.end()) continue;

        const std::string &tokenStr = it->second;
        std::string decoded = tokenStringToBytes(tokenStr, _impl->u2b);
        NSString *text = [NSString stringWithUTF8String:decoded.c_str()];

        if ([text length] > 0) {
            [words addObject:text];
            [wordToks addObject:@[tokenNum]];
        }
    }

    *outWords = [words autorelease];
    *outWordTokens = [wordToks autorelease];
}

// ── Properties ───────────────────────────────────────────────────────────────

- (NSUInteger)sot { return _impl->sot; }
- (NSUInteger)eot { return _impl->eot; }
- (NSUInteger)sotPrev { return _impl->sotPrev; }
- (NSUInteger)sotLM { return _impl->sotLM; }
- (NSUInteger)noTimestamps { return _impl->noTimestamps; }
- (NSUInteger)noSpeech { return _impl->noSpeech; }
- (NSUInteger)timestampBegin { return _impl->timestampBegin; }
- (NSUInteger)transcribeToken { return _impl->transcribeToken; }
- (NSUInteger)translateToken { return _impl->translateToken; }
- (NSUInteger)languageToken { return _impl->languageToken; }

- (NSString *)languageCode {
    return [NSString stringWithUTF8String:_impl->languageCode.c_str()];
}

- (NSArray<NSNumber *> *)sotSequence {
    NSMutableArray<NSNumber *> *seq = [[NSMutableArray alloc] initWithCapacity:_impl->sotSequence.size()];
    for (size_t id : _impl->sotSequence) {
        [seq addObject:@(id)];
    }
    return [seq autorelease];
}

- (NSUInteger)vocabSize { return _impl->vocabSize; }

- (NSUInteger)tokenIDForString:(NSString *)tokenString {
    if (!tokenString) return NSNotFound;
    std::string key = [tokenString UTF8String];
    auto it = _impl->tokenToID.find(key);
    if (it != _impl->tokenToID.end()) {
        return (NSUInteger)it->second;
    }
    return NSNotFound;
}

- (NSArray<NSNumber *> *)nonSpeechTokens {
    NSMutableArray<NSNumber *> *result = [[NSMutableArray alloc]
        initWithCapacity:_impl->nonSpeechTokenIDs.size()];
    for (size_t id : _impl->nonSpeechTokenIDs) {
        [result addObject:@(id)];
    }
    return [result autorelease];
}

@end
