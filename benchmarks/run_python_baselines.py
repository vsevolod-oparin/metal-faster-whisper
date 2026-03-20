"""Benchmark Python faster-whisper on the same audio files and model.

Run: python benchmarks/run_python_baselines.py

Requires: pip install faster-whisper
"""
import json
import os
import sys
import time
import importlib.util
import resource
import numpy as np

# Direct imports to avoid full faster_whisper import chain issues
FASTER_WHISPER_DIR = os.path.join(os.path.dirname(__file__), '../../faster-whisper/faster_whisper')

audio_spec = importlib.util.spec_from_file_location("audio", os.path.join(FASTER_WHISPER_DIR, "audio.py"))
audio_mod = importlib.util.module_from_spec(audio_spec)
audio_spec.loader.exec_module(audio_mod)
decode_audio = audio_mod.decode_audio

fe_spec = importlib.util.spec_from_file_location("feature_extractor", os.path.join(FASTER_WHISPER_DIR, "feature_extractor.py"))
fe_mod = importlib.util.module_from_spec(fe_spec)
fe_spec.loader.exec_module(fe_mod)
FeatureExtractor = fe_mod.FeatureExtractor

DATA_DIR = os.path.join(os.path.dirname(__file__), '../tests/data')
OUT_FILE = os.path.join(os.path.dirname(__file__), 'python_baselines.json')

results = {}

def get_peak_rss_mb():
    """Get peak RSS in MB."""
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)

# --- Audio Decode Benchmarks ---
print("=== Audio Decode Benchmarks ===")

for name, path in [
    ("physicsworks_wav_203s", os.path.join(DATA_DIR, "physicsworks.wav")),
    ("jfk_flac_11s", os.path.join(DATA_DIR, "jfk.flac")),
]:
    if not os.path.exists(path):
        print(f"  SKIP: {name} — file not found")
        continue
    times = []
    for _ in range(3):
        t0 = time.perf_counter()
        audio = decode_audio(path, sampling_rate=16000)
        t1 = time.perf_counter()
        times.append(t1 - t0)
    median = sorted(times)[1]
    duration = len(audio) / 16000.0
    results[f"decode_{name}"] = {
        "median_ms": round(median * 1000, 2),
        "duration_s": round(duration, 2),
        "samples": len(audio),
    }
    print(f"  {name}: {median*1000:.1f} ms ({duration:.1f}s audio)")

# Large file
large_path = os.path.join(os.path.dirname(__file__), '../../data/large.mp3')
if os.path.exists(large_path):
    t0 = time.perf_counter()
    audio_large = decode_audio(large_path, sampling_rate=16000)
    t1 = time.perf_counter()
    dur = len(audio_large) / 16000.0
    results["decode_large_mp3_83min"] = {
        "median_ms": round((t1-t0)*1000, 2),
        "duration_s": round(dur, 2),
        "samples": len(audio_large),
    }
    print(f"  large_mp3: {(t1-t0)*1000:.1f} ms ({dur:.0f}s audio)")
else:
    print(f"  SKIP: large.mp3 — not found")

# --- Mel Spectrogram Benchmarks ---
print("\n=== Mel Spectrogram Benchmarks ===")

audio_30s_path = os.path.join(DATA_DIR, "reference/physicsworks_16khz_mono.raw")
if os.path.exists(audio_30s_path):
    audio_full = np.fromfile(audio_30s_path, dtype=np.float32)
    audio_30s = audio_full[:480000]

    for n_mels in [80, 128]:
        fe = FeatureExtractor(feature_size=n_mels, sampling_rate=16000, hop_length=160, chunk_length=30, n_fft=400)
        times = []
        for _ in range(5):
            t0 = time.perf_counter()
            mel = fe(audio_30s)
            t1 = time.perf_counter()
            times.append(t1 - t0)
        median = sorted(times)[2]
        results[f"mel_30s_{n_mels}mels"] = {
            "median_ms": round(median * 1000, 2),
            "shape": list(mel.shape),
        }
        print(f"  mel_30s_{n_mels}mels: {median*1000:.1f} ms → shape {mel.shape}")

# --- Full Transcription Benchmark (if ctranslate2 available) ---
print("\n=== Full Transcription Benchmark ===")

try:
    import ctranslate2
    import tokenizers

    MODEL_DIR = os.path.join(os.path.dirname(__file__), '../../whisper-metal/models/whisper-large-v3-turbo')
    if not os.path.isdir(MODEL_DIR):
        raise FileNotFoundError(f"Model not found: {MODEL_DIR}")

    # Import the full WhisperModel
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../faster-whisper'))
    from faster_whisper import WhisperModel

    model = WhisperModel(MODEL_DIR, device="cpu", compute_type="float32")

    for name, path in [
        ("jfk_flac_11s", os.path.join(DATA_DIR, "jfk.flac")),
        ("physicsworks_wav_203s", os.path.join(DATA_DIR, "physicsworks.wav")),
    ]:
        if not os.path.exists(path):
            print(f"  SKIP: {name}")
            continue

        audio = decode_audio(path, sampling_rate=16000)
        duration = len(audio) / 16000.0

        # Warm up
        segments, info = model.transcribe(audio, language="en", beam_size=5, temperature=0.0)
        for s in segments: pass

        times = []
        for _ in range(3):
            t0 = time.perf_counter()
            segments, info = model.transcribe(audio, language="en", beam_size=5, temperature=0.0)
            text = ""
            for s in segments:
                text += s.text
            t1 = time.perf_counter()
            times.append(t1 - t0)

        median = sorted(times)[1]
        rtf = median / duration
        results[f"transcribe_{name}"] = {
            "median_ms": round(median * 1000, 2),
            "duration_s": round(duration, 2),
            "rtf": round(rtf, 4),
            "text_preview": text[:100],
        }
        print(f"  {name}: {median*1000:.0f} ms (RTF={rtf:.3f}, {duration:.1f}s audio)")
        print(f"    text: {text[:80]}...")

    # Word timestamps
    audio_jfk = decode_audio(os.path.join(DATA_DIR, "jfk.flac"), sampling_rate=16000)
    t0 = time.perf_counter()
    segments, info = model.transcribe(audio_jfk, language="en", beam_size=5, temperature=0.0, word_timestamps=True)
    for s in segments: pass
    t1 = time.perf_counter()
    results["transcribe_jfk_word_timestamps"] = {
        "median_ms": round((t1-t0)*1000, 2),
        "duration_s": 11.0,
    }
    print(f"  jfk + word_timestamps: {(t1-t0)*1000:.0f} ms")

except ImportError as e:
    print(f"  SKIP: Full transcription benchmark — {e}")
    print("  Install faster-whisper: pip install faster-whisper")
except Exception as e:
    print(f"  ERROR: {e}")

# --- Save results ---
results["_meta"] = {
    "date": time.strftime("%Y-%m-%d %H:%M"),
    "peak_rss_mb": round(get_peak_rss_mb(), 1),
}

with open(OUT_FILE, 'w') as f:
    json.dump(results, f, indent=2)
print(f"\nResults saved to {OUT_FILE}")
