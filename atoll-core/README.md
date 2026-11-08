# atoll-core

Rust data layer for Atoll's LLM usage tracking. It replaces the former Swift
`JSONLUsageParser` hot path: the streaming scan of Claude Code (`~/.claude/projects`)
and Codex (`~/.codex/sessions`) JSONL session logs — per-line parsing, cross-file
dedup, and week/today/session bucketing — runs here. Pricing stays in Swift
(`ModelPricingManager` owns the remote rate table; cost is linear in tokens, so it is
applied to per-model aggregates without changing results).

## Why Rust

The Swift parser leaked autoreleased Foundation objects off the main thread (see
upstream issue #870: peak footprint 2.59 GB on a week of heavy Claude Code logs).
Ownership semantics here make that class of peak impossible: buffers are bounded by
`CHUNK_SIZE + MAX_RECORD_SIZE` (≈1 MB) and every allocation is freed deterministically
when the scan returns. Measured upstream: 2.59 GB → 19 MB peak, 16.6 s → 12.8 s wall.

## Layout

```
atoll-core/
  Cargo.toml          # staticlib (+rlib for tests), dependency: serde_json
  include/atoll_core.h  # C ABI, consumed via DynamicIsland-Bridging-Header.h
  src/lib.rs          # FFI + streaming parser (mirrors the Swift semantics branch-for-branch)
  src/tests.rs        # unit suite incl. the Swift contract tests' scenarios
  build.sh            # cargo build --release → dist/libatoll_core.a
```

## FFI contract

`atoll_aggregate_usage(buf, buf_len, week_start, session_start, today_start, today_end)`

- `buf`: UTF-8 file paths separated by NUL bytes.
- window bounds: unix seconds; `[today_start, today_end)` is computed by the Swift
  caller with `Calendar.current` so local-day/DST semantics stay host-side.
- returns a malloc'd JSON string (`atoll_free_string` frees it):
  `{"week":[M...],"today":[M...],"session":[M...]}`, each M =
  `{"model":str,"input":i64,"output":i64,"cacheRead":i64,"cacheWrite":i64}`.
- NULL on invalid input or internal panic (catch_unwind at the boundary; Swift throws).

ABI version: `atoll_usage_core_abi()` → 1.

## Build & link

```sh
./build.sh                                   # → dist/libatoll_core.a (aarch64-apple-darwin)
cargo test                                   # unit suite
```

Xcode links it through build settings (the app target's bridging header includes
`include/atoll_core.h`):

```sh
xcodebuild ... \
  HEADER_SEARCH_PATHS='$(inherited) .../atoll-core/include' \
  OTHER_LDFLAGS='$(inherited) -L.../atoll-core/dist -latoll_core'
```

## Parity

`JSONLUsageParser` and this core were compared on real logs plus a stress corpus
(chunk-spanning records, oversized/underminated records, invalid UTF-8, float token
counts, cross-file dedup, ISO8601 variants, stale mtime, window edges): outputs
identical. The Swift contract suite lives in `DynamicIslandTests/UsageCoreTests.swift`.
