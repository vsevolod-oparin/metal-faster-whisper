# M9 Milestone Report — Model Downloading & Caching

**Date:** 2026-03-20
**Status:** PASSED (9/9 offline tests + manual network verification)

## Summary

Implemented model downloading from HuggingFace Hub via `NSURLSession`, with a local cache at `~/Library/Caches/MetalWhisper/models/`, model alias resolution (18 aliases), resumable downloads, progress callbacks, and CLI integration (`--list-models`, `--download`, `--model <alias>`).

## Features

### Model Resolution

```bash
# Model alias → auto-download + cache
metalwhisper audio.wav --model tiny

# HuggingFace repo ID → download
metalwhisper audio.wav --model Systran/faster-whisper-base

# Local path → use directly
metalwhisper audio.wav --model /path/to/model

# Pre-download without transcribing
metalwhisper --model large-v3 --download

# List all available aliases + cached models
metalwhisper --list-models
```

### Supported Aliases (18)

| Alias | HuggingFace Repo |
|-------|-----------------|
| tiny, tiny.en | Systran/faster-whisper-tiny[.en] |
| base, base.en | Systran/faster-whisper-base[.en] |
| small, small.en | Systran/faster-whisper-small[.en] |
| medium, medium.en | Systran/faster-whisper-medium[.en] |
| large-v1, large-v2, large-v3, large | Systran/faster-whisper-large-v[123] |
| distil-small.en, distil-medium.en | Systran/faster-distil-whisper-... |
| distil-large-v2, distil-large-v3 | Systran/faster-distil-whisper-... |
| large-v3-turbo, turbo | mobiuslabsgmbh/faster-whisper-large-v3-turbo |

### Download Implementation

- **NSURLSession** with delegate for progress tracking
- **Resumable**: partial downloads saved as `.partial` files, resumed with `Range` header
- **Progress callback**: `MWDownloadProgressBlock(bytesDownloaded, totalBytes, fileName)`
- **Validation**: checks required files (model.bin, tokenizer.json, config.json) + vocabulary (json or txt)
- **Optional files**: preprocessor_config.json downloaded if available, skipped if 404

### Cache Layout

```
~/Library/Caches/MetalWhisper/models/
  Systran--faster-whisper-tiny/
    model.bin        (75 MB)
    tokenizer.json   (2.1 MB)
    config.json      (2 KB)
    vocabulary.txt   (449 KB)
```

## Test Results

| Test | Result |
|------|--------|
| m9_available_models | PASS — 18 aliases |
| m9_repo_id_lookup | PASS — correct repo IDs |
| m9_local_path | PASS — direct path resolution |
| m9_cache_directory | PASS — ~/Library/Caches/ |
| m9_list_cached | PASS |
| m9_is_cached | PASS |
| m9_unknown_model_error | PASS — proper error message |
| m9_delete_nonexistent | PASS — no crash |
| m9_custom_cache_dir | PASS |
| m9_download_tiny (NETWORK) | PASS (manual) — 72MB downloaded, all files present |

## Fixes Applied During Implementation

- `preprocessor_config.json` made optional (not all HuggingFace repos have it)
- Request timeout increased from 30s to 120s (HuggingFace can be slow)
- Resource timeout set to 2 hours (for large-v3 at ~3GB)

## Task Checklist

| Task | Status |
|------|--------|
| M9.1: MWModelManager with URLSession download | Done |
| M9.2: Local cache at ~/Library/Caches/ | Done |
| M9.3: Model size aliases (18 supported) | Done |
| M9.4: Resumable downloads | Done (.partial files + Range header) |
| M9.5: Progress callback | Done |
| M9.6: Model validation | Done |
| M9.7: `--list-models` CLI flag | Done |
| M9.8: `--download` CLI flag | Done |

## First-Run Experience

```bash
$ metalwhisper lecture.mp3 --model turbo
Downloading model.bin: 45.2% (1459.3 / 3226.0 MB)...
...
Model resolved to: /Users/user/Library/Caches/MetalWhisper/models/mobiuslabsgmbh--faster-whisper-large-v3-turbo
Now I want to return to the conservation of mechanical energy...
```

## Project Status

| Milestone | Tests |
|-----------|-------|
| M0–M8 | 98 |
| M9 — Model Downloading | 9 |
| **Total** | **107+** |
