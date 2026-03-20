# Speaker Diarization: Comprehensive Research Report

**Date:** 2026-03-21
**Context:** MetalWhisper M14 planning — on-device speaker diarization for macOS Apple Silicon
**Scope:** State of the art, models, benchmarks, failure modes, integration with Whisper ASR, on-device feasibility

---

## Executive Summary

Speaker diarization -- determining "who spoke when" in audio -- remains one of the most challenging problems in speech processing. While significant progress has been made between 2023 and 2025, the field is characterized by a fundamental tension: **state-of-the-art systems achieve 11-14% DER on standard benchmarks but degrade sharply on out-of-domain audio, overlapping speech, and unknown speaker counts.**

The most important findings for MetalWhisper M14:

1. **pyannote.audio 3.1 / Community-1** is the de facto standard open-source diarization pipeline, achieving 11-22% DER across benchmarks. Its modular design (segmentation + embedding + clustering) maps well to on-device deployment.
2. **CoreML deployment is proven.** FluidAudio (FluidInference) and WhisperKit/SpeakerKit both run pyannote-derived models on Apple Neural Engine with 10-20x speedups over CPU. The segmentation model is ~1M parameters; the embedding model (WeSpeaker ResNet34) is ~6.6M parameters. Both are small enough for on-device.
3. **The recommended architecture for M14** is: (a) pyannote-style powerset segmentation converted to CoreML, (b) WeSpeaker ResNet34 or ECAPA-TDNN embeddings converted to CoreML, (c) agglomerative or spectral clustering on CPU, (d) segment-level speaker assignment aligned with Whisper output.
4. **Key risk:** Diarization quality is highly sensitive to domain, VAD quality, and hyperparameters. Shipping a good default that works across meeting recordings, phone calls, and podcasts requires careful tuning and honest documentation of limitations.

---

## 1. Foundational Concepts

### What Is Speaker Diarization?

Speaker diarization answers the question "who spoke when" in an audio recording. Given a multi-speaker audio file, the system produces a set of time-stamped speaker labels (e.g., `Speaker A: 0.0s-3.5s, Speaker B: 3.5s-7.2s, Speaker A: 7.2s-10.0s`). The standard output format is RTTM (Rich Transcription Time Marked).

### Core Pipeline Stages (Traditional)

The traditional (modular/cascading) approach involves four stages:

| Stage | Purpose | Typical Models |
|-------|---------|---------------|
| **1. Voice Activity Detection (VAD)** | Detect speech vs non-speech regions | MarbleNet, Silero VAD, pyannote segmentation |
| **2. Segmentation** | Split speech into homogeneous speaker segments | pyannote segmentation-3.0, change-point detection |
| **3. Speaker Embedding Extraction** | Generate a fixed-dimension vector representing each speaker's voice | ECAPA-TDNN, WeSpeaker ResNet34, TitaNet, x-vectors |
| **4. Clustering** | Group embeddings into speaker identities | Agglomerative Hierarchical Clustering (AHC), Spectral Clustering, VBx (Variational Bayes) |

### Traditional vs End-to-End

**Traditional (modular):** Each stage is trained independently and optimized separately. Advantages: modularity, interpretability, each component can be swapped. Disadvantages: error propagation between stages, suboptimal joint optimization, cannot directly handle overlapping speech in the clustering step.

**End-to-End Neural Diarization (EEND):** A single neural network directly outputs per-frame speaker activity for all speakers. Advantages: jointly optimized, naturally handles overlap. Disadvantages: fixed maximum speaker count, requires substantial training data, harder to debug.

**Hybrid:** Systems like pyannote 3.x and DiariZen combine neural segmentation (which handles local overlap) with clustering-based global speaker assignment. This is currently the dominant paradigm.

### Key Challenges

- **Overlapping speech:** 10-20% of meeting speech is overlapped. Traditional clustering cannot assign one segment to multiple speakers. Powerset segmentation (pyannote 3.x) addresses this locally but global overlap handling remains difficult.
- **Short segments:** Utterances under 1 second produce weak speaker embeddings, leading to clustering errors.
- **Unknown number of speakers:** Estimating the correct speaker count is an unsolved sub-problem. Over-estimation fragments speakers; under-estimation merges them.
- **Domain mismatch:** A model trained on meetings performs poorly on phone calls. Trained on English, it degrades on other languages. Acoustic conditions (noise, reverb, microphone type) dramatically affect performance.
- **Speaker similarity:** Same-gender speakers with similar vocal characteristics are frequently confused.

