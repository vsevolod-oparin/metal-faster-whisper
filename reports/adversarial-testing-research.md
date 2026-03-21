# Adversarial Software Testing Best Practices -- Comprehensive Research Report

**Date:** 2026-03-21
**Scope:** Adversarial testing mindset, edge case discovery, fast test execution, test organization, and actionable testing instructions for AI-assisted development
**Context:** metal-faster-whisper project (C++/Objective-C++, Metal/MPS, MRC, no ARC)

---

## Executive Summary

This report synthesizes research from Google's testing practices, Martin Fowler's test pyramid, Kent Beck's TDD philosophy, James Bach's exploratory testing heuristics, Netflix's chaos engineering, and modern techniques including property-based testing, mutation testing, metamorphic testing, and deterministic simulation testing (Antithesis).

**Central thesis: the most effective tests think like attackers, not like developers.** A developer writes tests to confirm code works. An adversarial tester writes tests to prove code breaks. The difference is not just mindset -- it is methodology. Adversarial tests systematically explore the space of inputs that developers did not consider, using techniques that range from simple boundary value analysis to sophisticated property-based fuzzing.

**Key findings:**

1. **Most bugs hide at boundaries.** Off-by-one errors, empty inputs, nil/null values, integer overflow, and type mismatches account for the majority of production bugs. Testing these costs almost nothing in execution time.

2. **Property-based testing finds bugs humans cannot imagine.** By generating thousands of randomized inputs constrained by properties, frameworks like QuickCheck have found bugs requiring 17-step reproduction sequences (LevelDB), buffer overflows in well-tested libraries (Argon2), and date parsing errors in established packages (dateutil).

3. **Mutation testing reveals weak tests.** High code coverage does not mean high test quality. Mutation testing introduces small code changes (mutants) and checks whether tests catch them. Surviving mutants expose tests that pass but verify nothing meaningful.

4. **Fast tests must be the default.** Google enforces test size limits: small tests (unit) must complete in under 60 seconds, with no I/O, no network, no sleep. The target ratio is 80% unit tests, 20% broader-scoped tests. Push tests as far down the pyramid as possible.

5. **Test smells are as dangerous as code smells.** Tautological tests, over-mocking, flaky tests, and implementation-coupled tests provide false confidence. They are worse than no tests because they consume maintenance effort while catching nothing.

---

## 1. Adversarial Testing Mindset

### 1.1 Think Like an Attacker

The fundamental shift from developer testing to adversarial testing:

| Developer Mindset | Attacker Mindset |
|---|---|
| "Does it work with valid input?" | "What breaks it?" |
| "Does the happy path succeed?" | "What happens on every unhappy path?" |
| "I'll test typical values" | "I'll test the most pathological values I can construct" |
| "The error handler probably works" | "I'll force every error path" |
| "Users won't do that" | "Users (and attackers) will do exactly that" |

The attacker mindset requires asking five questions for every function:

1. **What are the implicit assumptions?** Every function assumes something about its inputs. Find those assumptions and violate them.
2. **What happens at zero?** Zero items, zero length, zero bytes, zero duration.
3. **What happens at maximum?** INT_MAX, SIZE_MAX, the largest buffer the system can allocate.
4. **What happens with nil/null/empty?** Every pointer parameter. Every optional. Every collection.
5. **What happens twice?** Call it twice. Release it twice. Initialize it twice.

### 1.2 Systematic Edge Case Identification

Beyond guessing, use structured approaches:

**The ZOMBIES Mnemonic** (James Grenning):

- **Z**ero -- empty collections, zero counts, zero-length strings, zero duration
- **O**ne -- single element, single character, single iteration
- **M**any -- large collections, many iterations, concurrent access
- **B**oundary behaviors -- edges where behavior changes (full/empty, min/max, signed/unsigned crossover)
- **I**nterface definition -- what does the API contract promise? Test at the contract boundary
- **E**xception/error handling -- force every error path, verify error codes and messages
- **S**imple scenarios first -- build from simple to complex, never skip the trivial case

**The "Zero, One, Many" Principle:**

For any quantity in your system, test with exactly 0, exactly 1, and N where N is large enough to exercise loops, pagination, buffer management, and allocation patterns. Most off-by-one bugs manifest at the transition from 0 to 1 or from 1 to many.

### 1.3 Evil Input Generation Strategies

A systematic catalog of inputs designed to break code:

**Numeric inputs:**
- 0, -1, 1, -0 (IEEE 754 negative zero)
- INT_MIN, INT_MAX, INT_MIN+1, INT_MAX-1
- UINT_MAX (for unsigned), SIZE_MAX
- NaN, +Infinity, -Infinity, denormalized floats
- Powers of 2 (buffer size boundaries): 255, 256, 257, 65535, 65536
- Floating point: 0.1 + 0.2 (not equal to 0.3), FLT_EPSILON, DBL_EPSILON

