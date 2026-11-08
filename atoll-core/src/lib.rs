//! atoll-core: Rust data layer for Atoll's LLM usage tracking.
//!
//! Replaces the Swift `JSONLUsageParser` hot path: streaming scan of Claude Code /
//! Codex JSONL session logs with per-line parsing, cross-file dedup and
//! week/today/session bucketing. Returns per-model aggregated token totals as JSON;
//! pricing stays in Swift (the rate table is fetched remotely by
//! `ModelPricingManager`, and cost is linear in tokens so it can be applied to
//! aggregates without changing results).
//!
//! Memory behavior is the point: no Foundation autorelease pools to forget, buffers
//! are bounded by `CHUNK_SIZE + MAX_RECORD_SIZE`, and every allocation is freed
//! deterministically when `aggregate_inner` returns.

use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, CStr, CString};
use std::fs::{self, File};
use std::io::Read;
use std::ptr;
use std::time::UNIX_EPOCH;

const CHUNK_SIZE: usize = 64 * 1024; // 64 KB, matches the former Swift chunking
const MAX_RECORD_SIZE: usize = 1024 * 1024; // 1 MB max per record

/// One parsed usage record (mirrors Swift `UsageRecord`).
struct Record {
    ts: f64, // unix seconds
    model: String,
    input: i64, // all prompt tokens incl. cache read/write
    output: i64,
    cache_read: i64,
    cache_write: i64,
    dedup_key: Option<String>,
}

#[derive(Default, Copy, Clone)]
struct ModelTotals {
    input: i64,
    output: i64,
    cache_read: i64,
    cache_write: i64,
}

/// Per-file parser state: Codex `token_count` records do not carry the model name;
/// it comes from the most recent `turn_context` record in the same file.
#[derive(Default)]
struct FileState {
    codex_model: Option<String>,
}

fn get_obj<'a>(map: &'a Map<String, Value>, key: &str) -> Option<&'a Map<String, Value>> {
    map.get(key).and_then(Value::as_object)
}

fn get_str<'a>(map: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    map.get(key).and_then(Value::as_str)
}

/// Mirrors Swift's `["k"] as? Int` on `NSNumber`: integer, or a float with an
/// exact integer value (lossless bridging). Absent/other types read as 0.
fn get_int(map: &Map<String, Value>, key: &str) -> i64 {
    match map.get(key).and_then(Value::as_f64) {
        Some(f) if f.is_finite() && f.fract() == 0.0 && f.abs() < 9.0e18 => f as i64,
        _ => 0,
    }
}

/// Parse an ISO8601 timestamp the way `ISO8601DateFormatter` with
/// `[.withInternetDateTime, .withFractionalSeconds]` falling back to
/// `[.withInternetDateTime]` does: `YYYY-MM-DDTHH:MM:SS(.frac)?(Z|±HH:MM)`.
/// Returns unix seconds.
fn parse_iso8601(s: &str) -> Option<f64> {
    let b = s.as_bytes();
    if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' {
        return None;
    }
    let num = |from: usize, to: usize| -> Option<i64> {
        b[from..to]
            .iter()
            .try_fold(0i64, |acc, &c| c.is_ascii_digit().then_some(acc * 10 + (c - b'0') as i64))
    };
    let (year, month, day) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, min, sec) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || h > 23 || min > 59 || sec > 59 {
        return None;
    }
    let mut i = 19;
    let mut frac = 0.0f64;
    if b.get(i) == Some(&b'.') {
        i += 1;
        let start = i;
        let mut scale = 0.1f64;
        while i < b.len() && b[i].is_ascii_digit() {
            frac += (b[i] - b'0') as f64 * scale;
            scale *= 0.1;
            i += 1;
        }
        if i == start {
            return None;
        }
    }
    // Timezone: 'Z' or '±HH:MM', consuming the rest of the string exactly.
    let tz_offset = match b.get(i) {
        Some(b'Z') => {
            if i + 1 != b.len() {
                return None;
            }
            0
        }
        Some(&sign @ (b'+' | b'-')) => {
            if i + 6 != b.len() || b[i + 3] != b':' {
                return None;
            }
            let th = num(i + 1, i + 3)?;
            let tm = num(i + 4, i + 6)?;
            if th > 23 || tm > 59 {
                return None;
            }
            let off = th * 3600 + tm * 60;
            if sign == b'-' {
                -off
            } else {
                off
            }
        }
        _ => return None,
    };
    Some(days_from_civil(year, month, day) as f64 * 86400.0 + (h * 3600 + min * 60 + sec) as f64 + frac - tz_offset as f64)
}

