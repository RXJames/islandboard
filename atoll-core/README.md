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
  Cargo.toml            # staticlib (+rlib for tests), dependency: serde_json
  Cargo.lock            # pinned dependency graph (cargo build --locked)
  rust-toolchain.toml   # pinned Rust channel (stable) — used by rustup
  include/atoll_core.h  # C ABI, consumed via DynamicIsland-Bridging-Header.h
  src/lib.rs            # FFI + streaming parser (mirrors the Swift semantics branch-for-branch)
  src/tests.rs          # unit suite incl. the Swift contract tests' scenarios
  build.sh              # cargo build --release --locked → target/<triple>/release/libatoll_core.a + dist/
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

## Toolchain

The Rust channel is pinned by `rust-toolchain.toml` (stable), and dependencies are
pinned by `Cargo.lock`; every build uses `--locked` so a clean checkout always
resolves the same graph. Install rustup once:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
```

## Build & test

Run from `atoll-core/` so rustup picks up the toolchain file:

```sh
cargo test --locked                              # unit suite
./build.sh                                       # release lib for the host arch
./build.sh --if-needed                           # skip when sources are unchanged
cargo build --locked --release --target aarch64-apple-darwin
```

`build.sh` writes `target/<triple>/release/libatoll_core.a` (the path Xcode links
against) and copies it to `dist/`. `--if-needed` compares source timestamps against
the library, so the Xcode build phase is a no-op (~10 ms) when nothing changed.

## Xcode integration

The `DynamicIsland` target has a **Build atoll-core (Rust)** script phase (first in
the phase list) that runs `atoll-core/build.sh --if-needed`. The target links the
library through its build settings:

```
HEADER_SEARCH_PATHS = $(SRCROOT)/atoll-core/include
LIBRARY_SEARCH_PATHS = $(SRCROOT)/atoll-core/target/aarch64-apple-darwin/release
OTHER_LDFLAGS = -latoll_core
```

Consequences:

- A **clean checkout builds end-to-end** in Xcode as long as `cargo` is on `PATH`;
  no manual Rust step or checked-in `.a` is required.
- The phase inherits Xcode's minimal `PATH`, so `build.sh` adds `~/.cargo/bin`,
  `/opt/homebrew/bin` and `/usr/local/bin` itself.
- CI installs Rust, caches `~/.cargo` + `atoll-core/target`, runs `cargo test --locked`
  and a release build before `xcodebuild`.
- Xcode's user-script sandboxing must stay **off** for this target (it is:
  `ENABLE_USER_SCRIPT_SANDBOXING = NO`), otherwise the phase cannot run `cargo` or
  write into `target/`.

## Targets

`arm64` (`aarch64-apple-darwin`) is supported today — the library is built for the
architecture Xcode is building (`ARCHS`). `x86_64`/universal builds are not wired
yet: `build.sh` fails with an explicit message rather than linking a slice that does
not exist. Adding them later means a second cargo build for
`x86_64-apple-darwin`, `lipo -create`, and pointing `LIBRARY_SEARCH_PATHS` at the
merged library.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `error: cargo not found` from Xcode | Install rustup; the phase message includes the command. |
| `error: the lock file … needs to be updated` | Run `cargo update -p <crate>` in `atoll-core/` and commit `Cargo.lock`. |
| `error: atoll-core currently ships arm64 only` | You are building for x86_64/universal; see **Targets**. |
| Linker cannot find `-latoll_core` | The phase did not run (check Build Phases order) or the build target differs from `aarch64-apple-darwin`. |

## Parity

`JSONLUsageParser` and this core were compared on real logs plus a stress corpus
(chunk-spanning records, oversized/underminated records, invalid UTF-8, float token
counts, cross-file dedup, ISO8601 variants, stale mtime, window edges): outputs
identical. The Swift contract suite lives in `DynamicIslandTests/UsageCoreTests.swift`.