---

## 2. State-of-the-Art Models and Frameworks

### 2.1 pyannote.audio (Herve Bredin et al.)

**Status:** The most widely used open-source diarization toolkit. 12.4M+ monthly downloads. MIT license.

**Architecture (v3.1):**
- **Segmentation model** (pyannote/segmentation-3.0): PyanNet architecture using powerset multi-class training. Ingests 10s chunks of 16kHz mono audio. Outputs a `(num_frames, 7)` matrix where 7 classes encode: non-speech, speaker #1, #2, #3, and all pairwise overlaps (#1+#2, #1+#3, #2+#3). Handles up to 3 speakers per chunk with up to 2 simultaneous.
- **Speaker embedding model**: WeSpeaker ResNet34-LM (6.63M parameters, 4.55G FLOPS). Trained on VoxCeleb2. Produces 256-dim embeddings.
- **Clustering**: Agglomerative hierarchical clustering with centroid linkage, or VBx (Variational Bayes x-vector clustering).

**Powerset training** is the key innovation in pyannote 3.x. Instead of multi-label binary classification (one sigmoid per speaker), it uses multi-class cross-entropy over the powerset of speaker combinations. This eliminates the detection threshold hyperparameter and significantly improves overlapping speech handling.

**Benchmark DER (v3.1, no collar, including overlap):**

| Dataset | DER% | False Alarm% | Missed% | Confusion% |
|---------|------|-------------|---------|-----------|
| REPERE phase 2 | 7.8 | 1.8 | 2.6 | 3.5 |
| VoxConverse v0.3 | 11.3 | 4.1 | 3.4 | 3.8 |
| AISHELL-4 | 12.2 | 3.8 | 4.4 | 4.0 |
| AMI (headset mix) | 18.8 | 3.6 | 9.5 | 5.7 |
| DIHARD 3 (full) | 21.7 | 6.2 | 8.1 | 7.3 |
| AMI (array) | 22.4 | 3.8 | 11.2 | 7.5 |
| AliMeeting | 24.4 | 4.4 | 10.0 | 10.0 |

**Latest versions (2025-2026):**
- **Community-1** (free, open-source): Improved over 3.1. AMI IHM 17.0%, DIHARD 3 20.2%, AISHELL-4 11.7%.
- **Precision-2** (commercial cloud API): Best results. AMI IHM 12.9%, DIHARD 3 14.7%, AISHELL-4 11.4%. 2.2-2.6x faster on H100.
- pyannote.audio v4.0.4 released February 2026.

### 2.2 NVIDIA NeMo Speaker Diarization

**Components:**
- **MarbleNet** for VAD
- **TitaNet** for speaker embeddings (larger and more accurate than ECAPA-TDNN; ~23M parameters)
- **MSDD (Multi-Scale Diarization Decoder):** Takes speaker embeddings from multiple time scales, learns scale weights, and produces speaker labels. The multi-scale approach captures both fine-grained and coarse speaker information.
- **Sortformer:** Transformer encoder-based end-to-end diarization. Generates speaker labels in arrival time order (ATO) using Sort Loss. Handles up to 4 speakers.

**Sortformer streaming** (2025): Processes audio in overlapping chunks with an Arrival-Order Speaker Cache (AOSC) that tracks previously detected speakers. Achieves the fastest processing speed (RTF = 214.3x) among benchmarked systems.

**Limitations:** Sortformer is currently designed for up to 4 speakers; performance degrades beyond this. Struggles with very rapid turn-taking or heavy crosstalk.

### 2.3 DiariZen (BUT Speech@FIT)

**Architecture:** Hybrid EEND + clustering. Uses WavLM (self-supervised speech model) representations fed into a Conformer for neural speaker activity detection, combined with pyannote 3.1's clustering backend.

**Performance:** 13.3% average DER (best open-source alternative to pyannote). Particularly strong in high-speaker scenarios (5+ speakers: DER = 7.1%).

**Key insight:** WavLM's pre-trained representations provide richer acoustic information than task-specific models, leading to better generalization across domains.

