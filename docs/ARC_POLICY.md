# ARC Policy — Manual Retain/Release

All `.mm` files in MetalWhisper are compiled with `-fno-objc-arc`. This matches CTranslate2's Metal backend, which also disables ARC, and avoids ARC/non-ARC mixing issues at link time.

## Rules

### Object lifecycle

- Every `alloc`/`init`, `copy`, or `mutableCopy` must have a matching `release` or `autorelease`.
- Use `[obj release]` when you own the object and are done with it in the current scope.
- Use `[obj autorelease]` when returning an object the caller doesn't own (follows Cocoa naming conventions).

### `@autoreleasepool` placement

- **Public API entry points** (methods called from Swift or external code): wrap the body in `@autoreleasepool` to drain temporary objects.
- **Exception: methods that return autoreleased objects.** Do NOT wrap the body in `@autoreleasepool` — the pool would drain the return value before the caller can use it. Instead, let the caller's pool handle it.
- **Exception: initializers.** Do not wrap init bodies in `@autoreleasepool` — `[self release]` on failure within a pool can cause premature deallocation.
- **Loops creating temporary ObjC objects:** wrap the loop body in `@autoreleasepool` to avoid accumulation.

### `dealloc`

- Always call `[super dealloc]` as the last line.
- Reset C++ members (`std::unique_ptr::reset()`) before `[super dealloc]`.
- Release any retained ObjC ivars before `[super dealloc]`.

### Gotchas discovered

1. **Inner `@autoreleasepool` + autoreleased return value = crash.** The pool drains before the caller gets the object. Symptom: SIGSEGV (exit 139) on the caller side. Fix: don't pool methods returning autoreleased objects.

2. **`[self release]` inside `@autoreleasepool` in init.** If `[super init]` returns an autoreleased proxy, the pool could drain it while you're still using `self`. Fix: don't wrap init in `@autoreleasepool`.
