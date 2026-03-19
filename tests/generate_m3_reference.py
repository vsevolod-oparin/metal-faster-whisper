"""Generate reference tokenizer data from HuggingFace tokenizers (same as faster-whisper uses).

Run: python tests/generate_m3_reference.py
"""
import json
import os
import tokenizers

DATA_DIR = os.path.join(os.path.dirname(__file__), 'data')
REF_DIR = os.path.join(DATA_DIR, 'reference')
os.makedirs(REF_DIR, exist_ok=True)

MODEL_DIR = os.path.join(os.path.dirname(__file__),
    '../../whisper-metal/models/whisper-large-v3-turbo')

tok = tokenizers.Tokenizer.from_file(os.path.join(MODEL_DIR, 'tokenizer.json'))

ref = {}

# --- Special token IDs ---
special = {}
for name, token_str in [
    ('sot', '<|startoftranscript|>'),
    ('eot', '<|endoftext|>'),
    ('translate', '<|translate|>'),
    ('transcribe', '<|transcribe|>'),
    ('sot_lm', '<|startoflm|>'),
    ('sot_prev', '<|startofprev|>'),
    ('no_speech', '<|nospeech|>'),
    ('no_timestamps', '<|notimestamps|>'),
]:
    special[name] = tok.token_to_id(token_str)

# timestamp_begin = no_timestamps + 1
special['timestamp_begin'] = special['no_timestamps'] + 1

# Language tokens
for lang in ['en', 'zh', 'ja', 'fr', 'de', 'es', 'ko', 'ru']:
    special[f'lang_{lang}'] = tok.token_to_id(f'<|{lang}|>')

ref['special_tokens'] = special

# --- Encode tests ---
encode_tests = [
    "Hello, world!",
    " Hello, world!",
    "The quick brown fox jumps over the lazy dog.",
    "日本語のテスト",
    "Привет мир",
    "",
    " ",
    "It's a beautiful day!",
    "1234567890",
    "café résumé naïve",
]
encode_results = {}
for text in encode_tests:
    ids = tok.encode(text, add_special_tokens=False).ids
    encode_results[text] = ids
ref['encode'] = encode_results

# --- Decode tests ---
decode_tests = {
    'hello_world': [15947, 11, 1002, 0],
    'timestamps': [50364, 50365, 400, 370, 938, 50615],  # <|notimestamps|><|0.02|>...
    'simple': [400, 370, 938],
}
decode_results = {}
for name, ids in decode_tests.items():
    # Filter tokens < eot for decode
    eot = special['eot']
    text_tokens = [t for t in ids if t < eot]
    text = tok.decode(text_tokens)
    decode_results[name] = {'ids': ids, 'text': text}
ref['decode'] = decode_results

# --- sot_sequence for English transcribe (multilingual model) ---
sot_seq_en_transcribe = [special['sot'], special['lang_en'], special['transcribe']]
ref['sot_sequence_en_transcribe'] = sot_seq_en_transcribe

sot_seq_fr_translate = [special['sot'], special['lang_fr'], special['translate']]
ref['sot_sequence_fr_translate'] = sot_seq_fr_translate

# --- non_speech_tokens ---
# Port the logic from faster-whisper tokenizer.py
import string as string_mod

symbols = list('"#()*+/:;<=>@[\\]^_`{|}~「」『』')
symbols += "<< >> <<< >>> -- --- -( -[ (' (\" (( )) ((( ))) [[ ]] {{ }} ♪♪ ♪♪♪".split()
miscellaneous = set("♩♪♫♬♭♮♯")

result = set()
result.add(tok.encode(" -", add_special_tokens=False).ids[0])
result.add(tok.encode(" '", add_special_tokens=False).ids[0])

for symbol in symbols + list(miscellaneous):
    for text in [symbol, " " + symbol]:
        tokens = tok.encode(text, add_special_tokens=False).ids
        if len(tokens) == 1 or symbol in miscellaneous:
            result.add(tokens[0])

ref['non_speech_tokens'] = sorted(result)

# --- Word split tests ---
# split_tokens_on_spaces for English
def split_tokens_on_unicode(tokens, tok_obj, eot_id):
    from functools import lru_cache
    def decode_tokens(toks):
        text_toks = [t for t in toks if t < eot_id]
        return tok_obj.decode(text_toks)

    decoded_full = decode_tokens(tokens)
    replacement_char = "\ufffd"
    words = []
    word_tokens = []
    current_tokens = []
    unicode_offset = 0

    for token in tokens:
        current_tokens.append(token)
        decoded = decode_tokens(current_tokens)
        try:
            rci = decoded.index(replacement_char)
            rci += unicode_offset
        except ValueError:
            rci = None

        if rci is None or (rci < len(decoded_full) and decoded_full[rci] == replacement_char):
            words.append(decoded)
            word_tokens.append(current_tokens)
            current_tokens = []
            unicode_offset += len(decoded)

    return words, word_tokens

def split_tokens_on_spaces(tokens, tok_obj, eot_id):
    subwords, subword_tokens_list = split_tokens_on_unicode(tokens, tok_obj, eot_id)
    words = []
    word_tokens = []

    for subword, subword_tokens in zip(subwords, subword_tokens_list):
        special = subword_tokens[0] >= eot_id
        with_space = subword.startswith(" ")
        punctuation = subword.strip() in string_mod.punctuation
        if special or with_space or punctuation or len(words) == 0:
            words.append(subword)
            word_tokens.append(subword_tokens)
        else:
            words[-1] = words[-1] + subword
            word_tokens[-1].extend(subword_tokens)

    return words, word_tokens

# English word split
hello_ids = tok.encode("Hello, world!", add_special_tokens=False).ids
en_words, en_word_tokens = split_tokens_on_spaces(hello_ids, tok, special['eot'])
ref['word_split_english'] = {
    'input_ids': hello_ids,
    'words': en_words,
    'word_tokens': en_word_tokens,
}

# CJK word split (character-level)
jp_ids = tok.encode("日本語のテスト", add_special_tokens=False).ids
jp_words, jp_word_tokens = split_tokens_on_unicode(jp_ids, tok, special['eot'])
ref['word_split_cjk'] = {
    'input_ids': jp_ids,
    'words': jp_words,
    'word_tokens': jp_word_tokens,
}

# --- Roundtrip test sentences ---
roundtrip_sentences = [
    "Hello, world!",
    "The quick brown fox jumps over the lazy dog.",
    "Testing 1, 2, 3!",
    "café résumé naïve über",
    "日本語のテスト",
    "Привет мир",
    "It's a beautiful day.",
    "Hello\nWorld",
    "  multiple   spaces  ",
    "Special chars: @#$%",
]
roundtrip = {}
for s in roundtrip_sentences:
    ids = tok.encode(s, add_special_tokens=False).ids
    decoded = tok.decode(ids)
    roundtrip[s] = {'ids': ids, 'decoded': decoded}
ref['roundtrip'] = roundtrip

# --- Vocab info ---
ref['vocab_size'] = tok.get_vocab_size()

# Save
with open(os.path.join(REF_DIR, 'tokenizer_reference.json'), 'w') as f:
    json.dump(ref, f, indent=2, ensure_ascii=False)

print(f"OK: tokenizer reference saved")
print(f"  vocab_size: {ref['vocab_size']}")
print(f"  special tokens: {len(ref['special_tokens'])}")
print(f"  encode tests: {len(ref['encode'])}")
print(f"  non_speech_tokens: {len(ref['non_speech_tokens'])}")
print(f"  word_split_english words: {en_words}")
print(f"  word_split_cjk words: {jp_words}")
