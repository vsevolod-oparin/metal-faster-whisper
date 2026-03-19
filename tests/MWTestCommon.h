#pragma once

#import <Foundation/Foundation.h>

// ── Shared test infrastructure ──────────────────────────────────────────────
// Include this header in test files instead of duplicating test helpers.

static int gPassCount = 0;
static int gFailCount = 0;

static void reportResult(const char *testName, BOOL passed, NSString *detail) {
    if (passed) {
        fprintf(stdout, "  PASS: %s\n", testName);
        gPassCount++;
    } else {
        fprintf(stdout, "  FAIL: %s -- %s\n", testName, detail ? [detail UTF8String] : "(no detail)");
        gFailCount++;
    }
}

#define ASSERT_TRUE(name, cond, msg) do { \
    if (!(cond)) { \
        reportResult((name), NO, (msg)); \
        return; \
    } \
} while (0)

#define ASSERT_EQ(name, actual, expected) do { \
    long _a = (long)(actual); long _e = (long)(expected); \
    if (_a != _e) { \
        reportResult(name, NO, [NSString stringWithFormat:@"expected %ld, got %ld", _e, _a]); \
        return; \
    } \
} while (0)

static NSString *fmtErr(NSString *prefix, NSError *error) {
    return [NSString stringWithFormat:@"%@: %@", prefix, [error localizedDescription]];
}

static NSString *loadFailMsg(NSError *error) {
    return [NSString stringWithFormat:@"Load failed: %@", [error localizedDescription]];
}

static NSString *fmtStr(NSString *prefix, NSString *value) {
    return [NSString stringWithFormat:@"%@: %@", prefix, value];
}

static NSString *fmtFloat(NSString *prefix, float value) {
    return [NSString stringWithFormat:@"%@: %f", prefix, value];
}
