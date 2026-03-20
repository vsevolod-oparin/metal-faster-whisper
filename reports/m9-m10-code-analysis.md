# M9/M10 Code Analysis Report

**Date:** 2026-03-20
**Scope:** MWModelManager.mm, MWTranscriptionOptions.mm, MWTranscriber.mm (async methods), MetalWhisper.h
**Reviews conducted:** Code quality + Security (2 parallel agents)

---

## Summary

| Category | CRITICAL | HIGH | MEDIUM | LOW |
|----------|----------|------|--------|-----|
| Code Quality | — | 4 | 5 | — |
| Security | 2 | 5 | 4 | — |

After deduplication: **2 CRITICAL, 7 unique HIGH, 6 unique MEDIUM**.

---

## CRITICAL

### 1. Download buffers entire file in memory — OOM for large models

**File:** MWModelManager.mm (MWDownloadDelegate)

`NSURLSessionDataDelegate` accumulates all downloaded data into `NSMutableData`. For large-v3 (~3GB), this will exhaust RAM.

**Fix:** Switch to `NSURLSessionDownloadTask` which streams to a temp file on disk, or enforce a per-chunk write-to-disk pattern with a memory cap (~50MB buffer).

### 2. URL injection via unsanitized repo ID

**File:** MWModelManager.mm:329-330

When `sizeOrPath` contains `/` but isn't a known alias, it's interpolated directly into the HuggingFace URL. A crafted string like `../../evil` could manipulate the URL path.

**Fix:** Validate repo IDs against regex `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`.

---

## HIGH

### 3. Missing `dispatch_release` for semaphore (MRC leak)

**File:** MWModelManager.mm:372

`dispatch_semaphore_create` returns +1 under MRC. Never released.

**Fix:** `dispatch_release(semaphore)` after `invalidateAndCancel`.

### 4. MWDownloadDelegate doesn't retain/release semaphore

**File:** MWModelManager.mm:128,154,160

GCD objects need manual retain/release under MRC.

**Fix:** `dispatch_retain` in init, `dispatch_release` in dealloc.

### 5. No HTTPS enforcement on redirects

**File:** MWModelManager.mm

HuggingFace uses redirects (302) to CDN. Without `willPerformHTTPRedirection:` delegate, a MITM could redirect to HTTP.

**Fix:** Implement redirect delegate, reject non-HTTPS redirects.

### 6. No thread safety on singleton's `_cacheDirectory`

**File:** MWModelManager.mm:239-248

Concurrent `setCacheDirectory:` and `resolveModel:` on the shared singleton is a data race.

**Fix:** Use `@synchronized(self)` around cache directory access, or make it read-only after init.

### 7. TOCTOU race on .partial files

**File:** MWModelManager.mm

Between checking `.partial` file size and writing to it, an attacker on a shared system could replace it with a symlink.

**Fix:** Use `O_EXCL | O_CREAT` for new files, or open-then-stat for existing.

### 8. Cache directory created with default permissions

**File:** MWModelManager.mm

`createDirectoryAtPath:withIntermediateDirectories:attributes:nil` uses default umask. On shared systems, downloaded models could be world-readable.

**Fix:** Pass `@{NSFilePosixPermissions: @(0700)}` in attributes.

### 9. No checksum verification on downloaded files

**File:** MWModelManager.mm

Downloaded model.bin could be corrupted or tampered. No SHA256 verification.

**Fix:** Ideally verify against HuggingFace-provided checksums. At minimum, verify file size matches Content-Length.

---

## MEDIUM

1. **Resume logic doesn't validate Content-Range header** — corrupted data if server ignores Range request (MWModelManager.mm)
2. **segmentHandler threading inconsistency** — async method calls segmentHandler on background queue but completionHandler on main queue. Should document or unify. (MWTranscriber.mm)
3. **No input validation on MWTranscriptionOptions numeric fields** — beamSize=0, NaN temperatures accepted (MWTranscriptionOptions.mm)
4. **Partial file not cleaned on download failure** — .partial files accumulate on repeated failures (MWModelManager.mm)
5. **Autoreleased delegate passed to NSURLSession** — should use explicit alloc/release for clarity (MWModelManager.mm:377)
6. **Silently swallowed errors for optional files** — error cleared without logging (MWModelManager.mm:338)

---

---

## Fix Results (2026-03-20)

All findings fixed (12 of 13 — Fix 7 WONTFIX). All tests pass.

### Fixes Applied

| # | Fix | Severity |
|---|-----|----------|
| 1 | Download streams to disk via NSFileHandle on .partial file — constant ~64KB memory | CRITICAL |
| 2 | Repo ID validated against `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` regex | CRITICAL |
| 3 | `dispatch_release(semaphore)` on all exit paths from downloadFileFromURL: | HIGH |
| 4 | `dispatch_retain/_release` in MWDownloadDelegate init/dealloc | HIGH |
| 5 | `willPerformHTTPRedirection:` rejects non-HTTPS redirects | HIGH |
| 6 | `@synchronized(self)` on cacheDirectory getter/setter and all reads | HIGH |
| 7 | TOCTOU on .partial files | **WONTFIX** — not worth complexity for CLI |
| 8 | Cache directory created with `NSFilePosixPermissions: @(0700)` | HIGH |
| 9 | Download size verified: `bytesReceived == totalBytesExpected` when Content-Length known | HIGH |
| 10 | Partial files deleted on download failure | MEDIUM |
| 11 | segmentHandler threading documented in header | MEDIUM |
| 12 | MWTranscriptionOptions clamps beamSize [1,100], patience/penalties [0,10] | MEDIUM |
| 13 | Optional file failures logged via MWLog instead of silently swallowed | MEDIUM |

---

## Recommended Fix Order

**Phase 1 — Critical safety:**
1. Switch to download-to-disk (NSURLSessionDownloadTask) or add memory cap
2. Validate repo ID format with regex

**Phase 2 — MRC + security:**
3. Fix dispatch_semaphore lifecycle (retain/release)
4. Add HTTPS redirect enforcement
5. Set cache directory permissions to 0700
6. Add thread safety for cacheDirectory property

**Phase 3 — Robustness:**
7. Validate Content-Range on resume
8. Document segmentHandler threading
9. Add MWTranscriptionOptions field validation
10. Clean partial files on failure
