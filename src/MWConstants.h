#pragma once

#import <Foundation/Foundation.h>

// ── Audio decoding constants ─────────────────────────────────────────────────

/// Target sample rate for Whisper input (16 kHz).
static const NSUInteger kMWTargetSampleRate = 16000;

/// Target channel count for Whisper input (mono).
static const NSUInteger kMWTargetChannels = 1;

/// Number of frames to read per chunk during audio decoding.
static const NSUInteger kMWDecodeBufferFrames = 8192;

// ── Mel spectrogram constants ────────────────────────────────────────────────

/// Default FFT window size for Whisper feature extraction.
static const NSUInteger kMWDefaultNFFT = 400;

/// Default hop length (stride) in samples for STFT.
static const NSUInteger kMWDefaultHopLength = 160;

/// Default zero-padding appended to audio before STFT (matches Python padding=160).
static const NSUInteger kMWDefaultPadding = 160;

/// Floor value for log-mel computation: log10(max(x, kMWMelFloor)).
static const float kMWMelFloor = 1e-10f;

/// Offset added to log-mel values before scaling: (log + offset) / scale.
static const float kMWLogOffset = 4.0f;

/// Scale factor for final normalization: (log + offset) / scale.
static const float kMWLogScale = 4.0f;

/// Dynamic range for log-mel clamping: max(log, max_log - range).
static const float kMWLogDynamicRange = 8.0f;

/// Default number of mel spectrogram frames per chunk.
/// 30 seconds of audio at 16 kHz with hop_length=160 yields 3000 frames.
static const NSUInteger kMWDefaultChunkFrames = 3000;