### 2.4 EEND (End-to-End Neural Diarization)

**Origin:** Fujitsu, 2019. Originally BLSTM-based, later enhanced with self-attention (SA-EEND) and then with attractors (EEND-EDA) for flexible speaker counts.

**How it works:** Directly predicts per-frame speaker activity without separate embedding extraction or clustering. Self-attention conditions on all frames simultaneously, capturing long-range speaker dependencies.

**EEND-TA (2025):** Achieves DER of 14.49% on DIHARD III and 10.43% on MagicData RAMC.

**Limitation:** Fixed maximum speaker count at training time. Models trained for N speakers cannot handle N+1 without retraining.

### 2.5 Newer Approaches (2024-2025)

**SpeakerLM (August 2025):** End-to-end multimodal LLM for joint diarization and ASR. Uses SenseVoice-large audio encoder + Qwen2.5-7B-Instruct LLM. Supports flexible speaker registration modes (anonymous, personalized, over-specified). Represents the trend of LLM-based approaches but requires 7B+ parameters, making it impractical for on-device.

**DiarizationLM (Google, 2024):** LLM-based post-processing of diarization output. Converts diarized transcripts to text, feeds to a fine-tuned LLM for correction. Reduces Word DER by 55.5% (Fisher) and 44.9% (CALLHOME). Can be applied to any off-the-shelf ASR + diarization system without retraining. Uses a Transcript-Preserving Speaker Transfer (TPST) algorithm to ensure ASR text is not modified.

**Mamba-based segmentation (2024):** Replaces pyannote's PyanNet with Mamba (state-space model) for segmentation. Mamba's efficient long-range processing allows longer local windows, improving diarization quality. Achieves state-of-the-art on three datasets.

**DiCoW (Diarization-Conditioned Whisper, 2025):** Extends Whisper by integrating diarization labels directly as conditioning. Uses frame-level diarization-dependent transformations (FDDT) and query-key biasing (QKb) for target-speaker ASR.

**WhisperDiari (AAAI 2025):** Unified diarization + ASR framework building on Whisper with speaker adapters and Speaker Similarity Matrix Supervision.

### Model Comparison Summary

| System | Type | DER Range | Max Speakers | Model Size | Open Source | On-Device Feasible |
|--------|------|-----------|-------------|------------|-------------|-------------------|
| pyannote 3.1 | Hybrid | 7.8-24.4% | Unlimited (clustering) | ~8M (seg+emb) | Yes (MIT) | Yes |
| pyannote Community-1 | Hybrid | 11.7-20.2% | Unlimited | ~8M | Yes (MIT) | Yes |
| pyannote Precision-2 | Hybrid | 11.4-14.7% | Unlimited | Undisclosed | No (cloud API) | No |
| NeMo MSDD | Hybrid | ~12-20% | Unlimited | ~30M+ | Yes (Apache 2.0) | Marginal |
| NeMo Sortformer | End-to-end | ~11-15% | 4 | ~20M | Yes (Apache 2.0) | Marginal |
| DiariZen | Hybrid | 13.3% avg | Unlimited | WavLM Large (~300M) | Yes | No (too large) |
| EEND-TA | End-to-end | 10.4-14.5% | Fixed at training | ~10M | Yes | Possible |
| SpeakerLM | LLM-based | Competitive | Flexible | ~7B+ | No | No |
| DiarizationLM | Post-proc | Reduces WDER 45-55% | N/A | LLM-sized | Yes (code) | No |

---

## 3. Benchmarks and Datasets

### Standard Benchmarks

| Dataset | Domain | Language | Hours | Speakers/Session | Overlap% | Notes |
|---------|--------|----------|-------|-----------------|----------|-------|
| **AMI** | Meetings | English | 100h | 4 | ~15% | Headset mix (close-talk) and array (far-field) |
| **CALLHOME** | Phone calls | Multi | ~20h | 2-7 | ~10% | Classic 2-speaker telephony benchmark |
| **DIHARD III** | Diverse | English | ~40h | Varies | High | The "hardest" benchmark: clinical, web video, meetings |
| **VoxConverse** | Media | Multi | ~65h | 1-21 | ~3-10% | YouTube/broadcast conversations |
| **AISHELL-4** | Meetings | Mandarin | 120h | 4-8 | ~15% | 8-channel far-field |
| **AliMeeting** | Meetings | Mandarin | 118h | 2-4 | ~20% | Far-field, high overlap |
| **MSDWild** | In-the-wild | Multi | Varies | Varies | High | Diverse real-world audio |
| **REPERE** | Broadcast | French | ~30h | Varies | Low | French broadcast news/debates |

