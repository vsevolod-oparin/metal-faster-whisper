"""Generate reference audio decode outputs from faster-whisper's decode_audio().

Saves raw float32 samples and metadata as JSON for each test file.
Run from the metal-faster-whisper directory:
    python tests/generate_reference.py
"""
import json
import struct
import sys
import os

import importlib.util
import numpy as np

# Import audio.py directly to avoid the full faster_whisper import chain
# (which requires ctranslate2 Python bindings).
audio_path = os.path.join(os.path.dirname(__file__), '../../faster-whisper/faster_whisper/audio.py')
spec = importlib.util.spec_from_file_location("audio", audio_path)
audio_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio_mod)
decode_audio = audio_mod.decode_audio
pad_or_trim = audio_mod.pad_or_trim

DATA_DIR = os.path.join(os.path.dirname(__file__), 'data')
REF_DIR = os.path.join(DATA_DIR, 'reference')
os.makedirs(REF_DIR, exist_ok=True)

test_files = [
    'physicsworks.wav',
    'hotwords.mp3',
    'jfk.flac',
    'stereo_diarization.wav',
]

for fname in test_files:
    path = os.path.join(DATA_DIR, fname)
    if not os.path.exists(path):
        print(f"SKIP: {fname} not found")
        continue

    # Decode to 16kHz mono float32 (default)
    audio = decode_audio(path, sampling_rate=16000, split_stereo=False)
    base = os.path.splitext(fname)[0]

    # Save raw float32 samples
    raw_path = os.path.join(REF_DIR, f'{base}_16khz_mono.raw')
    audio.astype(np.float32).tofile(raw_path)

    # Save metadata
    meta = {
        'source_file': fname,
        'sample_rate': 16000,
        'channels': 1,
        'num_samples': len(audio),
        'duration_seconds': len(audio) / 16000.0,
        'first_100_samples': audio[:100].tolist(),
        'dtype': 'float32',
    }
    meta_path = os.path.join(REF_DIR, f'{base}_16khz_mono.json')
    with open(meta_path, 'w') as f:
        json.dump(meta, f, indent=2)

    print(f"OK: {fname} -> {len(audio)} samples ({len(audio)/16000:.2f}s)")

# Also generate stereo reference for stereo_diarization.wav
stereo_path = os.path.join(DATA_DIR, 'stereo_diarization.wav')
if os.path.exists(stereo_path):
    left, right = decode_audio(stereo_path, sampling_rate=16000, split_stereo=True)
    left.astype(np.float32).tofile(os.path.join(REF_DIR, 'stereo_diarization_left.raw'))
    right.astype(np.float32).tofile(os.path.join(REF_DIR, 'stereo_diarization_right.raw'))
    meta = {
        'source_file': 'stereo_diarization.wav',
        'sample_rate': 16000,
        'left_samples': len(left),
        'right_samples': len(right),
        'first_100_left': left[:100].tolist(),
        'first_100_right': right[:100].tolist(),
    }
    with open(os.path.join(REF_DIR, 'stereo_diarization_split.json'), 'w') as f:
        json.dump(meta, f, indent=2)
    print(f"OK: stereo split -> L={len(left)}, R={len(right)}")

# Pad/trim reference
audio_short = np.array([1.0, 2.0, 3.0], dtype=np.float32)
padded = pad_or_trim(audio_short, length=10)
audio_long = np.arange(20, dtype=np.float32)
trimmed = pad_or_trim(audio_long, length=10)
ref = {
    'pad_input': audio_short.tolist(),
    'pad_length': 10,
    'pad_output': padded.tolist(),
    'trim_input': audio_long.tolist(),
    'trim_length': 10,
    'trim_output': trimmed.tolist(),
}
with open(os.path.join(REF_DIR, 'pad_or_trim.json'), 'w') as f:
    json.dump(ref, f, indent=2)
print("OK: pad_or_trim reference")
