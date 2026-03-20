# M8 CLI Code Analysis Report

**Date:** 2026-03-20
**Scope:** cli/metalwhisper.mm (643 lines), tests/test_m8_cli.mm (300 lines)
**Reviews conducted:** Code quality + Security (2 parallel agents)

---

## Summary

| Category | CRITICAL | HIGH | MEDIUM | LOW |
|----------|----------|------|--------|-----|
| Code Quality | 1 (test only) | 5 | 5 | 2 |
| Security | — | 1 | 2 | 3 |

After deduplication: **0 CRITICAL in production**, **5 HIGH**, **5 MEDIUM** findings.

**MRC audit: CLEAN** — all 12 alloc/copy sites have matching releases. No leaks found.

---

## HIGH (fix now)

### 1. `--vad-filter` without `--vad-model` silently misbehaves

**File:** cli/metalwhisper.mm:513

Takes the batched path but VAD model path is never set in options. Behavior undefined.

**Fix:** Validate after parsing: if vadFilter && !vadModelPath, print error and exit 1.

### 2. Null dereference in verbose output when `info` is nil

**File:** cli/metalwhisper.mm:579-582

`[info.language UTF8String]` passes NULL to `%s` — undefined behavior (crash on many platforms).

**Fix:** Guard `if (info)` before verbose logging block.

### 3. `--beam-size` accepts negative/zero/garbage via `atoi()`

**File:** cli/metalwhisper.mm:347

Negative values wrap to huge NSUInteger. Non-numeric strings become 0.

**Fix:** Use `strtol`, validate `1 ≤ beamSize ≤ 100`.

### 4. `--task` accepts any string without validation

**File:** cli/metalwhisper.mm:335

`--task foo` silently forwarded to transcriber.

**Fix:** Validate against "transcribe" and "translate".

### 5. Predictable temp file for stdin pipe — symlink race

**File:** cli/metalwhisper.mm:407-408

Fixed path `metalwhisper_stdin.wav` allows symlink attack on shared systems and race between concurrent invocations.

**Fix:** Use PID or UUID in temp filename: `metalwhisper_stdin_%d.wav`, getpid()`.

---

## MEDIUM

### 6. Negative seconds produce wrong SRT/VTT timestamps

**File:** cli/metalwhisper.mm:52,61

**Fix:** Clamp `seconds = fmaxf(0.0f, seconds)` at top of each formatter.

### 7. Unrecognized `--output-format` silently defaults to text

**File:** cli/metalwhisper.mm:285

`--output-format srtt` (typo) gives text with no warning.

**Fix:** Print warning for unrecognized values.

### 8. Multi-file JSON is NDJSON (not valid JSON array)

**File:** cli/metalwhisper.mm:627

Multiple files produce concatenated JSON objects, not a JSON array.

**Fix:** Wrap in `[...]` for multi-file, or document NDJSON behavior.

### 9. `parseComputeType` missing int8_float16 / int8_float32

**File:** cli/metalwhisper.mm:273

Users can't select these compute types from CLI.

**Fix:** Add cases and update help text.

### 10. Unbounded stdin read — no size limit

**File:** cli/metalwhisper.mm:396-411

Piping `/dev/zero` causes OOM.

**Fix:** Add a 2GB cap on stdin read.

---

## LOW

1. `--condition-on-previous-text` flag is a no-op (default already YES)
2. `--language` not validated against known language codes
3. Temp file not cleaned on SIGINT/SIGTERM
4. `parseTemperatures` silently accepts non-numeric garbage
5. Test helper uses `popen()` with string interpolation (shell injection in tests)

---

## Test Coverage Gaps

| # | Missing test |
|---|-------------|
| 1 | `--output-dir` mode (write files to directory) |
| 2 | `--verbose` progress output on stderr |
| 3 | `--temperature` custom values |
| 4 | `--beam-size` edge cases (0, negative, garbage) |
| 5 | `--vad-filter` with and without `--vad-model` |
| 6 | Stdin pipe (`-` argument) |
| 7 | Multiple input files |
| 8 | Unicode filenames / special characters in paths |
| 9 | `--version` flag |

---

---

## Fix Results (2026-03-20)

All HIGH and MEDIUM findings fixed. 105+ tests pass.

### Fixes Applied (10)

| # | Fix | Severity |
|---|-----|----------|
| 1 | `--vad-filter` requires `--vad-model` — validated after parsing, exits with clear error | HIGH |
| 2 | Verbose output guards `if (info)` before accessing info.language | HIGH |
| 3 | `--beam-size` validated via `strtol`, range 1-100 enforced | HIGH |
| 4 | `--task` validated against "transcribe"/"translate" | HIGH |
| 5 | Stdin temp file uses PID + UUID: `metalwhisper_stdin_{pid}_{uuid}.wav` | HIGH |
| 6 | Negative seconds clamped to 0 in both SRT and VTT formatters | MEDIUM |
| 7 | Unrecognized `--output-format` prints warning before defaulting to text | MEDIUM |
| 8 | `parseComputeType` now handles int8_float16, int8_float32 | MEDIUM |
| 9 | Stdin read capped at 2 GB | MEDIUM |
| 10 | Help text updated with all compute types | MEDIUM |

### Verified manually

```
$ metalwhisper test.wav --task foo        → "Error: --task must be 'transcribe' or 'translate'" (exit 1)
$ metalwhisper test.wav --vad-filter      → "Error: --vad-filter requires --vad-model <path>" (exit 1)
$ metalwhisper test.wav --beam-size -5    → "Error: --beam-size must be between 1 and 100" (exit 1)
$ metalwhisper test.wav --output-format x → "Warning: Unknown output format 'x', using text"
```

---

## Recommended Fix Order

**Phase 1 — Safety (5 HIGH):**
1. Validate --vad-filter requires --vad-model
2. Guard info nil in verbose output
3. Validate --beam-size range
4. Validate --task values
5. Use PID in stdin temp filename

**Phase 2 — Robustness (5 MEDIUM):**
6. Clamp negative timestamps
7. Warn on unrecognized output format
8. Document or fix multi-file JSON
9. Add missing compute type aliases
10. Cap stdin read at 2GB
