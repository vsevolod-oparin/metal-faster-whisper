#import "MWFeatureExtractor.h"
#import "MWConstants.h"
#import "MWTranscriber.h"  // For MWErrorDomain and MWErrorCode
#import "MWHelpers.h"

#define ACCELERATE_NEW_LAPACK
#import <Accelerate/Accelerate.h>

#include <cmath>
#include <vector>

// MWSetError is provided by MWHelpers.h (already imported above).

// ── HTK Mel scale helpers ───────────────────────────────────────────────────

static const float kHTKFreqSp = 200.0f / 3.0f;           // Linear spacing below breakpoint
static const float kHTKMinLogHz = 1000.0f;                // Breakpoint frequency
static const float kHTKLogStep = logf(6.4f) / 27.0f;     // Log spacing factor: ln(6.4)/27

/// Convert frequency in Hz to mel scale (HTK formula).
static float hzToMel(float hz) {
    if (hz < kHTKMinLogHz) {
        return hz / kHTKFreqSp;
    }
    return 15.0f + logf(hz / kHTKMinLogHz) / kHTKLogStep;
}

/// Convert mel value to frequency in Hz (HTK formula).
static float melToHz(float mel) {
    float melBreak = kHTKMinLogHz / kHTKFreqSp;  // mel value at breakpoint
    if (mel < melBreak) {
        return mel * kHTKFreqSp;
    }
    return kHTKMinLogHz * expf((mel - 15.0f) * kHTKLogStep);
}

// ── Mel filterbank generation ───────────────────────────────────────────────

/// Generate mel filterbank matrix matching librosa/faster-whisper.
/// Returns a vector of size nMels * (nFFT/2+1) in row-major order.
static std::vector<float> generateMelFilters(NSUInteger nMels,
                                             NSUInteger nFFT,
                                             NSUInteger samplingRate) {
    NSUInteger nFreqs = nFFT / 2 + 1;
    std::vector<float> filters(nMels * nFreqs, 0.0f);

    // Compute FFT bin frequencies: fftfreqs[k] = k * sr / n_fft
    std::vector<float> fftfreqs(nFreqs);
    for (NSUInteger k = 0; k < nFreqs; k++) {
        fftfreqs[k] = (float)k * (float)samplingRate / (float)nFFT;
    }

    // Compute nMels+2 evenly spaced points in mel domain
    float minMel = hzToMel(0.0f);
    float maxMel = hzToMel((float)samplingRate / 2.0f);

    NSUInteger nPoints = nMels + 2;
    std::vector<float> melPoints(nPoints);
    for (NSUInteger i = 0; i < nPoints; i++) {
        melPoints[i] = minMel + (maxMel - minMel) * (float)i / (float)(nPoints - 1);
    }

    // Convert mel points back to Hz
    std::vector<float> hzPoints(nPoints);
    for (NSUInteger i = 0; i < nPoints; i++) {
        hzPoints[i] = melToHz(melPoints[i]);
    }

    // Build triangular filters with Slaney normalization
    for (NSUInteger m = 0; m < nMels; m++) {
        float lower = hzPoints[m];
        float center = hzPoints[m + 1];
        float upper = hzPoints[m + 2];

        // Slaney normalization: 2.0 / (upper - lower)
        float enorm = 2.0f / (upper - lower);

        for (NSUInteger k = 0; k < nFreqs; k++) {
            float freq = fftfreqs[k];
            float weight = 0.0f;

            if (freq >= lower && freq <= center && center != lower) {
                // Rising slope
                weight = (freq - lower) / (center - lower);
            } else if (freq > center && freq <= upper && upper != center) {
                // Falling slope
                weight = (upper - freq) / (upper - center);
            }

            filters[m * nFreqs + k] = weight * enorm;
        }
    }

    return filters;
}

// ── Reflect padding helper ──────────────────────────────────────────────────