### Diarization Error Rate (DER)

DER is the primary metric, decomposed into three components:

```
DER = False Alarm (FA) + Missed Speech (Miss) + Speaker Confusion (Conf)
```

- **False Alarm (FA):** System marks non-speech as speech
- **Missed Speech (Miss):** System fails to detect actual speech
- **Speaker Confusion (Conf):** Speech detected but assigned to wrong speaker

**Evaluation conventions that affect scores:**
- **Forgiveness collar:** A tolerance window (typically 0.25s) around speaker boundaries. Without collar, scores are higher (worse). pyannote reports without collar (hardest).
- **Overlap evaluation:** Whether overlapping speech regions are scored. Including overlap increases DER. pyannote includes overlap.
- **Oracle VAD vs system VAD:** Using ground-truth speech regions removes FA/Miss errors, isolating confusion. Some papers use oracle VAD, making results look better.

### Current SOTA Numbers (2025)

| Dataset | Best Open-Source | Best Overall | System |
|---------|-----------------|--------------|--------|
| AMI (IHM) | 17.0% | 12.9% | Community-1 / Precision-2 |
| DIHARD III | 20.2% | 14.7% | Community-1 / Precision-2 |
| VoxConverse | ~11% | ~11% | pyannote 3.1 |
| AISHELL-4 | 11.7% | 11.4% | Community-1 / Precision-2 |

### Benchmark Limitations

- **Not representative of real applications:** Most benchmarks use clean, controlled recordings. Real-world audio has background noise, music, laughter, and varying mic quality.
- **Limited overlap:** Many benchmarks have low overlap percentages. Real meetings can have 20-30% overlap.
- **English-dominated:** Most benchmarks and models are primarily English. Cross-lingual performance is understudied.
- **Fixed conditions:** Benchmarks do not capture streaming/real-time scenarios, incremental speaker discovery, or very long recordings (multi-hour).

---

## 4. Known Fragilities and Failure Modes

Speaker diarization is widely considered the most fragile component in a speech processing pipeline. The primary causes of errors are:

### 4.1 Missed Speech (Dominant Error)

The benchmarking study by Lanzendorfer et al. (2025) found that **missed speech segments are the primary cause of diarization errors** across all tested models. This is particularly severe in:
- Far-field recordings (microphone arrays)
- Noisy environments
- Whispered or quiet speech
- Speech with background music

### 4.2 Speaker Confusion

The second-largest error source. Especially problematic with:
- Same-gender speakers with similar vocal characteristics
- Short utterances (< 1 second) producing weak embeddings
- High speaker counts (5+ speakers exhaust embedding discriminability)
- Rapid turn-taking

### 4.3 Overlapping Speech

Traditional clustering cannot assign one time region to two speakers. Even powerset-based models (pyannote 3.x) handle at most 2 simultaneous speakers per chunk and 3 speakers total per 10-second window. Heavy crosstalk in arguments or group discussions degrades all systems.

### 4.4 Domain Mismatch

**This is the most practically impactful failure mode.** A model tuned for:
- Meetings fails on phone calls (different acoustic characteristics)
- English fails on tonal languages
- Studio recordings fails on field recordings
- Close-talk microphones fails on far-field arrays

The gap can be enormous: pyannote 3.1 achieves 7.8% DER on REPERE (broadcast) but 50.0% on AVA-AVD (audiovisual, in-the-wild).

### 4.5 Number-of-Speakers Estimation

When the speaker count is unknown (the common case), the system must estimate it from the data. Errors here cascade:
- **Over-estimation:** One speaker is split into two (fragmentation). Common with speakers who change vocal register.
- **Under-estimation:** Two speakers are merged into one. Common with similar-sounding speakers.

Providing `num_speakers` (oracle) significantly improves results but is rarely available in practice.

### 4.6 Short Utterances

Backchannel responses ("mm-hmm", "yeah", "right") are typically 0.2-0.5 seconds. Speaker embeddings from such short segments are unreliable, leading to either missed detection or random speaker assignment.

