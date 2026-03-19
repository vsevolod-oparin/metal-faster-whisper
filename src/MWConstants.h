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

/// Default number of mel spectrogram frames per chunk.
/// 30 seconds of audio at 16 kHz with hop_length=160 yields 3000 frames.
static const NSUInteger kMWDefaultChunkFrames = 3000;