/// Reflect-pad signal at both ends (no edge repetition, matching numpy reflect mode).
/// For index i < 0: sample[-i]. For index i >= length: sample[2*length - 2 - i].
/// Uses signed arithmetic throughout to avoid unsigned underflow on short signals.
static std::vector<float> reflectPad(const float *signal, NSUInteger length,
                                     NSUInteger padLeft, NSUInteger padRight) {
    NSUInteger paddedLength = padLeft + length + padRight;
    std::vector<float> padded(paddedLength);

    // Reflect padding requires at least 2 samples.
    // Fall back to zero-padding (or constant-padding for length==1).
    if (length < 2) {
        std::fill(padded.begin(), padded.end(), 0.0f);
        if (length == 1) {
            // Constant pad with the single sample value
            std::fill(padded.begin(), padded.end(), signal[0]);
        }
        if (length >= 1) {
            memcpy(padded.data() + padLeft, signal, length * sizeof(float));
        }
        return padded;
    }

    NSInteger sLength = (NSInteger)length;

    // Left padding (reflected, no edge repeat)
    for (NSUInteger i = 0; i < padLeft; i++) {
        NSInteger srcIdx = (NSInteger)(padLeft - i);  // 1, 2, 3, ...
        // Wrap into valid range [0, length-1] using reflect (no edge repeat)
        // Period is 2*(length-1). Map into [0, period), then fold.
        NSInteger period = 2 * (sLength - 1);
        if (period > 0) {
            srcIdx = srcIdx % period;
            if (srcIdx < 0) srcIdx += period;
            if (srcIdx >= sLength) {
                srcIdx = period - srcIdx;
            }
        } else {
            srcIdx = 0;
        }
        padded[i] = signal[srcIdx];
    }

    // Copy original signal
    memcpy(padded.data() + padLeft, signal, length * sizeof(float));

    // Right padding (reflected, no edge repeat)
    for (NSUInteger i = 0; i < padRight; i++) {
        NSInteger srcIdx = sLength - 2 - (NSInteger)i;  // length-2, length-3, ...
        // Wrap into valid range [0, length-1] using reflect (no edge repeat)
        NSInteger period = 2 * (sLength - 1);
        if (period > 0) {
            srcIdx = srcIdx % period;
            if (srcIdx < 0) srcIdx += period;
            if (srcIdx >= sLength) {
                srcIdx = period - srcIdx;
            }
        } else {
            srcIdx = 0;
        }
        padded[padLeft + length + i] = signal[srcIdx];
    }

    return padded;
}

// ── Bluestein FFT helper ────────────────────────────────────────────────────
//
// Computes an N-point DFT (where N can be arbitrary, e.g. 400) using
// Bluestein's algorithm, which reduces to a power-of-2 circular convolution.
// Uses vDSP_fft_zip (complex-to-complex FFT) for the convolution.

/// Compute the smallest power of 2 >= n.
/// Returns 0 if the result would overflow NSUInteger.
static NSUInteger nextPowerOf2(NSUInteger n) {
    if (n == 0) return 1;
    if (n > (NSUIntegerMax >> 1) + 1) return 0;  // overflow guard
    NSUInteger p = 1;
    while (p < n) p <<= 1;
    return p;
}

/// Compute log2 of a power-of-2 value.
static vDSP_Length log2OfPow2(NSUInteger n) {
    vDSP_Length log2n = 0;
    while ((1UL << log2n) < n) log2n++;
    return log2n;
}

/// Bluestein DFT context: precomputed chirp sequences and FFT setup for
/// computing an N-point DFT using a power-of-2 FFT of length M >= 2N-1.
struct BluesteinDFT {
    NSUInteger N;           // DFT length
    NSUInteger M;           // Power-of-2 convolution length
    vDSP_Length log2M;
    FFTSetup fftSetup;

    // Precomputed chirp: w[n] = exp(-j * pi * n^2 / N) for n = 0..N-1
    std::vector<float> chirpReal;  // cos(pi * n^2 / N)
    std::vector<float> chirpImag;  // -sin(pi * n^2 / N)

    // Precomputed FFT of the conjugate chirp sequence (split complex, length M).
    std::vector<float> bFFTReal;
    std::vector<float> bFFTImag;

    // Pre-computed conjugate chirp imaginary (negated chirpImag) for step 5.
    std::vector<float> chirpConjImag;

    // Work buffers (reused across calls to executeBluesteinDFT).
    // NOTE: Reusing these makes executeBluesteinDFT non-thread-safe for the
    // same BluesteinDFT context. Each thread must use its own context.
    std::vector<float> workAR;
    std::vector<float> workAI;
    std::vector<float> workCR;
    std::vector<float> workCI;
};