### 4.7 Audio Quality Issues

- Clipping/distortion corrupts embeddings
- Compression artifacts (low-bitrate codecs) reduce discriminability
- Reverb smears speaker characteristics
- Non-stationary noise (keyboard typing, door closing) triggers false alarms

---

## 5. Best Practices and Recipes

### 5.1 Pre-Processing

1. **Audio normalization:** Normalize to -3dBFS peak. Avoid clipping. Resample to 16kHz mono.
2. **VAD quality is critical.** The #1 hyperparameter to tune is VAD sensitivity. Too aggressive = missed speech. Too permissive = false alarms that corrupt clustering. Default VAD settings should be tuned per domain.
3. **Noise reduction:** Light noise suppression (suppression level 0.1-0.3) can help. Aggressive denoising can damage speaker characteristics.
4. **Channel handling:** For stereo, use average (not just left channel). For multi-channel, beamforming can improve SNR.

### 5.2 Pipeline Configuration

1. **Segmentation window:** pyannote uses 10-second chunks. Longer windows capture more speaker context but increase memory and may exceed the max-speakers-per-chunk limit.
2. **Embedding model selection:** WeSpeaker ResNet34 (6.6M params, 256-dim) offers the best size/accuracy tradeoff for on-device. ECAPA-TDNN (~14.6M params, 192-dim) is slightly more accurate but larger.
3. **Clustering algorithm:**
   - **Agglomerative (AHC):** Simple, deterministic, works well for 2-5 speakers. Threshold-sensitive.
   - **Spectral clustering:** Better for unknown speaker counts. Requires eigen-gap heuristic for speaker count estimation.
   - **VBx:** Bayesian refinement of AHC. Best overall accuracy but slower.
4. **Clustering threshold:** The most impactful hyperparameter. Too low = over-segmentation (too many speakers). Too high = under-segmentation (merged speakers). Tune per domain.

### 5.3 Post-Processing

1. **Minimum segment duration:** Filter out segments shorter than 0.3-0.5 seconds to remove noise.
2. **Gap merging:** Merge same-speaker segments separated by < 0.5 seconds of silence.
3. **Speaker smoothing:** Apply a median filter to prevent rapid speaker oscillation.
4. **LLM post-processing (DiarizationLM):** Use an LLM to correct speaker labels based on semantic context. Reduces WDER by 45-55% but requires an LLM, making it impractical for on-device without a local model.

### 5.4 When to Use Oracle Speaker Count

- **Provide `num_speakers` when known:** Always improves results. Common in phone calls (2), interviews (2-3), panel discussions (known panel).
- **Provide `min_speakers`/`max_speakers` when partially known:** Constrains the clustering. For meetings, `min_speakers=2, max_speakers=8` is reasonable.
- **Automatic estimation when unknown:** Accept that speaker count estimation adds 2-5% DER overhead.

### 5.5 Hyperparameter Tuning Guidance

Priority order for tuning:
1. VAD onset/offset thresholds
2. Clustering distance threshold
3. Minimum segment duration
4. Embedding extraction window/step size
5. Segmentation model confidence threshold

---

## 6. Integration with ASR (Especially Whisper)

### 6.1 Integration Architectures

There are three main approaches to combining diarization with ASR:

**A. Sequential (ASR-then-Diarize):** Run Whisper first to get transcript + timestamps, then run diarization independently, then align. This is the simplest but timestamps may not align well.

**B. Parallel (ASR + Diarize, then Align):** Run both pipelines independently, then align diarization segments with ASR words. This is the WhisperX approach.

**C. Joint (Diarize-Conditioned ASR):** Use diarization output as conditioning for ASR. This is the DiCoW and WhisperDiari approach, producing the best results but requiring specialized models.

### 6.2 WhisperX Approach (Recommended for M14)

WhisperX implements approach B with three stages:

1. **Transcription:** Whisper (via faster-whisper) produces utterance-level transcript with coarse timestamps.
2. **Forced alignment:** wav2vec2.0 phoneme model aligns transcript to word-level timestamps. This is critical because Whisper's native timestamps can be off by several seconds.
3. **Speaker assignment:** pyannote.audio produces diarization (speaker segments). Each word is assigned to the speaker whose segment covers that word's timestamp.

