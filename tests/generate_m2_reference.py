"""Generate reference mel spectrogram data from faster-whisper's FeatureExtractor.

Run from the metal-faster-whisper directory:
    python tests/generate_m2_reference.py
"""
import json
import os
import sys
import importlib.util
import numpy as np

# Import feature_extractor.py directly
fe_path = os.path.join(os.path.dirname(__file__), '../../faster-whisper/faster_whisper/feature_extractor.py')
spec = importlib.util.spec_from_file_location("feature_extractor", fe_path)
fe_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fe_mod)
FeatureExtractor = fe_mod.FeatureExtractor

DATA_DIR = os.path.join(os.path.dirname(__file__), 'data')
REF_DIR = os.path.join(DATA_DIR, 'reference')
os.makedirs(REF_DIR, exist_ok=True)

# --- 1. Mel filterbank reference (n_mels=80, n_fft=400, sr=16000) ---
fe80 = FeatureExtractor(feature_size=80, n_fft=400, sampling_rate=16000)
filters80 = fe80.mel_filters  # shape: (80, 201)
filters80.astype(np.float32).tofile(os.path.join(REF_DIR, 'mel_filters_80.raw'))
meta = {
    'n_mels': 80, 'n_fft': 400, 'sr': 16000,
    'shape': list(filters80.shape),
    'dtype': 'float32',
    'max_val': float(filters80.max()),
    'min_val': float(filters80.min()),
}
with open(os.path.join(REF_DIR, 'mel_filters_80.json'), 'w') as f:
    json.dump(meta, f, indent=2)
print(f"OK: mel_filters_80 shape={filters80.shape}")

# --- 1b. Mel filterbank for n_mels=128 (large-v3/turbo) ---
fe128 = FeatureExtractor(feature_size=128, n_fft=400, sampling_rate=16000)
filters128 = fe128.mel_filters
filters128.astype(np.float32).tofile(os.path.join(REF_DIR, 'mel_filters_128.raw'))
meta128 = {
    'n_mels': 128, 'n_fft': 400, 'sr': 16000,
    'shape': list(filters128.shape),
    'dtype': 'float32',
}
with open(os.path.join(REF_DIR, 'mel_filters_128.json'), 'w') as f:
    json.dump(meta128, f, indent=2)
print(f"OK: mel_filters_128 shape={filters128.shape}")

# --- 2. STFT reference (known signal) ---
# Generate a simple test signal: 1 second of 440 Hz sine wave at 16 kHz
sr = 16000
t = np.arange(sr, dtype=np.float32) / sr
signal = np.sin(2 * np.pi * 440 * t).astype(np.float32)
n_fft = 400
hop_length = 160
window = np.hanning(n_fft + 1)[:-1].astype(np.float32)

stft_out = FeatureExtractor.stft(signal, n_fft, hop_length, window=window, return_complex=True)
# stft_out shape: (201, n_frames)
magnitudes_sq = np.abs(stft_out[..., :-1]) ** 2  # drop last frame

signal.tofile(os.path.join(REF_DIR, 'stft_test_signal.raw'))
magnitudes_sq.astype(np.float32).tofile(os.path.join(REF_DIR, 'stft_magnitudes_sq.raw'))
meta_stft = {
    'n_fft': n_fft, 'hop_length': hop_length, 'sr': sr,
    'signal_samples': len(signal),
    'stft_shape': list(stft_out.shape),
    'magnitudes_sq_shape': list(magnitudes_sq.shape),
    'dtype': 'float32',
}
with open(os.path.join(REF_DIR, 'stft_reference.json'), 'w') as f:
    json.dump(meta_stft, f, indent=2)
print(f"OK: STFT shape={stft_out.shape}, magnitudes_sq shape={magnitudes_sq.shape}")

# --- 3. Full pipeline reference: physicsworks.wav (30s chunk) ---
# Load the raw decoded audio
raw_path = os.path.join(REF_DIR, 'physicsworks_16khz_mono.raw')
audio = np.fromfile(raw_path, dtype=np.float32)

# Take first 30s (480000 samples at 16kHz)
audio_30s = audio[:480000]

# Run through the FeatureExtractor with n_mels=80 (standard whisper)
fe = FeatureExtractor(feature_size=80, sampling_rate=16000, hop_length=160, chunk_length=30, n_fft=400)
mel_80 = fe(audio_30s)  # shape: (80, 3000)
mel_80.astype(np.float32).tofile(os.path.join(REF_DIR, 'mel_physicsworks_30s_80.raw'))
meta_mel80 = {
    'source': 'physicsworks.wav first 30s',
    'n_mels': 80, 'shape': list(mel_80.shape),
    'max_val': float(mel_80.max()), 'min_val': float(mel_80.min()),
}
with open(os.path.join(REF_DIR, 'mel_physicsworks_30s_80.json'), 'w') as f:
    json.dump(meta_mel80, f, indent=2)
print(f"OK: mel_80 shape={mel_80.shape} range=[{mel_80.min():.4f}, {mel_80.max():.4f}]")

# Also with n_mels=128 (for large-v3/turbo)
fe128full = FeatureExtractor(feature_size=128, sampling_rate=16000, hop_length=160, chunk_length=30, n_fft=400)
mel_128 = fe128full(audio_30s)
mel_128.astype(np.float32).tofile(os.path.join(REF_DIR, 'mel_physicsworks_30s_128.raw'))
meta_mel128 = {
    'source': 'physicsworks.wav first 30s',
    'n_mels': 128, 'shape': list(mel_128.shape),
    'max_val': float(mel_128.max()), 'min_val': float(mel_128.min()),
}
with open(os.path.join(REF_DIR, 'mel_physicsworks_30s_128.json'), 'w') as f:
    json.dump(meta_mel128, f, indent=2)
print(f"OK: mel_128 shape={mel_128.shape} range=[{mel_128.min():.4f}, {mel_128.max():.4f}]")

# --- 4. Short audio reference (5s → should pad to 3000 frames) ---
audio_5s = audio[:80000]  # 5 seconds
mel_short = fe(audio_5s)
mel_short.astype(np.float32).tofile(os.path.join(REF_DIR, 'mel_short_5s_80.raw'))
meta_short = {
    'source': 'physicsworks.wav first 5s',
    'input_samples': len(audio_5s),
    'n_mels': 80, 'shape': list(mel_short.shape),
}
with open(os.path.join(REF_DIR, 'mel_short_5s_80.json'), 'w') as f:
    json.dump(meta_short, f, indent=2)
print(f"OK: mel_short shape={mel_short.shape}")
