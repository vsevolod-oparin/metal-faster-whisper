"""Generate Python faster-whisper reference data for token-exact comparison.

Run: python tests/generate_python_reference.py

Produces tests/data/reference/python_transcription_*.json for each test audio.
"""
import json
import os
import sys
import time

from faster_whisper import WhisperModel
from faster_whisper.audio import decode_audio

DATA_DIR = os.path.join(os.path.dirname(__file__), 'data')
REF_DIR = os.path.join(DATA_DIR, 'reference')
os.makedirs(REF_DIR, exist_ok=True)

MODEL_DIR = os.path.join(os.path.dirname(__file__),
    '../../whisper-metal/models/whisper-large-v3-turbo')

print(f"Loading model from {MODEL_DIR}...")
model = WhisperModel(MODEL_DIR, device='cpu', compute_type='float32')
print("Model loaded.")

test_files = [
    ('jfk.flac', 'en'),
    ('physicsworks.wav', 'en'),
    ('russian_60s.wav', 'ru'),
]

for fname, lang in test_files:
    path = os.path.join(DATA_DIR, fname)
    if not os.path.exists(path):
        print(f"SKIP: {fname} not found")
        continue

    print(f"\nTranscribing {fname} (language={lang})...")
    t0 = time.time()

    # Greedy decoding with beam=6 (matching MetalWhisper defaults)
    segments, info = model.transcribe(
        path,
        language=lang,
        beam_size=6,
        temperature=0.0,
        condition_on_previous_text=True,
        word_timestamps=True,
        length_penalty=0.6,
    )

    result = {
        'file': fname,
        'language': info.language,
        'language_probability': info.language_probability,
        'duration': info.duration,
        'params': {
            'beam_size': 6,
            'temperature': 0.0,
            'length_penalty': 0.6,
            'condition_on_previous_text': True,
            'word_timestamps': True,
        },
        'segments': [],
    }

    for seg in segments:
        seg_data = {
            'id': seg.id,
            'start': round(seg.start, 3),
            'end': round(seg.end, 3),
            'text': seg.text,
            'tokens': list(seg.tokens),
            'temperature': seg.temperature,
            'avg_logprob': round(seg.avg_logprob, 6),
            'compression_ratio': round(seg.compression_ratio, 4),
            'no_speech_prob': round(seg.no_speech_prob, 6),
        }
        if seg.words:
            seg_data['words'] = [
                {
                    'word': w.word,
                    'start': round(w.start, 3),
                    'end': round(w.end, 3),
                    'probability': round(w.probability, 4),
                }
                for w in seg.words
            ]
        result['segments'].append(seg_data)

    elapsed = time.time() - t0
    base = os.path.splitext(fname)[0]
    out_path = os.path.join(REF_DIR, f'python_transcription_{base}.json')
    with open(out_path, 'w') as f:
        json.dump(result, f, indent=2, ensure_ascii=False)

    n_segs = len(result['segments'])
    n_words = sum(len(s.get('words', [])) for s in result['segments'])
    print(f"  {n_segs} segments, {n_words} words, {elapsed:.1f}s")
    print(f"  Text: {result['segments'][0]['text'][:80]}...")
    print(f"  Saved: {out_path}")

print("\nDone.")