**String/text inputs:**
- Empty string "", nil, single character "x"
- Unicode: multibyte characters, emoji, RTL text, zero-width joiners, BOM markers
- Very long strings (1MB+), strings with embedded nulls
- Format string attacks: "%s%s%s%n"
- Path traversal: "../../../etc/passwd"

**Collection inputs:**
- Empty array/dictionary, nil collection
- Single-element collection
- Very large collection (1M+ items)
- Collection with duplicate elements
- Collection with nil elements mixed in

**Binary/data inputs:**
- Empty NSData, nil NSData
- Single byte, odd-length data (for aligned access)
- Data with size not matching expected struct size
- Truncated data (partial header)
- Data larger than expected (extra trailing bytes)

**Audio-specific (for this project):**
- 0 samples, 1 sample, exactly 1 window of samples
- All-zero audio (silence), all-max audio (clipping)
- Audio shorter than mel window size
- Audio at wrong sample rate
- NaN samples, infinity samples embedded in valid audio

### 1.4 Fault Injection Patterns

Deliberately introduce failures to test error handling:

```
Fault Injection Categories:
1. Resource exhaustion -- malloc returns NULL, disk full, file descriptor limit
2. Timing faults -- slow responses, timeouts, out-of-order delivery
3. Data corruption -- bit flips, truncation, wrong encoding
4. Dependency failures -- model file missing, GPU unavailable, library not loaded
5. State corruption -- double-free, use-after-free, uninitialized memory
```

In C++/Obj-C++, fault injection at the unit test level:

```objc
// Test: what happens when model path is valid but file is corrupted?
static void test_corrupted_model(void) {
    // Create a temp file with garbage bytes
    NSString *tmpPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"garbage.bin"];
    NSData *garbage = [NSData dataWithBytes:"NOT_A_MODEL" length:11];
    [garbage writeToFile:tmpPath atomically:YES];

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc]
        initWithModelPath:tmpPath error:&error];
    ASSERT_TRUE("corrupted_model", t == nil,
        @"should fail on corrupted model");
    ASSERT_TRUE("corrupted_model", error != nil,
        @"should set error");

    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
    reportResult("corrupted_model", YES, nil);
}
```

---

## 2. Edge Case Discovery Techniques

### 2.1 Property-Based Testing

Property-based testing (PBT) was invented by Koen Claessen and John Hughes for Haskell (QuickCheck, 1999) and has since been ported to every major language: Hypothesis (Python), fast-check (JavaScript), SwiftCheck (Swift), RapidCheck (C++).

**How it works:**
1. Define a *property* -- an invariant that should hold for all valid inputs
2. The framework generates hundreds/thousands of random inputs
3. When a property violation is found, the framework *shrinks* the input to a minimal failing case

**Properties to test in an audio transcription library:**

```
Property 1 (Roundtrip):    encode(audio) then decode(encoded) produces valid output
Property 2 (Monotonicity): segment timestamps are monotonically increasing
Property 3 (Idempotence):  transcribing the same audio twice yields the same result
Property 4 (Boundedness):  all probabilities in [0.0, 1.0]
Property 5 (Non-crash):    any NSData input to transcribeAudio: does not crash
```

**Real bugs found by PBT:**
- Google LevelDB: required 17-step reproduction sequence, found automatically
- Argon2: buffer overflow when hash_len > 512 (found by Hypothesis)
- dateutil: swapped year/month parsing ISO 8601 date for year 0005
- js-yaml, query-string, left-pad: undiscovered bugs in popular npm packages

**Pseudo-code for property-based audio test:**

```
for trial in 1..1000:
    n_samples = random(0, 480000)  // 0 to 30 seconds
    audio = generate_random_float_array(n_samples, range=[-1.0, 1.0])
    data = NSData(bytes: audio, length: n_samples * 4)

    result = transcriber.transcribeAudio(data, language: "en", ...)

    // Property: never crashes
    assert(result != nil)
    // Property: segments have valid timestamps
    for segment in result:
        assert(segment.startTime >= 0)
        assert(segment.endTime >= segment.startTime)
        assert(segment.endTime <= float(n_samples) / 16000.0 + 0.5)
```

### 2.2 Combinatorial / Pairwise Testing

When a function has multiple parameters, exhaustive testing explodes combinatorially. Pairwise (2-way) testing covers all pairs of parameter values with dramatically fewer test cases.

Research finding: **interactions between any two parameters account for most bugs** (NIST). Pairwise testing reduces test suites by 85-95% while detecting up to 80% of faults.

Example for transcription options:

```
Parameters:
  language:     ["en", "ja", "zh", "auto"]
  task:         ["transcribe", "translate"]
  compute_type: ["float32", "float16", "int8"]
  beam_size:    [1, 5, 10]
  vad_filter:   [YES, NO]

Exhaustive: 4 x 2 x 3 x 3 x 2 = 144 combinations
Pairwise:   ~15-20 test cases covering all pairs
```

Tools: PICT (Microsoft), ACTS (NIST), AllPairs.

### 2.3 State Machine / Model-Based Testing

Model the system as a state machine, then generate test sequences that cover all states and transitions:

```
MWTranscriber states:
  UNINITIALIZED -> LOADED         (initWithModelPath:)
  LOADED        -> TRANSCRIBING   (transcribeURL:)
  TRANSCRIBING  -> LOADED         (transcription complete)
  LOADED        -> UNLOADED       (release/dealloc)

Edge transitions to test:
  - UNINITIALIZED -> transcribeURL:  (should fail gracefully)
  - LOADED -> initWithModelPath:     (double init)
  - TRANSCRIBING -> release          (cancel mid-transcription)
  - UNLOADED -> transcribeURL:       (use after release)
```

### 2.4 Contract-Based Testing

Design by Contract (Bertrand Meyer) defines:
- **Preconditions**: what must be true before calling a function
- **Postconditions**: what must be true after the function returns
- **Invariants**: what must always be true for a valid object

For adversarial testing, **deliberately violate every precondition** and verify the system handles it gracefully:

```objc
// Precondition: nFrames > 0
//               mel.length == nMels * nFrames * sizeof(float)
// Adversarial: violate both
[t encodeFeatures:[NSData data] nFrames:0 error:&error];
[t encodeFeatures:smallData nFrames:99999 error:&error];
[t encodeFeatures:nil nFrames:100 error:&error];
```

### 2.5 Metamorphic Testing

When you cannot determine the correct output for a given input (the "oracle problem"), metamorphic testing defines **relations between inputs and outputs** that must hold:

**Metamorphic relations for audio transcription:**

1. **Silence invariance**: prepending/appending silence should not change transcription text
2. **Volume invariance**: scaling audio amplitude by 0.5x or 2.0x should produce similar text
3. **Concatenation**: transcribing audio[A+B] should produce text containing text(A) and text(B)
4. **Repeat invariance**: the same word repeated should produce that word repeated
5. **Language consistency**: if language="en", output should contain English tokens regardless of non-speech noise

```
// Metamorphic test: volume scaling
audio_normal = load("jfk.flac")
audio_quiet  = scale(audio_normal, 0.5)
audio_loud   = scale(audio_normal, 2.0)

text_normal = transcribe(audio_normal)
text_quiet  = transcribe(audio_quiet)
text_loud   = transcribe(audio_loud)

assert word_overlap(text_normal, text_quiet) > 0.8
assert word_overlap(text_normal, text_loud)  > 0.8
```

---

## 3. Counterintuitive but Legal Code-Breaking Tests

### 3.1 Off-by-One and Integer Boundary Tests

```cpp
// The classic off-by-one: fence post problem
// If processing N items in chunks of K, what happens when N % K != 0?
// Audio: 16001 samples at 16kHz = 1.00006 seconds
//        Does the last sample get processed or dropped?

// Integer overflow on 32-bit:
int32_t samples = 2147483647;  // INT32_MAX
size_t bytes = (size_t)samples * sizeof(float);  // overflow on 32-bit

// Unsigned arithmetic trap:
NSUInteger len = 0;
NSUInteger adjusted = len - 1;  // wraps to SIZE_MAX
```

### 3.2 Floating Point Precision

```objc
// NaN propagation
float samples[] = {0.1f, NAN, 0.3f, 0.4f};
// Does mel spectrogram handle NaN? Propagate or crash?

// Denormalized numbers (extremely slow on some hardware)
float denorm = FLT_MIN * 0.5f;

// Negative zero
float negzero = -0.0f;
// negzero == 0.0f is true per IEEE 754
// but 1.0f/negzero == -INFINITY reveals the difference

// Comparison traps
float a = 0.1f + 0.2f;
// a == 0.3f FAILS -- the most common floating point bug
```

### 3.3 Concurrency Edge Cases

```objc
// Race: two threads transcribing on the same MWTranscriber
dispatch_group_t g = dispatch_group_create();
dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);

dispatch_group_async(g, q, ^{
    [transcriber transcribeURL:url1 language:@"en" ...];
});
dispatch_group_async(g, q, ^{
    [transcriber transcribeURL:url2 language:@"en" ...];
});
dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
// Does it crash? Corrupt state? Return wrong results?
```

### 3.4 Resource Exhaustion

```objc
// Memory pressure: allocate many transcribers
NSMutableArray *transcribers = [NSMutableArray array];
for (int i = 0; i < 100; i++) {
    MWTranscriber *t = [[MWTranscriber alloc]
        initWithModelPath:path error:nil];
    if (t) [transcribers addObject:t];
    // Does it fail gracefully or crash when memory exhausted?
}
for (MWTranscriber *t in transcribers) [t release];
```

### 3.5 Re-entrancy

```objc
// Call transcribe from within a segment callback
[t transcribeURL:url language:@"en" task:@"transcribe" options:nil
  segmentHandler:^(MWTranscriptionSegment *seg, BOOL *stop) {
      // Re-entrant call -- is this safe?
      NSError *innerError = nil;
      [t transcribeURL:url2 language:@"en" task:@"transcribe"
          options:nil segmentHandler:nil info:nil error:&innerError];
  } info:nil error:&error];
```