/// Create a Bluestein DFT context for length N.
static BluesteinDFT *createBluesteinDFT(NSUInteger N) {
    BluesteinDFT *ctx = new BluesteinDFT();
    ctx->N = N;
    ctx->M = nextPowerOf2(2 * N - 1);
    if (ctx->M == 0) {
        delete ctx;
        return nullptr;
    }
    ctx->log2M = log2OfPow2(ctx->M);

    ctx->fftSetup = vDSP_create_fftsetup(ctx->log2M, kFFTRadix2);
    if (!ctx->fftSetup) {
        delete ctx;
        return nullptr;
    }

    // Compute chirp sequence: chirp[n] = exp(-j * pi * n^2 / N)
    ctx->chirpReal.resize(N);
    ctx->chirpImag.resize(N);
    double piOverN = M_PI / (double)N;
    for (NSUInteger n = 0; n < N; n++) {
        double angle = piOverN * (double)(n * n);
        ctx->chirpReal[n] = (float)cos(angle);
        ctx->chirpImag[n] = (float)(-sin(angle));
    }

    // Build b sequence (conjugate chirp, wrapped) and compute its FFT.
    // b[0] = conj(chirp[0]), b[n] = conj(chirp[n]) for n=1..N-1,
    // b[M-n] = conj(chirp[n]) for n=1..N-1, b[other] = 0.
    ctx->bFFTReal.resize(ctx->M, 0.0f);
    ctx->bFFTImag.resize(ctx->M, 0.0f);

    ctx->bFFTReal[0] = ctx->chirpReal[0];
    ctx->bFFTImag[0] = -ctx->chirpImag[0];
    for (NSUInteger n = 1; n < N; n++) {
        float conjR = ctx->chirpReal[n];
        float conjI = -ctx->chirpImag[n];
        ctx->bFFTReal[n] = conjR;
        ctx->bFFTImag[n] = conjI;
        ctx->bFFTReal[ctx->M - n] = conjR;
        ctx->bFFTImag[ctx->M - n] = conjI;
    }

    // FFT of b in-place using vDSP_fft_zip (complex-to-complex)
    DSPSplitComplex bSplit;
    bSplit.realp = ctx->bFFTReal.data();
    bSplit.imagp = ctx->bFFTImag.data();
    vDSP_fft_zip(ctx->fftSetup, &bSplit, 1, ctx->log2M, kFFTDirection_Forward);

    // Pre-compute conjugate chirp imaginary for step 5 (negated chirpImag).
    ctx->chirpConjImag.resize(N);
    for (NSUInteger n = 0; n < N; n++) {
        ctx->chirpConjImag[n] = -ctx->chirpImag[n];
    }

    // Pre-allocate work buffers for executeBluesteinDFT reuse.
    ctx->workAR.resize(ctx->M, 0.0f);
    ctx->workAI.resize(ctx->M, 0.0f);
    ctx->workCR.resize(ctx->M);
    ctx->workCI.resize(ctx->M);

    return ctx;
}

/// Destroy a Bluestein DFT context.
static void destroyBluesteinDFT(BluesteinDFT *ctx) {
    if (ctx) {
        if (ctx->fftSetup) {
            vDSP_destroy_fftsetup(ctx->fftSetup);
        }
        delete ctx;
    }
}