/// Days since unix epoch for a proleptic Gregorian date (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// Line-level parser. Mirrors Swift `JSONLUsageParser.parseLine(_:codexModel:)`
/// branch-for-branch, including record-kind precedence:
/// 1. Codex `turn_context` (updates state, yields nothing)
/// 2. Codex `event_msg`/`token_count`
/// 3. Generic Claude-style `message.usage` / top-level `usage`
fn parse_line(line: &str, st: &mut FileState) -> Option<Record> {
    let value: Value = serde_json::from_str(line).ok()?;
    let obj = value.as_object()?;

    if get_str(obj, "type") == Some("turn_context") {
        if let Some(model) = get_obj(obj, "payload").and_then(|p| p.get("model")).and_then(Value::as_str) {
            if !model.is_empty() {
                st.codex_model = Some(model.to_owned());
            }
        }
        return None;
    }

    if let Some(rec) = parse_codex_token_count(obj, st.codex_model.as_deref().unwrap_or("codex")) {
        return Some(rec);
    }

    let message = get_obj(obj, "message");
    let usage = message
        .and_then(|m| m.get("usage"))
        .and_then(Value::as_object)
        .or_else(|| obj.get("usage").and_then(Value::as_object))?;

    // Claude Code reports uncached input, cache writes and cache reads as three
    // separate, non-overlapping counters.
    let cache_write = get_int(usage, "cache_creation_input_tokens");
    let cache_read = get_int(usage, "cache_read_input_tokens");
    let input = get_int(usage, "input_tokens") + cache_write + cache_read;
    let output = get_int(usage, "output_tokens");
    if input + output <= 0 {
        return None;
    }
    let model = message
        .and_then(|m| m.get("model"))
        .and_then(Value::as_str)
        .or_else(|| get_str(obj, "model"))
        .unwrap_or("unknown");
    let ts_string = get_str(obj, "timestamp")
        .or_else(|| message.and_then(|m| m.get("timestamp")).and_then(Value::as_str))
        .unwrap_or("");
    let ts = parse_iso8601(ts_string)?;
    let message_id = message.and_then(|m| m.get("id")).and_then(Value::as_str);
    let request_id = get_str(obj, "requestId").or_else(|| get_str(obj, "request_id"));
    let dedup_key = if message_id.is_some() || request_id.is_some() {
        Some(format!("{}-{}", message_id.unwrap_or(""), request_id.unwrap_or("")))
    } else {
        None
    };
    Some(Record {
        ts,
        model: model.to_owned(),
        input,
        output,
        cache_read,
        cache_write,
        dedup_key,
    })
}

/// Codex (OpenAI usage semantics): `input_tokens` already includes the cached
/// portion reported in `cached_input_tokens`; cache writes are separate.
fn parse_codex_token_count(obj: &Map<String, Value>, model: &str) -> Option<Record> {
    if get_str(obj, "type") != Some("event_msg") {
        return None;
    }
    let payload = get_obj(obj, "payload")?;
    if get_str(payload, "type") != Some("token_count") {
        return None;
    }
    let info = get_obj(payload, "info")?;
    let usage = get_obj(info, "last_token_usage")?;
    let ts = parse_iso8601(get_str(obj, "timestamp")?)?;

    let input = get_int(usage, "input_tokens");
    let output = get_int(usage, "output_tokens");
    let cache_read = input.min(get_int(usage, "cached_input_tokens"));
    let cache_write = get_int(usage, "cache_write_input_tokens");
    if input < 0 || output < 0 || (input == 0 && output == 0) {
        return None;
    }
    Some(Record {
        ts,
        model: model.to_owned(),
        input: input + cache_write,
        output,
        cache_read,
        cache_write,
        dedup_key: None,
    })
}

