---
description: Run adversarial testing on a target file or component — finds edge cases, boundary violations, and crash-inducing inputs
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, Agent
---

# Adversarial Test

Run adversarial testing against the specified target. Think like an attacker: find inputs that crash, corrupt, leak, or return garbage.

## Instructions

1. **Identify the target.** The user's argument (`$ARGUMENTS`) specifies the file, class, or component to attack. If empty, ask.

2. **Reconnaissance.** Read the target code. For every public method, identify:
   - All parameters and their types
   - Implicit assumptions (non-nil, positive, aligned, initialized)
   - Error paths (NSError**, return nil, exceptions)
   - State requirements (must init first, not thread-safe)

3. **Plan attacks using ZOMBIES:**
   - **Z**ero: nil, empty, zero-length, zero-count
   - **O**ne: single byte/sample/frame/character
   - **M**any: large inputs, concurrent access, iteration
   - **B**oundary: off-by-one, INT_MAX, NaN, Inf, -0.0f, denormalized floats, unsigned wraparound
   - **I**nterface: violate every precondition, invalid enum casts, optional params as nil
   - **E**xception: every error path, double-call, use-after-error recovery
   - **S**imple first: start minimal, add complexity

4. **Write tests.** Each test:
   - Named `test_{what}_{adversarial_condition}_{expected_outcome}`
   - Arrange-Act-Assert, ONE behavior per test
   - Must have meaningful assertions (no line hitters, no tautologies)
   - Must be fast (< 1ms for boundary, < 100ms for state, < 5s for integration)
   - Must handle MRC correctly (release on all paths, @autoreleasepool in loops)

5. **Run tests.** Build and execute. Every adversarial input must either succeed with a valid result OR fail with a proper error. **Crashing is never acceptable.**

6. **Report.** Write findings to `reports/adversarial-test-{component}.md`:
   - Attack surface summary
   - Tests written (table: name, pattern, speed, finding)
   - Bugs found (severity, description, file:line, reproduction)
   - Coverage gaps remaining

## Attack Patterns

- **Contract violation:** nil where non-nil expected, wrong types, invalid enums
- **State machine abuse:** wrong call order, re-entrancy from callbacks, use-after-release
- **Resource exhaustion:** many allocations, unbounded memory growth, FD leaks
- **Concurrency:** same instance from multiple threads, release during use
- **Data corruption:** valid size but NaN values, truncated data, wrong alignment
- **Floating point traps:** NaN propagation, denormalized numbers, precision loss
- **Order dependence:** A then B vs B then A, state leakage between calls
- **Re-entrancy:** call API from within its own callback

## Project-Specific Vectors

- **MRC:** missing release on error paths, autorelease accumulation, retain/release mismatch
- **Metal/GPU:** unavailable device, misaligned buffers, CPU/GPU simultaneous access
- **C++/ObjC++ interop:** exceptions crossing boundary, dangling UTF8String pointers
- **Audio:** zero samples, all-silence, all-clipping, wrong sample rate, NaN in samples

## Rules

- Never compute expected values using the same code being tested
- Float comparisons must use epsilon (fabs(a-b) < 1e-5f), never ==
- Concurrency tests: use dispatch_group/semaphore, never sleep+check, 100+ iterations
- More negative tests than positive tests per file
- Run under ASan/TSan flags if available