/// Execute Bluestein DFT: compute N-point DFT of real input.
/// Input: real-valued signal of length N.
/// Output: complex spectrum (outReal, outImag) of length N.
///
/// NOTE: Uses pre-allocated work buffers in ctx, making this function
/// non-thread-safe for the same BluesteinDFT context. Each thread must
/// use its own context instance.
static void executeBluesteinDFT(BluesteinDFT *ctx,
                                const float *inputReal,
                                float *outReal, float *outImag) {
    NSUInteger N = ctx->N;
    NSUInteger M = ctx->M;
    float *aR = ctx->workAR.data();
    float *aI = ctx->workAI.data();
    float *cR = ctx->workCR.data();
    float *cI = ctx->workCI.data();

    // Step 1: a[n] = x[n] * chirp[n] for n=0..N-1, vectorized
    vDSP_vmul(inputReal, 1, ctx->chirpReal.data(), 1, aR, 1, (vDSP_Length)N);
    vDSP_vmul(inputReal, 1, ctx->chirpImag.data(), 1, aI, 1, (vDSP_Length)N);
    // Zero-pad tail [N..M)
    vDSP_vclr(aR + N, 1, (vDSP_Length)(M - N));
    vDSP_vclr(aI + N, 1, (vDSP_Length)(M - N));

    // Step 2: FFT of a using vDSP_fft_zip (complex-to-complex, in-place)
    DSPSplitComplex aSplit = { aR, aI };
    vDSP_fft_zip(ctx->fftSetup, &aSplit, 1, ctx->log2M, kFFTDirection_Forward);

    // Step 3: Pointwise complex multiply A_FFT * B_FFT, vectorized
    // vDSP_zvmul with conjugate=+1 computes C = A * B (no conjugation).
    DSPSplitComplex bSplit = { ctx->bFFTReal.data(), ctx->bFFTImag.data() };
    DSPSplitComplex cSplit = { cR, cI };
    vDSP_zvmul(&aSplit, 1, &bSplit, 1, &cSplit, 1, (vDSP_Length)M, /*conjugate=*/+1);

    // Step 4: Inverse FFT of product
    vDSP_fft_zip(ctx->fftSetup, &cSplit, 1, ctx->log2M, kFFTDirection_Inverse);

    // vDSP_fft_zip inverse does NOT divide by M, so scale by 1/M.
    float invM = 1.0f / (float)M;

    // Step 5: Scale c by 1/M, then multiply by conj(chirp), vectorized.
    // Scale first N elements of c by invM.
    vDSP_vsmul(cR, 1, &invM, cR, 1, (vDSP_Length)N);
    vDSP_vsmul(cI, 1, &invM, cI, 1, (vDSP_Length)N);
    // Multiply scaled c * conj(chirp).
    // vDSP_zvmul with conjugate=-1 computes C = conj(A) * B.
    // To get c * conj(chirp), pass chirp as A and c as B with conjugate=-1:
    //   C = conj(chirp) * cScaled = cScaled * conj(chirp).
    DSPSplitComplex cScaled = { cR, cI };
    DSPSplitComplex chirpSplit = { ctx->chirpReal.data(), ctx->chirpImag.data() };
    DSPSplitComplex outSplit = { outReal, outImag };
    vDSP_zvmul(&chirpSplit, 1, &cScaled, 1, &outSplit, 1, (vDSP_Length)N, /*conjugate=*/-1);
}

// ── Implementation ──────────────────────────────────────────────────────────

@implementation MWFeatureExtractor {
    NSUInteger _nFFT;
    NSUInteger _hopLength;
    NSUInteger _samplingRate;
    std::vector<float> _melFilters;    // nMels * (nFFT/2+1), row-major
    std::vector<float> _hannWindow;    // nFFT periodic Hann
    BluesteinDFT *_bluesteinCtx;
}

// ── Initializers ────────────────────────────────────────────────────────────

- (instancetype)initWithNMels:(NSUInteger)nMels
                         nFFT:(NSUInteger)nFFT
                    hopLength:(NSUInteger)hopLength
                 samplingRate:(NSUInteger)samplingRate {
    self = [super init];
    if (self) {
        // Validate parameters to prevent division by zero and other undefined behavior.
        if (nFFT == 0 || hopLength == 0 || samplingRate == 0 || nMels == 0) {
            MWLog(@"MWFeatureExtractor: Invalid parameters (nFFT=%lu, hop=%lu, sr=%lu, mels=%lu)",
                  (unsigned long)nFFT, (unsigned long)hopLength,
                  (unsigned long)samplingRate, (unsigned long)nMels);
            [self release];
            return nil;
        }

        _nMels = nMels;
        _nFFT = nFFT;
        _hopLength = hopLength;
        _samplingRate = samplingRate;
        // Generate mel filterbank (computed once, reused)
        _melFilters = generateMelFilters(nMels, nFFT, samplingRate);

        // Generate periodic Hann window: 0.5 * (1 - cos(2*pi*n/N)) for n=0..N-1
        _hannWindow.resize(nFFT);
        float twoPiOverN = 2.0f * (float)M_PI / (float)nFFT;
        for (NSUInteger n = 0; n < nFFT; n++) {
            _hannWindow[n] = 0.5f * (1.0f - cosf(twoPiOverN * (float)n));
        }

        // Create Bluestein DFT context for arbitrary-length FFT.
        // vDSP DFT functions only support lengths factorable as f * 2^n
        // where f in {1, 3, 5, 15}. nFFT=400 is not supported, so we use
        // Bluestein's algorithm which computes an N-point DFT via a
        // power-of-2 FFT of length M >= 2N-1.
        _bluesteinCtx = createBluesteinDFT(nFFT);
        if (!_bluesteinCtx) {
            MWLog(@"MWFeatureExtractor: Failed to create Bluestein DFT for n_fft=%lu",
                  (unsigned long)nFFT);
            [self release];
            return nil;
        }
    }
    return self;
}

