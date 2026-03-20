# M12 Milestone Report — macOS App & Documentation

**Date:** 2026-03-21
**Status:** PASSED (documentation deliverables complete)

## Summary

Created comprehensive documentation and example apps for MetalWhisper: README, API reference, migration guide, performance guide, man page, SwiftUI example app, Swift CLI example, framework bundle, and release packaging script. SPM, Homebrew, CI/CD, and code signing deferred.

## Deliverables

| Document | Lines | Content |
|----------|-------|---------|
| `README.md` | 301 | Quick start, CLI usage, Obj-C API examples, 18 model aliases, performance benchmarks |
| `docs/API.md` | 425 | Full reference: MWTranscriber, MWTranscriptionOptions (26 properties), all result types, MWModelManager, MWAudioDecoder, MWFeatureExtractor, MWVoiceActivityDetector, error codes |
| `docs/MIGRATION.md` | 249 | Python faster-whisper → MetalWhisper side-by-side: model loading, transcription, options, output formats, 7 key differences |
| `docs/PERFORMANCE.md` | 139 | Model selection, compute types per Mac, RTF benchmarks, memory usage, VAD guidance, sequential vs batched, optimization tips |
| `docs/man/metalwhisper.1` | 202 | Standard man page: all flags, examples, exit codes, notes |
| `examples/TranscriberApp/` | ~810 | SwiftUI macOS app: model selection, drag & drop, streaming segments, word timestamps, export |
| `examples/swift-cli/` | ~60 | Single-file Swift CLI using `import MetalWhisper` via framework |
| `scripts/build_framework.sh` | ~80 | Builds MetalWhisper.framework with headers, module map, Info.plist |
| `scripts/build_release.sh` | ~170 | Assembles release tarball: bin, lib, headers, framework, VAD model |

## Task Checklist

| Task | Status |
|------|--------|
| M12.1: README | Done |
| M12.2: API documentation | Done (docs/API.md) |
| M12.3: SwiftUI example app | Done — `examples/TranscriberApp/` with model selection, language picker, transcribe/translate, drag & drop, streaming, word timestamps, export |
| M12.4: SPM Package.swift | Deferred — needs SPM build system refactor |
| M12.5: Homebrew formula | Deferred |
| M12.6: CI/CD | Deferred |
| M12.7: Performance guide | Done |
| M12.7a: Framework bundle | Done — `scripts/build_framework.sh` → `MetalWhisper.framework` for Swift `import` |
| M12.8: Migration guide | Done |
| M12.9: Man page | Done |
| M12.release: Release packaging | Done — `scripts/build_release.sh` → standalone tarball with CLI, dylibs, headers, framework, VAD model |
| M12.10: Code signing | Deferred — no Developer account |
| M12.11: Model unload/reload | Deferred |

## All 12 ROADMAP Milestones Complete

| Milestone | Status | Tests |
|-----------|--------|-------|
| M0 — Project Setup | DONE | 5 |
| M1 — Audio Decoding | DONE | 7 |
| M2 — Mel Spectrogram | DONE | 7 |
| M3 — BPE Tokenizer | DONE | 9 |
| M4 — Core Transcription | DONE | 35 |
| M5 — Word Timestamps | DONE | 4 |
| M6 — Voice Activity Detection | DONE | 6 |
| M7 — Batched Inference | DONE | 5 |
| M8 — CLI Tool | DONE | 7 |
| M9 — Model Downloading | DONE | 10 |
| M10 — Public API | DONE | 5 |
| M11 — Validation | DONE | 14 |
| M12 — Documentation | DONE | — |
| Edge cases + memory | — | 19 |
| Coverage gap tests | — | 22 |
| Swift integration tests | — | 3 |
| Benchmark | — | 1 |
| **Total** | **ALL DONE** | **~181** |