**Performance:** ~70x real-time with Whisper large-v2 on GPU. < 8GB GPU memory. WER < 5%, DER ~8% reported.

### 6.3 Alignment Challenges

- **Whisper timestamp inaccuracy:** Whisper's cross-attention-based timestamps are utterance-level, not word-level, and can drift by seconds. Forced alignment with wav2vec2 or CTC models is essential.
- **Boundary misalignment:** Diarization boundaries and ASR word boundaries rarely coincide exactly. A word may straddle a speaker change. Heuristics: assign to the speaker covering the majority of the word's duration.
- **Hallucination regions:** Whisper sometimes generates text for non-speech regions. VAD pre-filtering reduces this.

### 6.4 For MetalWhisper M14

The recommended integration approach:

```
Audio → VAD (MWVoiceActivityDetector, already implemented)
    → Mel Spectrogram (MWFeatureExtractor, already implemented)
    → Whisper Decode (MWTranscriber, already implemented)
    → Forced Alignment (new: CTC-based aligner for word timestamps)
    → Speaker Segmentation (new: CoreML segmentation model)
    → Speaker Embedding (new: CoreML embedding model)
    → Clustering (new: AHC on CPU)
    → Speaker Assignment (new: word-to-speaker mapping)
    → Output with speaker labels
```

Word-level alignment may already be partially available if MetalWhisper supports word timestamps from Whisper's cross-attention. If so, forced alignment is optional but improves accuracy.

---

## 7. On-Device / Embedded Considerations

### 7.1 Model Sizes

| Component | Model | Parameters | Size (fp16) | CoreML Feasible |
|-----------|-------|-----------|-------------|-----------------|
| Segmentation | pyannote segmentation-3.0 | ~1M | ~2 MB | Yes |
| Embedding | WeSpeaker ResNet34 | 6.63M | ~13 MB | Yes |
| Embedding | ECAPA-TDNN | ~14.6M | ~29 MB | Yes |
| Embedding | TitaNet-Large | ~23M | ~46 MB | Marginal |
| EEND | SA-EEND | ~10M | ~20 MB | Yes |
| Self-supervised | WavLM Large | ~300M | ~600 MB | No (too large) |

**Total for recommended pipeline (segmentation + WeSpeaker):** ~15 MB in fp16. Very feasible for on-device.

### 7.2 Existing Apple Silicon Implementations

**FluidAudio (FluidInference):**
- Swift SDK running on Apple Neural Engine (ANE)
- Implements pyannote Community-1 pipeline (powerset segmentation + WeSpeaker embeddings + VBx clustering)
- Also offers LS-EEND for streaming (up to 10 speakers, 100ms frame updates)
- CoreML models on ANE: ~10x speedup over CPU, ~20x over non-optimized implementations
- Average DER: 22.14% across standard benchmarks (optimized for real-time, not peak accuracy)
- MIT/Apache 2.0 licensed

**WhisperKit/SpeakerKit (Argmax):**
- On-device diarization framework built on CoreML
- Runs pyannote v4 (Community-1) segmentation and embedding models
- Integrated with WhisperKit transcription
- Open-source (with commercial Argmax Pro SDK for better models)

**speech-swift (Soniqo):**
- Open-source Swift library for Apple Silicon (M1-M4)
- Uses MLX and CoreML for diarization
- Speaker embedding extraction and VAD

### 7.3 CoreML/Metal Considerations

1. **ANE vs GPU vs CPU:** The segmentation and embedding models are small enough to run efficiently on ANE, which is the most power-efficient option. GPU (Metal/MPS) is also viable. CPU is adequate for the clustering step.
2. **Model conversion:** PyTorch models can be converted via `coremltools`. The pyannote segmentation model and WeSpeaker embedding model have been successfully converted by FluidAudio and WhisperKit.
3. **Quantization:** INT8 quantization of ECAPA-TDNN shows only 0.16% EER degradation with 4x compression. Similar quantization can be applied to WeSpeaker for even smaller models.
4. **Memory:** The entire diarization pipeline (segmentation + embedding + clustering) requires < 100 MB RAM, well within Apple Silicon constraints.

### 7.4 Streaming vs Batch