- (instancetype)initWithNMels:(NSUInteger)nMels {
    return [self initWithNMels:nMels
                          nFFT:kMWDefaultNFFT
                     hopLength:kMWDefaultHopLength
                  samplingRate:kMWTargetSampleRate];
}

- (void)dealloc {
    destroyBluesteinDFT(_bluesteinCtx);
    _bluesteinCtx = nullptr;
    [super dealloc];
}

// ── Properties ──────────────────────────────────────────────────────────────

- (NSData *)melFilterbank {
    return [NSData dataWithBytes:_melFilters.data()
                          length:_melFilters.size() * sizeof(float)];
}

// ── STFT computation ────────────────────────────────────────────────────────

/// Compute STFT magnitude squared for the given (already padded) signal.
/// Returns magnitudes squared in row-major order: magnitudes[frame * nFreqs + freq].
/// nFreqs = nFFT/2 + 1. Last frame is dropped to match Python stft[..., :-1].
- (std::vector<float>)computeSTFTMagnitudesSquared:(const float *)signal
                                      signalLength:(NSUInteger)signalLength
                                        frameCount:(NSUInteger &)outFrameCount {
    NSUInteger nFreqs = _nFFT / 2 + 1;

    // Guard: signal must be long enough for at least 2 STFT frames
    // (we drop the last frame, so need totalFrames >= 2).
    if (signalLength <= _nFFT) {
        outFrameCount = 0;
        return std::vector<float>();
    }

    // Number of STFT frames (before dropping last)
    NSUInteger totalFrames = (signalLength - _nFFT) / _hopLength + 1;

    if (totalFrames < 2) {
        outFrameCount = 0;
        return std::vector<float>();
    }

    // Drop last frame to match Python stft[..., :-1]
    NSUInteger nFrames = totalFrames - 1;
    outFrameCount = nFrames;

    // Guard against size_t overflow in allocation (Fix H3)
    if (nFreqs > 0 && nFrames > SIZE_MAX / nFreqs) {
        outFrameCount = 0;
        return {};
    }

    // Allocate output: nFrames rows x nFreqs cols (row-major)
    std::vector<float> magnitudes(nFreqs * nFrames, 0.0f);

    // Temporary buffers
    std::vector<float> windowedFrame(_nFFT);
    std::vector<float> outReal(_nFFT);
    std::vector<float> outImag(_nFFT);

    for (NSUInteger f = 0; f < nFrames; f++) {
        NSUInteger offset = f * _hopLength;

        // Apply Hann window
        vDSP_vmul(signal + offset, 1, _hannWindow.data(), 1,
                  windowedFrame.data(), 1, (vDSP_Length)_nFFT);

        // Compute DFT via Bluestein's algorithm
        executeBluesteinDFT(_bluesteinCtx,
                            windowedFrame.data(),
                            outReal.data(), outImag.data());

        // Extract magnitude squared for bins 0..nFFT/2, vectorized
        float *magRow = magnitudes.data() + f * nFreqs;
        DSPSplitComplex sc = { outReal.data(), outImag.data() };
        vDSP_zvmags(&sc, 1, magRow, 1, (vDSP_Length)nFreqs);
    }

    return magnitudes;
}

// ── Full pipeline ───────────────────────────────────────────────────────────

