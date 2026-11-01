// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Reads the current process's live tracing state; persistent JIT flags are not
/// accepted as proof of a connected debugger. A read failure returns false.
bool airrecord_process_is_traced(void);

/// Reads get-task-allow from this process's effective code-signing entitlements.
/// Missing, malformed, or unreadable entitlements return false.
bool airrecord_process_allows_debugging(void);

#ifdef __cplusplus
}
#endif