struct Window {
    week_start: f64,
    session_start: f64,
    today_start: f64,
    today_end: f64,
}

/// Session logs are append-only, so a file whose last write predates the window
/// cannot contain a record inside it. Returns true when the date is unreadable,
/// so an unexpected filesystem keeps the file rather than silently dropping its
/// records.
fn mtime_allows(path: &str, cutoff: f64) -> bool {
    match fs::metadata(path).and_then(|m| m.modified()) {
        Ok(t) => match t.duration_since(UNIX_EPOCH) {
            Ok(d) => d.as_secs_f64() >= cutoff,
            Err(_) => false,
        },
        Err(_) => true,
    }
}

type TotalsMap = HashMap<String, ModelTotals>;

fn stream_file(path: &str, w: &Window, seen: &mut HashSet<String>, week: &mut TotalsMap, today: &mut TotalsMap, session: &mut TotalsMap) {
    let Ok(mut file) = File::open(path) else { return };
    let mut buffer: Vec<u8> = Vec::with_capacity(CHUNK_SIZE);
    let mut chunk = [0u8; CHUNK_SIZE];
    let mut discarding_oversized = false;
    let mut st = FileState::default();

    while let Ok(n) = file.read(&mut chunk) {
        if n == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..n]);

        // Process complete lines from buffer.
        while let Some(pos) = buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buffer.drain(..=pos).collect();
            let line = &line[..line.len() - 1]; // strip the '\n'
            if discarding_oversized {
                // We were discarding an oversized record; this newline ends it.
                discarding_oversized = false;
                continue;
            }
            if line.len() > MAX_RECORD_SIZE {
                continue; // skip oversized terminated records before decoding
            }
            process_record(line, &mut st, w, seen, week, today, session);
        }

        // Bound buffer growth: if the buffer exceeds MAX_RECORD_SIZE without a
        // newline, discard data up to the next newline when it arrives.
        if buffer.len() > MAX_RECORD_SIZE {
            discarding_oversized = true;
            let cut = buffer.len() - MAX_RECORD_SIZE;
            buffer.drain(..cut);
        }
    }

    // Process any remaining data (last line without trailing newline), but only if
    // it's within the size limit and we're not discarding.
    if !discarding_oversized && !buffer.is_empty() && buffer.len() <= MAX_RECORD_SIZE {
        process_record(&buffer, &mut st, w, seen, week, today, session);
    }
}

fn process_record(line: &[u8], st: &mut FileState, w: &Window, seen: &mut HashSet<String>, week: &mut TotalsMap, today: &mut TotalsMap, session: &mut TotalsMap) {
    let Ok(text) = std::str::from_utf8(line) else { return };
    if text.is_empty() {
        return;
    }
    let Some(rec) = parse_line(text, st) else { return };
    if rec.ts < w.week_start {
        return;
    }
    if let Some(key) = &rec.dedup_key {
        if !seen.insert(key.clone()) {
            return;
        }
    }
    add(week, &rec);
    if rec.ts >= w.today_start && rec.ts < w.today_end {
        add(today, &rec);
    }
    if rec.ts >= w.session_start {
        add(session, &rec);
    }
}

fn add(map: &mut TotalsMap, rec: &Record) {
    let e = map.entry(rec.model.clone()).or_default();
    e.input += rec.input;
    e.output += rec.output;
    e.cache_read += rec.cache_read;
    e.cache_write += rec.cache_write;
}

