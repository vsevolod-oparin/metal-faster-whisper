#pragma once

#import <Foundation/Foundation.h>
#import "MWTranscriber.h"

// ── Debug logging macro ─────────────────────────────────────────────────────

/// Set to YES to enable debug logging via NSLog.
extern BOOL MWDebugLoggingEnabled;

#define MWLog(...) do { if (MWDebugLoggingEnabled) NSLog(__VA_ARGS__); } while(0)

// ── Error helper ────────────────────────────────────────────────────────────

/// Set an NSError with the MWErrorDomain.
void MWSetError(NSError **error, NSInteger code, NSString *description);

// ── JSON loading ────────────────────────────────────────────────────────────

/// Load a JSON dictionary from a file path. Returns nil if file missing or parse fails.
NSDictionary *MWLoadJSONFromPath(NSString *path, NSError **error);

// ── Whisper language codes ──────────────────────────────────────────────────

/// Standard Whisper language codes (100 languages for multilingual models).
NSArray<NSString *> *MWWhisperLanguageCodes(void);

// ── Mel helpers ─────────────────────────────────────────────────────────────

/// Pad or trim a mel spectrogram (nMels x nFrames, row-major) to targetFrames columns.
NSData *MWPadOrTrimMel(NSData *mel, NSUInteger nMels, NSUInteger nFrames, NSUInteger targetFrames);

/// Extract a sub-range of mel frames from a full mel spectrogram.
NSData *MWSliceMel(NSData *fullMel, NSUInteger nMels, NSUInteger totalFrames,
                   NSUInteger startFrame, NSUInteger numFrames);

// ── Compression ratio ───────────────────────────────────────────────────────

/// Compute the compression ratio of a string using zlib.
float MWGetCompressionRatio(NSString *text);

// ── Word-level timestamp helpers ────────────────────────────────────────────

/// Compute anomaly score for a word based on probability and duration.
float MWWordAnomalyScore(float probability, float duration);

/// Check if a segment's words indicate an anomaly (hallucination).
BOOL MWIsSegmentAnomaly(NSArray<MWWord *> *words);

/// Merge punctuation marks into adjacent words.
void MWMergePunctuations(NSMutableArray<NSMutableDictionary *> *alignment,
                         NSString *prepended, NSString *appended);

// ── Option parsing helpers ──────────────────────────────────────────────────

/// Read an unsigned integer option from a dictionary with type validation.
NSUInteger MWOptUInt(NSDictionary *opts, NSString *key, NSUInteger dflt);

/// Read a float option from a dictionary with type validation.
float MWOptFloat(NSDictionary *opts, NSString *key, float dflt);

/// Read a BOOL option from a dictionary with type validation.
BOOL MWOptBool(NSDictionary *opts, NSString *key, BOOL dflt);

/// Read a non-empty string option from a dictionary with type validation.
NSString *MWOptString(NSDictionary *opts, NSString *key);