| Aspect | Batch (Offline) | Streaming (Online) |
|--------|----------------|-------------------|
| Accuracy | Best (global optimization) | Lower (causal constraints) |
| Latency | Full-file processing time | 0.5-5.5 seconds |
| Speaker count | Estimated after all audio | Incremental discovery |
| Use case | File transcription | Live meetings/calls |
| Recommended for M14 | Yes (start here) | Future M14.x extension |

**Recommendation for M14:** Start with batch/offline diarization. Streaming diarization (like Sortformer or diart) adds significant complexity and lower accuracy.

---

## 8. Karpathy's autoresearch

Karpathy's autoresearch project (https://github.com/karpathy/autoresearch) is an autonomous ML research framework where AI agents modify a GPT training loop (`train.py`) to optimize validation loss. Each experiment runs for 5 minutes of wall-clock time, and the agent keeps or discards changes based on `val_bpb` improvement.

**Relevance to diarization:** None. The project focuses exclusively on language model training with text data. It does not address audio processing, speaker diarization, or any speech-related tasks. The methodology (automated experiment iteration) is interesting but not applicable to our use case since diarization requires different evaluation infrastructure (audio datasets, DER computation, RTTM comparison).

---

## 9. Recent Developments (2024-2025)

### 9.1 Key Papers and Models

| Year | Development | Significance |
|------|------------|-------------|
| 2024 | DiarizationLM (Google) | LLM post-processing reduces WDER 45-55% |
| 2024 | Mamba-based segmentation | State-space models enable longer windows |
| 2024 | DiariZen v1 | WavLM + Conformer hybrid outperforms pyannote on some benchmarks |
| 2025 | pyannote Community-1 / Precision-2 | Latest open/commercial pyannote models |
| 2025 | Sortformer streaming (NVIDIA) | Real-time diarization with speaker cache |
| 2025 | EEND-TA | Pushes EEND to 14.49% on DIHARD III |
| 2025 | DiCoW | Diarization-conditioned Whisper for target-speaker ASR |
| 2025 | SpeakerLM | 7B LLM for joint diarization + recognition |
| 2025 | WhisperDiari (AAAI) | Unified Whisper-based diarization + ASR |
| 2025 | SDBench | Comprehensive benchmark suite for diarization |
| 2025 | FluidAudio / SpeakerKit | CoreML diarization on Apple Silicon |
| 2026 | pyannote.audio 4.0 | Latest framework release |

### 9.2 Trends

1. **LLM integration:** Both for end-to-end diarization (SpeakerLM) and post-processing (DiarizationLM). LLMs leverage semantic context that acoustic-only systems miss.
2. **Self-supervised features:** WavLM and similar models provide richer representations than task-specific models, improving generalization (DiariZen).
3. **Streaming/online:** Growing demand for real-time diarization (Sortformer streaming, LS-EEND, diart).
4. **On-device deployment:** CoreML and MLX implementations making diarization feasible on mobile/edge devices.
5. **Joint ASR + diarization:** Moving from cascaded to joint models (DiCoW, WhisperDiari, SpeakerLM).
6. **Better benchmarks:** SDBench (2025) provides comprehensive evaluation across diverse conditions.

### 9.3 Open Problems

- Robust speaker count estimation without oracle information
- Handling 10+ speakers in long recordings (multi-hour meetings)
- Cross-domain generalization without fine-tuning
- Real-time diarization with < 500ms latency at competitive accuracy
- Overlapping speech with 3+ simultaneous speakers
- Child/elderly speaker handling (underrepresented in training data)
- Multilingual diarization with code-switching

---

## 10. Practical Recommendations for MetalWhisper M14

### 10.1 Architecture Decision

**Recommended: pyannote-style modular pipeline with CoreML models.**

Rationale:
- Proven architecture with well-understood behavior
- Small models (< 15 MB total) suitable for on-device
- CoreML conversion already demonstrated by FluidAudio and WhisperKit
- Modular design allows component-by-component development and testing
- Matches the M14 roadmap tasks (M14.1-M14.6)

### 10.2 Implementation Plan Aligned with M14 Tasks

