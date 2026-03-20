"""Generate reference VAD data from faster-whisper's vad.py.

Run: python tests/generate_m6_reference.py
"""
import json
import os
import sys
import importlib.util
import numpy as np

# Import vad.py and audio.py directly
FW_DIR = os.path.join(os.path.dirname(__file__), '../../faster-whisper/faster_whisper')

audio_spec = importlib.util.spec_from_file_location("audio", os.path.join(FW_DIR, "audio.py"))
audio_mod = importlib.util.module_from_spec(audio_spec)
audio_spec.loader.exec_module(audio_mod)
decode_audio = audio_mod.decode_audio

# For vad.py we need utils.py too
utils_spec = importlib.util.spec_from_file_location("utils", os.path.join(FW_DIR, "utils.py"))
utils_mod = importlib.util.module_from_spec(utils_spec)
sys.modules['faster_whisper.utils'] = utils_mod
utils_spec.loader.exec_module(utils_mod)

vad_spec = importlib.util.spec_from_file_location("vad", os.path.join(FW_DIR, "vad.py"))
vad_mod = importlib.util.module_from_spec(vad_spec)
vad_spec.loader.exec_module(vad_mod)

DATA_DIR = os.path.join(os.path.dirname(__file__), 'data')
REF_DIR = os.path.join(DATA_DIR, 'reference')
os.makedirs(REF_DIR, exist_ok=True)

ref = {}

# --- 1. Speech probabilities on physicsworks.wav (first 30s) ---
audio = decode_audio(os.path.join(DATA_DIR, 'physicsworks.wav'), sampling_rate=16000)
audio_30s = audio[:480000]  # 30s

# Pad to multiple of 512
padded = np.pad(audio_30s, (0, 512 - len(audio_30s) % 512))
model = vad_mod.get_vad_model()
probs = model(padded)

ref['speech_probs_30s'] = {
    'audio_samples': len(audio_30s),
    'padded_samples': len(padded),
    'num_chunks': len(probs),
    'probs': [float(p) for p in probs.flatten()],
}
print(f"OK: speech_probs_30s — {len(probs)} chunks")

# --- 2. Full get_speech_timestamps on physicsworks.wav ---
timestamps = vad_mod.get_speech_timestamps(audio_30s)
ref['timestamps_30s'] = [{'start': int(t['start']), 'end': int(t['end'])} for t in timestamps]
print(f"OK: timestamps_30s — {len(timestamps)} speech segments")
for t in timestamps:
    print(f"  [{t['start']/16000:.2f}s - {t['end']/16000:.2f}s]")

# --- 3. collect_chunks ---
audio_chunks, chunks_metadata = vad_mod.collect_chunks(audio_30s, timestamps)
ref['collect_chunks_30s'] = {
    'num_chunks': len(audio_chunks),
    'total_speech_samples': sum(len(c) for c in audio_chunks),
    'metadata': chunks_metadata,
}
print(f"OK: collect_chunks — {len(audio_chunks)} chunks, {sum(len(c) for c in audio_chunks)} speech samples")

# --- 4. SpeechTimestampsMap ---
ts_map = vad_mod.SpeechTimestampsMap(timestamps, sampling_rate=16000)
# Test restoring a few times
test_times = [0.0, 1.0, 5.0, 10.0, 15.0, 20.0, 25.0, 29.0]
restored = {}
for t in test_times:
    orig = ts_map.get_original_time(t)
    restored[str(t)] = orig
ref['timestamp_map'] = {
    'test_times': test_times,
    'restored_times': restored,
    'chunk_end_sample': ts_map.chunk_end_sample,
    'total_silence_before': ts_map.total_silence_before,
}
print(f"OK: timestamp_map — {len(test_times)} test points")

# --- 5. Speech probs for jfk.flac ---
audio_jfk = decode_audio(os.path.join(DATA_DIR, 'jfk.flac'), sampling_rate=16000)
padded_jfk = np.pad(audio_jfk, (0, 512 - len(audio_jfk) % 512))
probs_jfk = model(padded_jfk)
timestamps_jfk = vad_mod.get_speech_timestamps(audio_jfk)
ref['timestamps_jfk'] = [{'start': int(t['start']), 'end': int(t['end'])} for t in timestamps_jfk]
ref['speech_probs_jfk'] = {
    'num_chunks': len(probs_jfk),
    'probs': [float(p) for p in probs_jfk.flatten()],
}
print(f"OK: jfk — {len(probs_jfk)} chunks, {len(timestamps_jfk)} segments")

# Save
with open(os.path.join(REF_DIR, 'vad_reference.json'), 'w') as f:
    json.dump(ref, f, indent=2)
print(f"\nSaved to {REF_DIR}/vad_reference.json")