### 3.6 Order-Dependent Behavior

```objc
// Does the result change if we transcribe the same file twice?
NSArray *result1 = [t transcribeURL:url ...];
NSArray *result2 = [t transcribeURL:url ...];
// Results should be identical (determinism test)

// Does transcribing file A then B give different results
// than transcribing file B then A?
// (Checks for leaked internal state between calls)
```

### 3.7 Time-Dependent Behavior

```objc
// Float precision degrades for large timestamps
float t1 = 16777216.0f;   // 2^24
float t2 = t1 + 1.0f;
// t1 == t2 in float32! Timestamps become indistinguishable
// after ~194 days of audio
```

---

## 4. Mutation Testing

### 4.1 How Mutation Testing Reveals Weak Tests

Mutation testing introduces small changes ("mutants") to production code and checks if tests catch them:

| Mutation Type | Example | What It Reveals |
|---|---|---|
| Boundary mutation | `<` becomes `<=` | Missing boundary test |
| Constant mutation | `0` becomes `1` | Magic number not tested |
| Return value mutation | `return result` becomes `return nil` | Assertion too weak |
| Negation mutation | `if (valid)` becomes `if (!valid)` | Happy path only tested |
| Arithmetic mutation | `+` becomes `-` | Calculation not verified |
| Void method mutation | Delete method call | Side effect not asserted |

**Key insight**: High code coverage does NOT mean high mutation score. A test can execute every line but verify nothing. Mutation testing exposes these "line hitter" tests.

### 4.2 Practical Application

A mutation score of 80%+ indicates strong tests. Focus mutation testing on:
- Business logic and algorithms (mel spectrogram computation, VAD thresholds)
- Error handling paths (what if the error check is removed?)
- Boundary conditions (what if `>=` becomes `>`?)

Tools: Mull (C/C++ mutation testing), PIT (Java), mutmut (Python). For C++/Obj-C++, Mull integrates with LLVM/Clang.

---

## 5. Fast Test Execution Practices

### 5.1 Google's Test Size Classification

| Size | Time Limit | I/O | Network | Sleep | Threading |
|---|---|---|---|---|---|
| Small (unit) | 60 seconds | No | No | No | Single |
| Medium (integration) | 300 seconds | Localhost | Localhost only | Yes | Multiple |
| Large (e2e) | 900+ seconds | Yes | Yes | Yes | Multiple |

