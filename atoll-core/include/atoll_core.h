/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * C ABI for atoll-core (Rust). Implemented in atoll-core/src/lib.rs.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#ifndef ATOLL_CORE_H
#define ATOLL_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Streaming JSONL usage aggregation for Claude Code / Codex session logs.
 *
 * `buf` holds `buf_len` bytes: UTF-8 file paths separated by NUL bytes (an
 * optional trailing NUL yields no empty path). Window bounds are unix seconds:
 * `week_start`, `session_start`, `[today_start, today_end)` (local-day
 * boundaries computed by the caller so calendar semantics stay with the host).
 *
 * Returns a newly allocated NUL-terminated JSON string on success:
 *   {"week":[M...],"today":[M...],"session":[M...]}
 * where each M is
 *   {"model":str,"input":i64,"output":i64,"cacheRead":i64,"cacheWrite":i64}
 * The caller must free the result with atoll_free_string. Returns NULL on
 * invalid arguments or an internal panic.
 */
char *atoll_aggregate_usage(const char *buf, size_t buf_len,
                            double week_start, double session_start,
                            double today_start, double today_end);

/* Free a string returned by atoll_aggregate_usage. NULL is a no-op. */
void atoll_free_string(char *s);

/* ABI version of the JSON payload produced by atoll_aggregate_usage. */
unsigned int atoll_usage_core_abi(void);

#ifdef __cplusplus
}
#endif

#endif /* ATOLL_CORE_H */