fn serialize(map: &TotalsMap) -> String {
    let mut entries: Vec<(&String, &ModelTotals)> = map.iter().collect();
    entries.sort_by(|a, b| a.0.cmp(b.0)); // deterministic output
    let parts: Vec<String> = entries
        .iter()
        .map(|(model, t)| {
            format!(
                "{{\"model\":{},\"input\":{},\"output\":{},\"cacheRead\":{},\"cacheWrite\":{}}}",
                json_string(model),
                t.input,
                t.output,
                t.cache_read,
                t.cache_write
            )
        })
        .collect();
    format!("[{}]", parts.join(","))
}

/// JSON string escaping, matching serde's output.
fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

struct Args {
    paths: Vec<String>,
    week_start: f64,
    session_start: f64,
    today_start: f64,
    today_end: f64,
}

fn aggregate_inner(a: &Args) -> String {
    let w = Window {
        week_start: a.week_start,
        session_start: a.session_start,
        today_start: a.today_start,
        today_end: a.today_end,
    };
    let mut seen = HashSet::new();
    let mut week = TotalsMap::new();
    let mut today = TotalsMap::new();
    let mut session = TotalsMap::new();
    for path in &a.paths {
        if !mtime_allows(path, a.week_start) {
            continue;
        }
        stream_file(path, &w, &mut seen, &mut week, &mut today, &mut session);
    }
    format!(
        "{{\"week\":{},\"today\":{},\"session\":{}}}",
        serialize(&week),
        serialize(&today),
        serialize(&session)
    )
}

/// Streaming JSONL usage aggregation for NUL-separated file paths.
///
/// `buf` holds `buf_len` bytes: UTF-8 file paths separated by NUL bytes (an
/// optional trailing NUL yields no empty path). Window bounds are unix seconds:
/// `week_start`, `session_start`, `[today_start, today_end)` (local-day
/// boundaries computed by the caller so calendar semantics stay with the host).
///
/// Returns a newly allocated NUL-terminated JSON string on success:
/// `{"week":[M...],"today":[M...],"session":[M...]}` where each element M is
/// `{"model":str,"input":i64,"output":i64,"cacheRead":i64,"cacheWrite":i64}`.
/// The caller must free the result with [`atoll_free_string`]. Returns NULL on
/// invalid arguments or an internal panic.
///
/// # Safety
/// `buf` must be readable for `buf_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn atoll_aggregate_usage(
    buf: *const c_char,
    buf_len: usize,
    week_start: f64,
    session_start: f64,
    today_start: f64,
    today_end: f64,
) -> *mut c_char {
    if buf.is_null() && buf_len > 0 {
        return ptr::null_mut();
    }
    let built = std::panic::catch_unwind(|| {
        let raw = std::slice::from_raw_parts(buf as *const u8, buf_len);
        let mut paths_vec = Vec::new();
        for seg in raw.split(|&b| b == 0) {
            if seg.is_empty() {
                continue;
            }
            match std::str::from_utf8(seg) {
                Ok(s) => paths_vec.push(s.to_owned()),
                Err(_) => return None, // non-UTF-8 path: fail the whole scan rather than half-count
            }
        }
        Some(Args {
            paths: paths_vec,
            week_start,
            session_start,
            today_start,
            today_end,
        })
    });
    let Ok(Some(args)) = built else {
        return ptr::null_mut();
    };
    match std::panic::catch_unwind(move || aggregate_inner(&args)) {
        Ok(json) => CString::new(json).map(CString::into_raw).unwrap_or(ptr::null_mut()),
        Err(_) => ptr::null_mut(),
    }
}

/// Free a string returned by [`atoll_aggregate_usage`].
///
/// # Safety
/// `s` must be a pointer previously returned by `atoll_aggregate_usage` and not yet
/// freed.
#[no_mangle]
pub unsafe extern "C" fn atoll_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// ABI version of the JSON payload produced by `atoll_aggregate_usage`.
#[no_mangle]
pub extern "C" fn atoll_usage_core_abi() -> u32 {
    1
}

#[cfg(test)]
mod tests;
