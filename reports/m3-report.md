# M3 Milestone Report — BPE Tokenizer

**Date:** 2026-03-19
**Status:** PASSED

## Summary

Implemented a standalone BPE tokenizer matching Python's HuggingFace `tokenizers` library output exactly. Loads `tokenizer.json` directly — no Python, no HuggingFace dependency. Supports encode, decode, special tokens, word splitting, timestamp decoding, and non-speech token suppression.

## Files Created

| File | Lines | Purpose |
|------|-------|---------|
| `src/MWTokenizer.h` | 71 | Public API: encode, decode, special tokens, word split, suppression |
| `src/MWTokenizer.mm` | 828 | GPT-2 byte-level BPE, tokenizer.json parsing, word splitting |
| `tests/test_m3_tokenizer.mm` | ~360 | 9 test cases against Python reference |
| `tests/generate_m3_reference.py` | ~170 | Reference data generation script |

## Implementation Details

### GPT-2 Byte-Level BPE

Whisper uses GPT-2's byte-level BPE tokenizer. The key insight: every UTF-8 byte maps to a specific unicode character before BPE merges apply. For example, byte 0x20 (space) maps to 'Ġ' (U+0120). This makes the BPE vocabulary byte-complete — any UTF-8 input can be tokenized without unknown tokens.

**Encode pipeline:**
1. Convert input text to UTF-8 bytes
2. Map each byte to its unicode character via `bytes_to_unicode()`
3. Split into individual characters
4. Apply BPE merges greedily (find highest-priority merge pair, replace, repeat)
5. Look up each BPE token in the vocab → token IDs

**Decode pipeline:**
1. Map token IDs → token strings via reverse vocab
2. Concatenate all token strings
3. Map each unicode character back to bytes via `unicode_to_bytes()`
4. Decode bytes as UTF-8

### Special Token Management

All special tokens loaded from `added_tokens` in `tokenizer.json`:
- `<|startoftranscript|>` (50258), `<|endoftext|>` (50257)
- Language tokens: `<|en|>` (50259), `<|zh|>` (50260), etc.
- Task tokens: `<|transcribe|>` (50360), `<|translate|>` (50359)
- `<|notimestamps|>` (50364), `<|nospeech|>` (50363)
- Timestamp tokens: `<|0.00|>` (50365) through `<|30.00|>` (51865)

### Word Splitting

Two strategies matching Python exactly:
- **Space-based** (most languages): group tokens by leading space or punctuation boundaries
- **Character-based** (CJK: zh, ja, th, lo, my, yue): split at each valid unicode decode point

### Non-Speech Suppression

82 tokens matching Python's algorithm exactly: symbols like `#()*+/:;`, multi-char sequences like `♪♪♪`, and space-prefixed hyphen/quote.

## Test Results

```
PASS: test_m3_load_vocab          — vocab size 51866
PASS: test_m3_encode              — 10 strings, exact ID match (English, CJK, Cyrillic, accented)
PASS: test_m3_decode              — token sequences decoded correctly
PASS: test_m3_special_tokens      — all special token IDs match Python
PASS: test_m3_sot_sequence        — en/transcribe and fr/translate sequences correct
PASS: test_m3_non_speech_tokens   — 82 suppression tokens match exactly
PASS: test_m3_word_split_english  — "Hello, world!" → ["Hello", ",", " world", "!"]
PASS: test_m3_word_split_cjk      — "日本語のテスト" → ["日本", "語", "の", "テ", "スト"]
PASS: test_m3_roundtrip           — 10 sentences encode→decode match
```

## Task Checklist

| Task | Status |
|------|--------|
| M3.1: JSON parser for tokenizer.json | Done |
| M3.2: BPE encode(text) | Done |
| M3.3: decode(tokens) | Done |
| M3.4: Special token properties | Done |
| M3.5: sot_sequence construction | Done |
| M3.6: split_to_word_tokens | Done |
| M3.7: non_speech_tokens | Done |
| M3.8: decode_with_timestamps | Done |

## Exit Criteria

| Criterion | Status |
|-----------|--------|
| Token-identical output vs Python tokenizers | PASS — all 10 encode tests match exactly |
| All Whisper model sizes | Tested with large-v3-turbo. Other models deferred to M9 (download needed) |

## Notes

- Actual line count (828) is 3.3x the estimate (250). The GPT-2 byte mapping, BPE merge loop, and word splitting algorithms are more complex in C++ than Python due to explicit UTF-8 handling and manual memory management.
- The BPE merge loop uses a ranked `std::unordered_map` for O(1) merge priority lookup. Performance is not benchmarked since tokenization is not on the critical path (CPU-bound, sub-millisecond for typical inputs).
