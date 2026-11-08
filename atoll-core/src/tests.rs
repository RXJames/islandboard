use super::*;
use serde_json::Value;
use std::fs;

fn iso_ts(ts: f64) -> String {
    let secs = ts.floor() as i64;
    let frac = ((ts - ts.floor()) * 1000.0).round() as i64;
    let days = secs.div_euclid(86400);
    let r = secs.rem_euclid(86400);
    let (y, m, d) = civil_from_days(days);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z", y, m, d, r / 3600, (r % 3600) / 60, r % 60, frac)
}

fn civil_from_days(z0: i64) -> (i64, i64, i64) {
    let z = z0 + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

struct TempFile {
    path: String,
}
impl TempFile {
    fn new(content: &str) -> TempFile {
        static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("atoll_core_test_{}_{}.jsonl", std::process::id(), n));
        fs::write(&path, content).unwrap();
        TempFile {
            path: path.to_string_lossy().into_owned(),
        }
    }
}
impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn agg(paths: &[&str], week_start: f64, session_start: f64, today_start: f64, today_end: f64) -> Value {
    let args = Args {
        paths: paths.iter().map(|s| s.to_string()).collect(),
        week_start,
        session_start,
        today_start,
        today_end,
    };
    serde_json::from_str(&aggregate_inner(&args)).unwrap()
}

fn totals_for(v: &Value, bucket: &str, model: &str) -> (i64, i64) {
    v[bucket]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["model"] == model)
        .map(|e| (e["input"].as_i64().unwrap(), e["output"].as_i64().unwrap()))
        .unwrap_or((0, 0))
}

fn windows(now: f64) -> (f64, f64, f64, f64) {
    (now - 7.0 * 86400.0, now - 5.0 * 3600.0, (now / 86400.0).floor() * 86400.0, (now / 86400.0).floor() * 86400.0 + 86400.0)
}

#[test]
fn test_parse_valid_jsonl_records() {
    let now = 1_780_000_000.0;
    let (ws, ss, ts_, te) = windows(now);
    let f = TempFile::new(&format!(
        "{{\"timestamp\": \"{}\", \"message\": {{\"id\": \"msg1\", \"model\": \"claude-3-opus\", \"usage\": {{\"input_tokens\": 100, \"output_tokens\": 50}}}}}}\n{{\"timestamp\": \"{}\", \"message\": {{\"id\": \"msg2\", \"model\": \"claude-3-sonnet\", \"usage\": {{\"input_tokens\": 200, \"output_tokens\": 100}}}}}}\n",
        iso_ts(now - 3600.0),
        iso_ts(now - 7200.0)
    ));
    let v = agg(&[&f.path], ws, ss, ts_, te);
    assert_eq!(totals_for(&v, "session", "claude-3-opus"), (100, 50));
    assert_eq!(totals_for(&v, "session", "claude-3-sonnet"), (200, 100));
    assert_eq!(v["session"].as_array().unwrap().len(), 2);
    assert_eq!(v["week"].as_array().unwrap().len(), 2);
    assert_eq!(v["today"].as_array().unwrap().len(), 2);
}

#[test]
fn test_parse_deduplicates_by_message_id() {
    let now = 1_780_000_000.0;
    let (ws, ss, ts_, te) = windows(now);
    let line = format!(
        "{{\"timestamp\": \"{}\", \"message\": {{\"id\": \"msg1\", \"model\": \"claude-3-opus\", \"usage\": {{\"input_tokens\": 100, \"output_tokens\": 50}}}}}}",
        iso_ts(now - 3600.0)
    );
    let f = TempFile::new(&format!("{line}\n{line}\n"));
    let v = agg(&[&f.path], ws, ss, ts_, te);
    assert_eq!(totals_for(&v, "session", "claude-3-opus"), (100, 50));
}

#[test]
fn test_dedup_across_files() {
    let now = 1_780_000_000.0;
    let (ws, ss, ts_, te) = windows(now);
    let line = format!(
        "{{\"timestamp\": \"{}\", \"message\": {{\"id\": \"msgX\", \"model\": \"m\", \"usage\": {{\"input_tokens\": 10, \"output_tokens\": 5}}}}}}",
        iso_ts(now - 3600.0)
    );
    let a = TempFile::new(&format!("{line}\n"));
    let b = TempFile::new(&format!("{line}\n"));
    let v = agg(&[&a.path, &b.path], ws, ss, ts_, te);
    assert_eq!(totals_for(&v, "week", "m"), (10, 5));
}