**Target ratio**: 80% small, 20% medium/large (Google's recommendation).

### 5.2 What Makes Tests Slow

Ranked by impact:

1. **Model loading** -- Loading a Whisper model takes 1-5 seconds. Never load per-test.
2. **GPU computation** -- Actual inference on Metal/MPS. Required for integration tests but not unit tests.
3. **File I/O** -- Reading audio files, model files. Use in-memory buffers for unit tests.
4. **Network access** -- Never in unit tests.
5. **Sleep/polling** -- Never use sleep-based waits. Use semaphores or completion handlers.
6. **Excessive setup** -- Creating complex object graphs when a simple stub would suffice.
7. **Large data** -- Processing 1-hour audio when 1-second audio tests the same code path.

### 5.3 Separating Fast from Slow Tests

```
test_m0_link.mm          -- FAST  (< 1s, no model)
test_m0_compute_types.mm -- FAST  (< 1s, no model)
test_m1_audio.mm         -- FAST  (< 2s, file I/O only)
test_m2_mel.mm           -- FAST  (< 2s, CPU computation)
test_m3_tokenizer.mm     -- FAST  (< 1s, no model)
test_edge_cases.mm       -- MEDIUM (needs model, < 10s)
test_m4_*_*.mm           -- MEDIUM (needs model, < 30s each)
test_e2e.mm              -- SLOW  (full pipeline, minutes)
test_benchmark.mm        -- SLOW  (performance measurement)
```

**Strategy**: Tag tests by speed tier. Run fast tests on every build. Run medium tests on every commit. Run slow tests nightly or on PR.

### 5.4 Making Tests Faster

**Shared model loading**: Load the model once in main(), pass to all test functions. The project already does this correctly.

**Minimal audio data**: Use the shortest possible audio that exercises the code path. For encoding tests, use synthetic mel data instead of decoding real audio.

**In-memory substitutes**: For file-based tests, use `[NSData dataWithBytes:length:]` instead of reading from disk.

**Avoid redundant computation**: If testing tokenization, do not also run mel extraction and encoding.

**Parallel test execution**: Each test binary can run in parallel since they are separate processes. Within a binary, tests that share a model instance must run sequentially.

### 5.5 When Slow Tests Are Necessary

Slow tests are acceptable when they test properties that cannot be verified any other way:

- **End-to-end transcription accuracy**: Must load model, process real audio, check output text
- **Performance benchmarks**: Must measure actual GPU execution time
- **Memory leak detection**: Must run full pipeline and measure RSS
- **Concurrency tests**: Must exercise real thread interaction with real GPU
- **Model compatibility**: Must verify different model sizes (tiny, base, small, medium, large)

These should run in CI on a schedule (nightly) or as a separate test target.

---

## 6. Test Smells and Anti-Patterns

### 6.1 The Most Dangerous Anti-Patterns

**Tautological Test** -- Tests that verify the code does what the code does:
```objc
// BAD: This test proves nothing
float result = computeMel(samples);
float expected = computeMel(samples);  // Same function!
ASSERT_EQ(result, expected);
```

**Over-Mocking (Mockery)** -- So many mocks that nothing real is tested:
```objc
// BAD: Testing the mock, not the system
id mockTranscriber = [MockTranscriber new];
[mockTranscriber setReturnValue:@"hello"];
NSString *result = [mockTranscriber transcribe:audio];
ASSERT_EQ(result, @"hello");
// Of course it equals what we told it to return
```

**Line Hitter** -- 100% coverage, zero assertions:
```objc
// BAD: Executes the code but checks nothing
static void test_mel_extraction(void) {
    NSData *mel = [extractor computeMelSpectrogram:audio];
    // No assertion! "Passes" even if mel is garbage.
    reportResult("mel_extraction", YES, nil);
}
```

**Happy Path Only** -- Tests only valid inputs. Never tests: empty audio, wrong language, corrupted audio, extremely long audio, silence, noise, mixed languages.

**Inspector** -- Tests that break encapsulation. Accessing private ivars via runtime introspection couples tests to implementation details.

**The Flaky Test** -- Passes sometimes, fails sometimes:
```
Common causes:
- Timing-dependent assertions (sleep + check)
- Floating-point comparison with == instead of epsilon
- Tests depending on hash map iteration order
- Tests depending on filesystem state from other tests
- Tests depending on current time/date
```

### 6.2 Complete Anti-Pattern Catalog

| Anti-Pattern | Description |
|---|---|
| Cuckoo | Test in wrong test class |
| Test-per-Method | Organized by method, not behavior |
| Giant | Thousands of lines per test file |
| Excessive Setup | Hundreds of lines of prep before testing |
| Conjoined Twins | Unit test that is actually integration |
| Local Hero | Only works on developer's machine |
| Generous Leftovers | Depends on data from prior test |
| Mockery | Mocks so deep nothing real is tested |
| Inspector | Breaks encapsulation for coverage |
| Line Hitter | Coverage without assertions |
| The Liar | Passes regardless of bugs |
| Happy Path | Only tests valid scenarios |
| Slow Poke | Prohibitively slow execution |
| Dodger | Tests side effects, avoids core behavior |
| Secret Catcher | Relies on exception catch, no assertion |
| Enumerator | Meaningless names: test1, test2, test3 |
| Free Ride | Unrelated assertions tacked onto existing test |
| Nitpicker | Compares full output when only parts matter |
| Sequencer | Assumes unordered collections have order |

### 6.3 Preventing Flaky Tests

1. **No shared mutable state between tests.** Each test starts clean.
2. **No time-dependent assertions.** Use fixed timestamps or relative comparisons.
3. **Epsilon comparison for floats.** Never use `==` for floating point.
4. **No order dependence.** Tests must pass in any order.
5. **Deterministic seeds.** If using random data, seed the RNG and log the seed.
6. **Quarantine flaky tests immediately.** A flaky test erodes trust in the entire suite.

### 6.4 Test Code Quality

From Google's Software Engineering book:

- **DAMP over DRY**: Test code should be "Descriptive And Meaningful Phrases" rather than aggressively de-duplicated. Readability trumps reuse in tests.
- **No test logic**: Tests should be "trivially correct upon inspection." No loops, no conditionals, no complex string concatenation in assertions.
- **Test behaviors, not methods**: Organize tests by behavior (what the system does), not by method (which function is called).
- **Clear failure messages**: When a test fails, the message should tell you exactly what went wrong without needing to read the test code.

---

## 7. Modern Testing Strategies

### 7.1 Arrange-Act-Assert with Minimal Arrange

The AAA pattern (Bill Wake, 2001) structures every test into three distinct sections:

```objc
static void test_encode_produces_correct_shape(MWTranscriber *t) {
    // ARRANGE: only what this test needs
    float mel[80 * 3000] = {0};
    NSData *melData = [NSData dataWithBytes:mel length:sizeof(mel)];

    // ACT: one action
    NSError *error = nil;
    NSData *encoded = [t encodeFeatures:melData nFrames:3000 error:&error];

    // ASSERT: focused verification
    ASSERT_TRUE("encode_shape", encoded != nil,
        fmtErr(@"encode failed", error));
    size_t expectedSize = 512 * 1500 * sizeof(float);
    ASSERT_EQ("encode_shape", [encoded length], expectedSize);
}
```

### 7.2 Test Doubles Hierarchy

| Type | Has Behavior? | Tracks Calls? | When to Use |
|---|---|---|---|
| Dummy | No | No | Fill parameters you do not care about |
| Stub | Canned responses | No | Control indirect inputs |
| Spy | Canned responses | Yes | Verify indirect outputs after the fact |
| Mock | Pre-programmed | Yes | Verify interaction contracts |
| Fake | Real but simplified | No | Replace slow deps (in-memory DB) |

**For this project**: Prefer fakes over mocks. A fake audio decoder that returns synthetic samples is more valuable than a mock that expects specific method calls.

### 7.3 Characterization Tests for Legacy Code

When porting from another implementation, characterization tests capture current behavior:

1. Call the function with known input
2. Record the actual output
3. Assert that future runs produce the same output
4. Use this as a safety net while refactoring

### 7.4 Deterministic Simulation Testing

Pioneered by the creators of FoundationDB, commercialized by Antithesis. The most advanced testing technique currently available:

- Run the complete system in a deterministic simulation
- Inject faults (network retries, thread hangs, node restarts) automatically
- All bugs are perfectly reproducible (no flaky tests)
- Combines fuzzing, property-based testing, and fault injection

The principle applies even at unit test level: **eliminate all sources of non-determinism** in your test suite.

---

## 8. C++/Objective-C++ Specific Testing

### 8.1 Sanitizers

Three sanitizers should be run regularly, but **never simultaneously** (they conflict):

**Address Sanitizer (ASan):**
- Detects: buffer overflow, use-after-free, double-free, stack overflow
- Overhead: ~2x slowdown
- Enable: `-fsanitize=address`
- Critical for MRC code where manual memory management is error-prone

**Thread Sanitizer (TSan):**
- Detects: data races, lock order inversions
- Overhead: ~5-15x slowdown
- Enable: `-fsanitize=thread`
- Critical for GCD + C++ thread pool interaction
- Note: on Apple platforms, TSan only works in the Simulator, not on-device

**Undefined Behavior Sanitizer (UBSan):**
- Detects: signed integer overflow, null pointer dereference, misaligned access, shift overflow
- Overhead: minimal (~10%)
- Enable: `-fsanitize=undefined`
- Catches subtle C++ UB that "works on my machine" but fails elsewhere

**Test plan strategy**: Create separate test configurations, one with ASan, one with TSan. Run UBSan with both.

### 8.2 Testing MRC (Manual Reference Counting)

```objc
// Test: verify no leak on error path
static void test_no_leak_on_error(void) {
    size_t rss_before = getCurrentRSS();

    for (int i = 0; i < 1000; i++) {
        @autoreleasepool {
            NSError *error = nil;
            MWTranscriber *t = [[MWTranscriber alloc]
                initWithModelPath:@"/bad" error:&error];
            [t release];
        }
    }

    size_t rss_after = getCurrentRSS();
    size_t leaked = rss_after > rss_before ? rss_after - rss_before : 0;
    ASSERT_TRUE("no_leak_on_error", leaked < 1024 * 1024,
        @"possible leak detected");
}
```

### 8.3 Testing Metal/GPU Code

1. **Metal availability**: Always check `MTLCreateSystemDefaultDevice()`. Tests should skip gracefully on machines without Metal.
2. **Determinism**: GPU floating point may differ slightly between runs or devices. Use epsilon comparisons.
3. **Command buffer completion**: Never assume GPU work is done without waiting.
4. **Buffer overflows**: Metal has no bounds checking. Overflows corrupt silently.
5. **Unified memory**: On Apple Silicon, CPU and GPU share memory. Test that buffers are not simultaneously modified.

### 8.4 Testing GCD/Concurrency

```objc
static void test_concurrent_transcriptions(
    MWTranscriber *t, NSString *dataDir) {
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue =
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
    __block BOOL anyFailure = NO;

    for (int i = 0; i < 10; i++) {
        dispatch_group_async(group, queue, ^{
            @autoreleasepool {
                NSString *path = [dataDir
                    stringByAppendingPathComponent:@"jfk.flac"];
                NSURL *url = [NSURL fileURLWithPath:path];
                NSError *error = nil;
                NSArray *segments = [t transcribeURL:url
                    language:@"en" task:@"transcribe"
                    options:nil segmentHandler:nil
                    info:nil error:&error];
                if (!segments) anyFailure = YES;
            }
        });
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    ASSERT_TRUE("concurrent", !anyFailure,
        @"concurrent transcription failed");
}
```

---

## 9. Fast Adversarial Tests -- Mean AND Quick

The best adversarial tests combine the attacker mindset with sub-second execution. These need no model loading, no GPU, no file I/O:

### 9.1 Boundary and Null Tests (< 1ms each)

Test timestamp formatting at float precision limits. Test token ID at INT_MAX. Test empty string handling in tokenizer. Test segment with startTime > endTime. Test segment with duration = 0. Test options with beam_size = 0, beam_size = -1, beam_size = INT_MAX.

### 9.2 Invariant Tests (< 10ms each)

Generate random mel data. Verify: all values finite (no NaN, no Inf). Verify: dimensions match expected shape. Verify: padding produces zeros. Generate known-frequency sine wave. Verify: mel energy concentrated at expected bin.

### 9.3 Error Path Tests (< 100ms each)

Exercise every NSError path: nil model path, empty model path, model path to a directory, model path to a non-model file, model path with non-ASCII characters, model path exceeding PATH_MAX.

### 9.4 Contract Violation Tests (< 1ms each)

Deliberately violate every documented precondition: nFrames=0 to encode, nFrames > actual data size, negative values where unsigned expected, nil where nonnull expected, empty collections where non-empty expected.

### 9.5 The "Evil Input" Battery (< 100ms total)

Create a standard battery of evil inputs that runs against every public API method:

```
nil, [NSData data], [NSData dataWithBytes:"\0" length:1]
Single-byte data, data with wrong alignment
Data with NaN floats, data with Inf floats
NSURL with file:// scheme to /dev/null
NSURL with http:// scheme (should be rejected)
NSString with emoji, NSString with control characters
NSNumber with NaN, NSNumber with negative values
NSDictionary with extra keys, missing keys
NSArray with 0, 1, 1M elements
```

---

## 10. Test Organization

### 10.1 Test Taxonomy

```
tests/
  test_m0_link.mm              -- Tier 1: SMOKE     (< 1s, no deps)
  test_m0_compute_types.mm     -- Tier 1: SMOKE
  test_m1_audio.mm             -- Tier 1: UNIT      (< 5s, file I/O)
  test_m2_mel.mm               -- Tier 1: UNIT      (< 5s, CPU only)
  test_m3_tokenizer.mm         -- Tier 1: UNIT      (< 5s, no model)
  test_edge_cases.mm           -- Tier 2: ADVERSARIAL (model, < 30s)
  test_m4_*_*.mm               -- Tier 2: INTEGRATION (model, < 30s)
  test_m6_m7_edge_cases.mm     -- Tier 2: ADVERSARIAL (model + VAD)
  test_m11_validation.mm       -- Tier 2: INTEGRATION
  test_e2e.mm                  -- Tier 3: END-TO-END (minutes)
  test_benchmark.mm            -- Tier 3: PERFORMANCE
  test_coverage.mm             -- Tier 3: COMPREHENSIVE
```

### 10.2 Execution Strategy

| Trigger | Tests Run | Time Budget |
|---|---|---|
| File save (IDE) | Tier 1 only | < 10 seconds |
| Git commit | Tier 1 + Tier 2 | < 2 minutes |
| Pull request | All tiers | < 10 minutes |
| Nightly CI | All + sanitizers + benchmarks | < 1 hour |

### 10.3 Naming Convention

```
// Good names:
test_encode_zero_frames_returns_nil_error
test_transcribe_empty_audio_returns_empty_array
test_vad_nil_audio_returns_empty_no_crash
test_concurrent_transcription_does_not_corrupt

// Bad names:
test1, test_encode, test_basic, test_edge_case
```

---

## 11. References and Sources

### Books and Foundational Works
- Kent Beck, *Test-Driven Development: By Example* (2002)
- Michael Feathers, *Working Effectively with Legacy Code* (2004)
- James Bach, "Exploratory Testing Explained" (2003)
- Bertrand Meyer, "Design by Contract" (Eiffel, 1986)
- Claessen and Hughes, "QuickCheck" (2000)

### Industry Blogs and Articles
- Google, *Software Engineering at Google*, Ch. 12: Unit Testing
- Google, *Software Engineering at Google*, Ch. 14: Larger Tests
- Google Testing Blog, "Test Sizes" (2010)
- Martin Fowler, "The Practical Test Pyramid"
- Martin Fowler, "Mocks Aren't Stubs"
- Kostis Kapelonis, "Software Testing Anti-patterns" (blog.codepipes.com)
- Yegor Bugayenko, "Unit Testing Anti-Patterns, Full List"
- James Grenning, "TDD Guided by ZOMBIES"
- Increment Magazine, "In Praise of Property-Based Testing"

### Tools and Platforms
- Antithesis -- deterministic simulation testing (antithesis.com)
- Mull -- C/C++ mutation testing
- PICT -- Microsoft pairwise testing tool
- ACTS -- NIST combinatorial testing tool

### Apple/Xcode Specific
- Apple Developer Documentation, "Diagnosing Memory, Thread, and Crash Issues Early"
- Clang ASan/TSan/UBSan documentation

---

## Proposed CLAUDE.md Testing Instructions

```markdown
## Testing Rules

### Adversarial Mindset

When writing tests, think like an attacker, not a developer. The goal
of a test is to BREAK the code, not to confirm it works.

For every function under test, ask:
1. What happens with nil/null/empty input?
2. What happens at zero? At one? At INT_MAX/SIZE_MAX?
3. What happens with malformed/truncated/oversized data?
4. What happens if called twice? Called concurrently? Called after release?
5. What error paths exist and are they all exercised?

Never write only happy-path tests. Every test file must include at
least as many adversarial/negative tests as positive tests.

### Edge Case Checklist (ZOMBIES)

Before considering a test suite complete, verify coverage of:

**Z - Zero:**
- Empty collections, zero-length data, zero count, zero duration
- nil/null for every pointer parameter
- Empty string ""

**O - One:**
- Single element/byte/sample/character
- Single iteration of any loop

**M - Many:**
- Large inputs (1M+ elements where feasible without slowing tests)
- Enough iterations to expose accumulation bugs (autoreleasepool, memory)

**B - Boundary:**
- Off-by-one: N-1, N, N+1 for every boundary N
- Integer limits: INT_MIN, INT_MAX, UINT_MAX, SIZE_MAX
- Float specials: NaN, +Inf, -Inf, -0.0, FLT_EPSILON, denormalized
- Buffer boundaries: exactly fits, one byte short, one byte over
- Type boundaries: signed/unsigned crossover, 32/64 bit limits

**I - Interface:**
- Every documented precondition violated
- Every documented error code triggered
- Every optional parameter as nil
- Every enum value including invalid cast values

**E - Exception/Error:**
- Every NSError** path exercised
- Error codes verified (not just error != nil)
- Error recovery: can the object still be used after an error?

**S - Simple scenarios first:**
- Build complexity incrementally
- If the simple case fails, do not add complexity

### Speed Requirements

**Unit tests MUST complete in < 1 second each.** No exceptions.

To achieve this:
- No model loading in unit tests (pass pre-loaded model or test without)
- No file I/O in pure logic tests (use in-memory data)
- No sleep, polling, or arbitrary waits
- No GPU computation in pure logic tests
- Minimal object construction -- only what the test needs

**Integration tests SHOULD complete in < 30 seconds each.**
- Share model loading across tests (load once in main)
- Use shortest audio that exercises the code path
- Prefer synthetic data over real audio files

**Slow tests (> 30s) require explicit justification:**
- End-to-end accuracy validation
- Performance benchmarks
- Memory leak detection over many iterations
- Concurrency stress tests

### Test Organization

Each test file tests ONE area of functionality. No monolithic test files.

Name tests to describe behavior and expected outcome:
```
test_{what}_{condition}_{expected_result}
Example: test_encode_zero_frames_returns_nil_error
```

Separate tests by speed tier:
- Tier 1 (< 5s total): No model, no GPU. Run on every build.
- Tier 2 (< 30s each): Needs model. Run on every commit.
- Tier 3 (minutes): Full pipeline. Run nightly or on PR.

### Test Structure

Use Arrange-Act-Assert with minimal Arrange:
```objc
static void test_example(SomeObject *obj) {
    // ARRANGE: only what this test needs, nothing more
    NSData *input = [NSData dataWithBytes:data length:len];

    // ACT: one action
    NSError *error = nil;
    NSData *result = [obj process:input error:&error];

    // ASSERT: focused, specific assertions
    ASSERT_TRUE(name, result != nil, fmtErr(@"failed", error));
    ASSERT_EQ(name, [result length], expectedLength);
}
```

Each test function tests ONE behavior. Do not combine multiple
behaviors in one test.

### Anti-Patterns to Avoid

**Tautological test:** Never compute expected values using the same
code being tested.

**Line hitter:** Every test MUST have at least one meaningful assertion.
A test that calls code without checking the result is not a test.

**Over-mocking:** If more than 2 mocks/stubs are needed, you are
probably testing the wrong thing. Prefer fakes with real behavior.

**Inspector:** Do not access private ivars or use runtime introspection
in tests. Test through public API only.

**Flaky test patterns:**
- Floating point comparison with == (use epsilon)
- Depending on hash map iteration order
- Depending on timing (use deterministic waits)
- Depending on filesystem state from other tests
- Using unseeded random values (always seed and log)

**Happy path only:** If a test file has only positive tests, it is
incomplete. Add adversarial tests before declaring done.

### Floating Point Testing Rules

Never compare floats with ==. Always use epsilon:
```objc
BOOL closeEnough = fabs(actual - expected) < 1e-5f;
ASSERT_TRUE(name, closeEnough, @"float mismatch");
```

Always test with: NaN, +Inf, -Inf, -0.0, very small
(denormalized), very large values.

### MRC Testing Rules

Every test that allocates objects must release them on ALL paths
including early returns.

Wrap test loops in @autoreleasepool:
```objc
for (int i = 0; i < N; i++) {
    @autoreleasepool {
        // test body
    }
}
```

For leak detection tests: measure RSS before and after, assert
delta < threshold.

### Concurrency Testing Rules

Never test concurrency with sleep + check. Use:
- dispatch_semaphore_wait
- dispatch_group_wait
- Completion handlers

When testing thread safety, run the concurrent operation at least
100 times to increase probability of exposing races.

Run tests under Thread Sanitizer (-fsanitize=thread) in CI.

### Sanitizer Requirements

Tests MUST pass under all three sanitizers (separate configurations):
- Address Sanitizer: memory corruption, use-after-free, buffer overflow
- Thread Sanitizer: data races, lock inversions
- Undefined Behavior Sanitizer: signed overflow, null deref, misalignment

Do not suppress sanitizer findings without documenting why.
```