- (nullable NSData *)computeMelSpectrogramFromAudio:(NSData *)audio
                                         frameCount:(NSUInteger *)outFrameCount
                                              error:(NSError **)error {
    // Serialize mel computation on this instance to prevent concurrent calls
    // from corrupting shared BluesteinDFT work buffers.  Mel computation is
    // fast (~7ms for 30s audio) and not the bottleneck (GPU encode dominates),
    // so serialization has negligible impact on throughput.  (Fix C2)
    @synchronized (self) {
    try {
        if (!audio || [audio length] == 0) {
            MWSetError(error, MWErrorCodeEncodeFailed,
                       @"Input audio data is empty or nil");
            return nil;
        }

        if ([audio length] % sizeof(float) != 0) {
            MWSetError(error, MWErrorCodeEncodeFailed,
                       @"Input audio length is not a multiple of sizeof(float)");
            return nil;
        }

        NSUInteger nSamples = [audio length] / sizeof(float);
        const float *audioPtr = (const float *)[audio bytes];

        // Step 1: Pad with kMWDefaultPadding zeros at end (matching Python padding=160)
        NSUInteger paddedLength = nSamples + kMWDefaultPadding;
        std::vector<float> paddedAudio(paddedLength, 0.0f);
        memcpy(paddedAudio.data(), audioPtr, nSamples * sizeof(float));

        // Step 2: Reflect-pad by nFFT/2 on each side for center=True STFT
        NSUInteger padSize = _nFFT / 2;
        std::vector<float> reflected = reflectPad(paddedAudio.data(), paddedLength,
                                                  padSize, padSize);
        NSUInteger reflectedLength = reflected.size();

        // Step 3: Compute STFT magnitude squared
        NSUInteger nFrames = 0;
        std::vector<float> magnitudes = [self computeSTFTMagnitudesSquared:reflected.data()
                                                             signalLength:reflectedLength
                                                               frameCount:nFrames];

        NSUInteger nFreqs = _nFFT / 2 + 1;

        // Step 4: Mel filterbank multiply
        // melFilters: (_nMels x nFreqs), row-major
        // magnitudes: (nFrames x nFreqs), row-major — mag[frame * nFreqs + freq]
        // result: (_nMels x nFrames), row-major
        //
        // mel = melFilters @ magnitudes^T
        //     = (_nMels x nFreqs) @ (nFreqs x nFrames)
        //     = (_nMels x nFrames)
        std::vector<float> melSpec(_nMels * nFrames, 0.0f);
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                    (int)_nMels,           // M: rows of result
                    (int)nFrames,          // N: cols of result
                    (int)nFreqs,           // K: inner dimension
                    1.0f,                  // alpha
                    _melFilters.data(),    // A: mel filters (_nMels x nFreqs)
                    (int)nFreqs,           // lda
                    magnitudes.data(),     // B: magnitudes (nFrames x nFreqs) row-major
                    (int)nFreqs,           // ldb
                    0.0f,                  // beta
                    melSpec.data(),        // C: result (_nMels x nFrames)
                    (int)nFrames);         // ldc

        // Step 5: Log-mel: log10(max(mel, 1e-10))
        NSUInteger totalElements = _nMels * nFrames;

        // Clamp to floor: max(x, kMWMelFloor)
        float floor = kMWMelFloor;
        vDSP_vthr(melSpec.data(), 1, &floor, melSpec.data(), 1, (vDSP_Length)totalElements);

        // Compute log10 in-place
        int totalElementsInt = (int)totalElements;
        vvlog10f(melSpec.data(), melSpec.data(), &totalElementsInt);

        // Step 6: Normalize
        // Find max value
        float maxVal = 0.0f;
        vDSP_maxv(melSpec.data(), 1, &maxVal, (vDSP_Length)totalElements);

        // Clamp: max(log_spec, max_val - kMWLogDynamicRange)
        float lowerBound = maxVal - kMWLogDynamicRange;
        vDSP_vthr(melSpec.data(), 1, &lowerBound, melSpec.data(), 1, (vDSP_Length)totalElements);

        // Scale: (log_spec + kMWLogOffset) / kMWLogScale
        float offset = kMWLogOffset;
        vDSP_vsadd(melSpec.data(), 1, &offset, melSpec.data(), 1, (vDSP_Length)totalElements);

        float invScale = 1.0f / kMWLogScale;
        vDSP_vsmul(melSpec.data(), 1, &invScale, melSpec.data(), 1, (vDSP_Length)totalElements);

        if (outFrameCount) *outFrameCount = nFrames;

        return [NSData dataWithBytes:melSpec.data()
                              length:totalElements * sizeof(float)];

    } catch (const std::exception &e) {
        MWSetError(error, MWErrorCodeEncodeFailed,
                   [NSString stringWithFormat:@"Mel spectrogram computation failed: %s", e.what()]);
        return nil;
    } catch (...) {
        MWSetError(error, MWErrorCodeEncodeFailed,
                   @"Mel spectrogram computation failed with unknown error");
        return nil;
    }
    } // @synchronized (self)  (Fix C2)
}

@end