#[test]
fn test_rejects_oversized_unterminated_record() {
    let now = 1_780_000_000.0;
    let (ws, ss, ts_, te) = windows(now);
    let valid = format!(
        "{{\"timestamp\": \"{}\", \"message\": {{\"id\": \"msg1\", \"model\": \"claude-3-opus\", \"usage\": {{\"input_tokens\": 100, \"output_tokens\": 50}}}}}}",
        iso_ts(now - 3600.0)
    );
    let valid2 = format!(
        "{{\"timestamp\": \"{}\", \"message\": {{\"id\": \"msg2\", \"model\": \"claude-3-sonnet\", \"usage\": {{\"input_tokens\": 200, \"output_tokens\": 100}}}}}}",
        iso_ts(now - 3600.0)
    );
    let padding = "x".repeat(1024 * 1024 + 100);
    let oversized = format!(
        "{{\"timestamp\": \"{}\", \"message\": {{\"id\": \"msgOversized\", \"model\": \"claude-3-opus\", \"usage\": {{\"input_tokens\": 100, \"output_tokens\": 50}}}}, \"padding\": \"{}\"}}",
        iso_ts(now - 3600.0),
        padding
    );
    let f = TempFile::new(&format!("{valid}\n{oversized}\n{valid2}"));
    let v = agg(&[&f.path], ws, ss, ts_, te);
    assert_eq!(totals_for(&v, "session", "claude-3-opus"), (100, 50)); // only msg1
    assert_eq!(totals_for(&v, "session", "claude-3-sonnet"), (200, 100));
    assert_eq!(v["session"].as_array().unwrap().len(), 2);
}

#[test]
fn test_parses_allowed_size_unterminated_final_record() {
    let now = 1_780_000_000.0;
    let (ws, ss, ts_, te) = windows(now);
    let valid = format!(
        "{{\"timestamp\": \"{}\", \"message\": {{\"id\": \"msg1\", \"model\": \"claude-3-opus\", \"usage\": {{\"input_tokens\": 100, \"output_tokens\": 50}}}}}}",
        iso_ts(now - 3600.0)
    );
    let final_line = format!(
        "{{\"timestamp\": \"{}\", \"message\": {{\"id\": \"msg2\", \"model\": \"claude-3-sonnet\", \"usage\": {{\"input_tokens\": 200, \"output_tokens\": 100}}}}}}",
        iso_ts(now - 3600.0)
    );
    let f = TempFile::new(&format!("{valid}\n{final_line}")); // no trailing newline
    let v = agg(&[&f.path], ws, ss, ts_, te);
    assert_eq!(totals_for(&v, "session", "claude-3-opus"), (100, 50));
    assert_eq!(totals_for(&v, "session", "claude-3-sonnet"), (200, 100));
}

#[test]
fn test_skips_records_outside_week_window() {
    let now = 1_780_000_000.0;
    let (ws, ss, ts_, te) = windows(now);
    let old = format!(
        "{{\"timestamp\": \"{}\", \"message\": {{\"id\": \"msg1\", \"model\": \"old-model\", \"usage\": {{\"input_tokens\": 100, \"output_tokens\": 50}}}}}}",
        iso_ts(now - 8.0 * 86400.0)
    );
    let recent = format!(
        "{{\"timestamp\": \"{}\", \"message\": {{\"id\": \"msg2\", \"model\": \"new-model\", \"usage\": {{\"input_tokens\": 200, \"output_tokens\": 100}}}}}}",
        iso_ts(now - 3600.0)
    );
    let f = TempFile::new(&format!("{old}\n{recent}\n"));
    let v = agg(&[&f.path], ws, ss, ts_, te);
    assert_eq!(totals_for(&v, "week", "new-model"), (200, 100));
    assert_eq!(v["week"].as_array().unwrap().len(), 1);
}

#[test]
fn test_parse_codex_token_count_format() {
    let now = 1_780_000_000.0;
    let (ws, ss, ts_, te) = windows(now);
    let content = format!(
        "{{\"type\": \"event_msg\", \"timestamp\": \"{}\", \"payload\": {{\"type\": \"token_count\", \"info\": {{\"last_token_usage\": {{\"input_tokens\": 500, \"output_tokens\": 250}}}}}}}}",
        iso_ts(now - 3600.0)
    );
    let f = TempFile::new(&content);
    let v = agg(&[&f.path], ws, ss, ts_, te);
    assert_eq!(totals_for(&v, "session", "codex"), (500, 250));
}

#[test]
fn test_codex_turn_context_model_propagates() {
    let now = 1_780_000_000.0;
    let (ws, ss, ts_, te) = windows(now);
    let content = format!(
        "{{\"type\": \"turn_context\", \"payload\": {{\"model\": \"gpt-5.1-codex\"}}}}\n{{\"type\": \"event_msg\", \"timestamp\": \"{}\", \"payload\": {{\"type\": \"token_count\", \"info\": {{\"last_token_usage\": {{\"input_tokens\": 1000, \"cached_input_tokens\": 400, \"cache_write_input_tokens\": 0, \"output_tokens\": 100}}}}}}}}",
        iso_ts(now - 3600.0)
    );
    let f = TempFile::new(&content);
    let v = agg(&[&f.path], ws, ss, ts_, te);
    let (input, output) = totals_for(&v, "week", "gpt-5.1-codex");
    assert_eq!((input, output), (1000, 100));
    assert_eq!(v["week"].as_array().unwrap().len(), 1); // not tagged "codex"
}