| Task | Implementation | Model/Approach |
|------|---------------|---------------|
| M14.1: Speaker embedding model | Convert WeSpeaker ResNet34 to CoreML | 6.6M params, 256-dim output |
| M14.2: Embedding extraction | Run CoreML model on VAD segments | Segment-level embeddings |
| M14.3: Clustering | Agglomerative hierarchical clustering | CPU, no ML needed |
| M14.4: Speaker-labeled output | Map cluster IDs to sequential labels | Word-to-speaker assignment |
| M14.5: SRT/VTT export | Extend existing subtitle export | Add `[Speaker N]` prefix |
| M14.6: CLI flag | Add `--diarize` and `--num-speakers` | Options in MWTranscriptionOptions |

**Additional component not in roadmap but recommended:**
- Segmentation model (pyannote segmentation-3.0 converted to CoreML) for local speaker change detection and overlap handling. Without this, relying solely on VAD chunks for embedding extraction will produce poor results on overlapping speech.

### 10.3 Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Poor accuracy on user's audio | Document expected DER ranges per domain. Expose clustering threshold as tunable parameter |
| Overlap handling | Use powerset segmentation model; document 2-speaker-overlap limit |
| Speaker count estimation | Default to automatic; expose `num_speakers`, `min_speakers`, `max_speakers` options |
| CoreML conversion issues | Reference FluidAudio's proven conversion; test with coremltools early |
| Latency concerns | Batch-only for M14; streaming deferred to future milestone |

### 10.4 Test Strategy

For `e2e_diarize_2_speakers` and `e2e_diarize_speaker_consistency`:
- Use a clean 2-speaker meeting recording (turn-taking, no overlap) as baseline test
- Verify DER < 15% on this controlled case
- Verify consistent speaker labeling (same speaker gets same ID throughout)
- Separate test for overlapping speech scenario with expected degradation documented

---

## References

### Papers
- Bredin, H. et al. "pyannote.audio 2.1: speaker diarization pipeline." INTERSPEECH 2023.
- Plaquet, A. & Bredin, H. "Powerset multi-class cross entropy loss for neural speaker diarization." INTERSPEECH 2023.
- Fujita, Y. et al. "End-to-End Neural Speaker Diarization with Self-Attention." ASRU 2019. (arXiv: 1909.06247)
- Park, T.J. et al. "Multi-Scale Speaker Diarization with Dynamic Scale Weighting." INTERSPEECH 2022.
- Wang, Q. et al. "DiarizationLM: Speaker Diarization Post-Processing with Large Language Models." INTERSPEECH 2024. (arXiv: 2401.03506)
- Lanzendorfer, L. et al. "Benchmarking Diarization Models." arXiv:2509.26177, 2025.
- Broughton et al. "Pushing the Limits of End-to-End Diarization." INTERSPEECH 2025. (arXiv: 2509.14737)
- SpeakerLM. arXiv:2508.06372, August 2025.
- Bain, M. et al. "WhisperX: Time-Accurate Speech Transcription of Long-Form Audio." arXiv: 2303.00747.
- DiCoW. arXiv: 2501.00114, January 2025.

### Repositories and Models
- pyannote/pyannote-audio: https://github.com/pyannote/pyannote-audio
- pyannote/speaker-diarization-3.1: https://huggingface.co/pyannote/speaker-diarization-3.1
- pyannote/segmentation-3.0: https://huggingface.co/pyannote/segmentation-3.0
- NVIDIA NeMo: https://github.com/NVIDIA-NeMo/NeMo
- DiariZen: https://github.com/BUTSpeechFIT/DiariZen
- WhisperX: https://github.com/m-bain/whisperX
- WeSpeaker: https://github.com/wenet-e2e/wespeaker
- FluidAudio: https://github.com/FluidInference/FluidAudio
- WhisperKit/SpeakerKit: https://github.com/argmaxinc/WhisperKit
- speech-swift (Soniqo): https://github.com/soniqo/speech-swift
- DiarizationLM: https://github.com/google/speaker-id/tree/master/DiarizationLM
- Karpathy autoresearch: https://github.com/karpathy/autoresearch (not related to diarization)

### Benchmarks and Datasets
- AMI Corpus: https://groups.inf.ed.ac.uk/ami/corpus/
- DIHARD Challenge: https://dihardchallenge.github.io/dihard3/
- VoxConverse: https://www.robots.ox.ac.uk/~vgg/data/voxconverse/
- CALLHOME: LDC catalog
- AISHELL-4: https://www.aishelltech.com/aishell_4
