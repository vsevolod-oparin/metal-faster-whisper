---
name: adversarial-test
description: >
  Run adversarial testing on a target file, class, component, or the entire project — finds edge
  cases, boundary violations, and crash-inducing inputs. Use this skill PROACTIVELY whenever the
  user asks to "write tests", "add tests", "test this", "test the whole project", "test everything",
  "audit test coverage", "check this component", or mentions testing, edge cases, boundaries, or
  robustness for any Obj-C, Obj-C++, C++, or Metal code. Also trigger when the user says "adversarial
  test", "/adversarial-test", "attack this code", or wants to audit test coverage for gaps. Don't
  wait to be asked explicitly — if new code was written or existing code was modified, offer to run
  adversarial tests.
version: 1.1.0
---

# Adversarial Test

Run adversarial testing against the specified target. Think like an attacker: find inputs that crash, corrupt, leak, or return garbage.

## Mode Selection

Determine scope from `$ARGUMENTS`:

- **No argument / "project" / "all"** → **Project-wide mode**: discover and test all public APIs across the codebase
- **File path, class name, or component name** → **Focused mode**: test only that target

---

## Project-Wide Mode

When testing the whole project:

### 1. Discovery

Glob for all public headers and implementation files:
- `**/*.h` — public API declarations
- `**/*.mm`, `**/*.m`, `**/*.cpp` — implementations

For each header, extract:
- Every `@interface` / `class` with public methods
- Every public C function
- Every `typedef`, `enum`, `struct` that is part of the API surface

Group components by domain (e.g., audio, transcription, feature extraction, Metal, tokenizer). This becomes your attack plan.

### 2. Prioritize by Risk

Rank components highest-to-lowest attack priority:
1. Components that handle external/user input (audio data, file paths, config)
2. Components with C++ exceptions or Metal GPU work
3. Components with MRC (manual memory management)
4. Components involved in concurrency
5. Pure data-transform components

### 3. Test per Component

For each component, apply Focused Mode (see below). Write tests to a new file named `tests/AdversarialTest{Component}.mm`.

### 4. Project-Wide Report

Write `reports/adversarial-test-project.md` with:
- **Coverage matrix**: component × attack pattern (✓ tested / ✗ gap / N/A)
- **Bugs found** across all components (ranked by severity)
- **Highest-risk gaps** not yet tested
- **Build/run summary**: which test files compiled, which passed

---

## Focused Mode

### 1. Reconnaissance

Read the target code. For every public method, identify:
- All parameters and their types
- Implicit assumptions (non-nil, positive, aligned, initialized)
- Error paths (NSError**, return nil, exceptions)
- State requirements (must init first, not thread-safe)

### 2. Plan attacks using ZOMBIES

- **Z**ero: nil, empty, zero-length, zero-count
- **O**ne: single byte/sample/frame/character
- **M**any: large inputs, concurrent access, iteration
- **B**oundary: off-by-one, INT_MAX, NaN, Inf, -0.0f, denormalized floats, unsigned wraparound
- **I**nterface: violate every precondition, invalid enum casts, optional params as nil
- **E**xception: every error path, double-call, use-after-error recovery
- **S**imple first: start minimal, add complexity

### 3. Write tests

Each test:
- Named `test_{what}_{adversarial_condition}_{expected_outcome}`
- Arrange-Act-Assert, ONE behavior per test
- Must have meaningful assertions (no line hitters, no tautologies)
- Must be fast (< 1ms for boundary, < 100ms for state, < 5s for integration)
- Must handle MRC correctly (release on all paths, @autoreleasepool in loops)

### 4. Run tests

Build and execute. Every adversarial input must either succeed with a valid result OR fail with a proper error. **Crashing is never acceptable.**

### 5. Report

Write findings to `reports/adversarial-test-{component}.md`:
- Attack surface summary
- Tests written (table: name, pattern, speed, finding)
- Bugs found (severity, description, file:line, reproduction)
- Coverage gaps remaining

---

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
- In project-wide mode, process components in priority order; stop and report if a component causes build failure rather than silently skipping it
- Run under ASan/TSan flags if available