#[test]
fn test_codex_cache_semantics() {
    // input already includes cached; total input = input + cache_write; cache_read = min(input, cached)
    let line = format!(
        "{{\"type\": \"event_msg\", \"timestamp\": \"{}\", \"payload\": {{\"type\": \"token_count\", \"info\": {{\"last_token_usage\": {{\"input_tokens\": 100, \"cached_input_tokens\": 150, \"cache_write_input_tokens\": 30, \"output_tokens\": 10}}}}}}}}",
        iso_ts(1_780_000_000.0 - 3600.0)
    );
    let st = &mut FileState::default();
    let rec = parse_line(&line, st).unwrap();
    assert_eq!(rec.input, 130); // 100 + 30
    assert_eq!(rec.cache_read, 100); // min(100, 150)
    assert_eq!(rec.cache_write, 30);
}

#[test]
fn test_claude_cache_buckets_sum_into_input() {
    // input_tokens + cache_creation + cache_read = shown input
    let line = format!(
        "{{\"timestamp\": \"{}\", \"message\": {{\"model\": \"claude\", \"usage\": {{\"input_tokens\": 10, \"cache_creation_input_tokens\": 5, \"cache_read_input_tokens\": 7, \"output_tokens\": 2}}}}}}",
        iso_ts(1_780_000_000.0 - 3600.0)
    );
    let st = &mut FileState::default();
    let rec = parse_line(&line, st).unwrap();
    assert_eq!(rec.input, 22);
    assert_eq!(rec.cache_read, 7);
    assert_eq!(rec.cache_write, 5);
    assert_eq!(rec.dedup_key, None); // no message id / request id
}

#[test]
fn test_request_id_dedup_key() {
    let line = format!(
        "{{\"timestamp\": \"{}\", \"requestId\": \"req1\", \"usage\": {{\"input_tokens\": 1, \"output_tokens\": 1}}}}",
        iso_ts(1_780_000_000.0 - 3600.0)
    );
    let st = &mut FileState::default();
    let rec = parse_line(&line, st).unwrap();
    assert_eq!(rec.dedup_key.as_deref(), Some("-req1")); // mirrors Swift's "msgID-reqID" with empty message id
    assert_eq!(rec.model, "unknown");
}

#[test]
fn test_record_spanning_chunk_boundary_is_parsed() {
    // A ~200 KB valid record spread across several 64 KB chunks must not be
    // dropped: interleaved padding rows keep usage lines spread out.
    let now = 1_780_000_000.0;
    let (ws, ss, ts_, te) = windows(now);
    let mut lines = Vec::new();
    let big_payload = "y".repeat(200 * 1024);
    lines.push(format!(
        "{{\"timestamp\": \"{}\", \"message\": {{\"id\": \"big\", \"model\": \"m\", \"usage\": {{\"input_tokens\": 42, \"output_tokens\": 7}}, \"note\": \"{}\"}}}}",
        iso_ts(now - 3600.0),
        big_payload
    ));
    let f = TempFile::new(&lines.join("\n"));
    let v = agg(&[&f.path], ws, ss, ts_, te);
    assert_eq!(totals_for(&v, "week", "m"), (42, 7));
}

#[test]
fn test_non_object_lines_are_skipped() {
    let now = 1_780_000_000.0;
    let (ws, ss, ts_, te) = windows(now);
    let f = TempFile::new(&format!("[1,2,3]\n\"just a string\"\n{{bad json\n{}", iso_ts(now)));
    let v = agg(&[&f.path], ws, ss, ts_, te);
    assert_eq!(v["week"].as_array().unwrap().len(), 0);
}

#[test]
fn test_iso8601_variants() {
    // fractional + Z
    assert!(parse_iso8601("2026-11-08T01:02:03.456Z").is_some());
    // plain internet date (no fraction)
    let plain = parse_iso8601("2026-11-08T01:02:03Z").unwrap();
    let frac = parse_iso8601("2026-11-08T01:02:03.000Z").unwrap();
    assert_eq!(plain, frac);
    // explicit offsets
    let utc = parse_iso8601("2026-11-08T01:02:03Z").unwrap();
    let plus = parse_iso8601("2026-11-08T09:02:03+08:00").unwrap();
    assert_eq!(utc, plus);
    // rejections
    assert!(parse_iso8601("2026-11-08 01:02:03Z").is_none());
    assert!(parse_iso8601("2026-13-08T01:02:03Z").is_none());
    assert!(parse_iso8601("2026-11-08T01:02:03").is_none()); // missing zone
    assert!(parse_iso8601("").is_none());
}

#[test]
fn test_missing_file_is_kept_and_yields_nothing() {
    // metadata unreadable → keep the file (matches Swift), open fails → no records
    let (ws, ss, ts_, te) = windows(1_780_000_000.0);
    let v = agg(&["/nonexistent/atoll.jsonl"], ws, ss, ts_, te);
    assert_eq!(v["week"].as_array().unwrap().len(), 0);
}

#[test]
fn test_json_escape_in_model_name() {
    assert_eq!(json_string("a\"b\\c\nd"), "\"a\\\"b\\\\c\\nd\"");
}
