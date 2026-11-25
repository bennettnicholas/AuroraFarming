//! The on-phone database.
//!
//! One SQLite file holds two layers:
//! * open_oura's `oura-store` schema (`events`, `device`, `sync_state`, ...): every
//!   history event exactly as the ring sent it, plus the sync cursor. This layer
//!   is lossless, so better decoders can re-derive everything later.
//! * Aurora's own tables: `samples` (dated, typed metrics derived by
//!   [`crate::metrics`]) and `connector_state` (how far each export connector got).
//!
//! Sample rows have stable ids: re-deriving a sample (for example once a later
//! time anchor dates it more precisely) updates it in place, so export connectors
//! can page through `samples` by id without re-sending everything.

use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;

use crate::metrics::{points_for_event, MetricKind, RingPoint, Sample, SleepStageAssembler};
use crate::ring_time::{ClockSource, RingClock};
use crate::CoreError;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS aurora_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS samples (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    kind     TEXT NOT NULL,
    ts       REAL NOT NULL,
    end_ts   REAL,
    value    REAL NOT NULL,
    event_id INTEGER NOT NULL,
    ord      INTEGER NOT NULL,
    UNIQUE(event_id, kind, ord)
);
CREATE INDEX IF NOT EXISTS idx_samples_kind_ts ON samples(kind, ts);
CREATE TABLE IF NOT EXISTS connector_state (
    connector_id  TEXT PRIMARY KEY,
    cursor        INTEGER NOT NULL,
    updated_unix  INTEGER NOT NULL
);
"#;

/// Event tags [`crate::metrics`] derives samples from.
const METRIC_TAGS: &str = "80, 93, 106, 111, 117, 118, 90, 128";
// 0x50=80 activity, 0x5d=93 hrv, 0x6a=106 sleep period, 0x6f=111 spo2,
// 0x75=117 sleep temp, 0x76=118 bedtime, 0x5a=90 sleep stages, 0x80=128 green IBI.

/// Events captured this recently are re-derived on every refresh, so a time anchor
/// that arrives in a later sync re-dates them.
const REDERIVE_WINDOW_S: i64 = 3 * 24 * 3600;

pub(crate) fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

struct Inner {
    raw: oura_store::Store,
    conn: Connection,
}

/// The app's database. Thread-safe; every call is short and synchronous.
#[derive(uniffi::Object)]
pub struct AuroraStore {
    path: String,
    inner: Mutex<Inner>,
}

/// Time-bucketed aggregate of one metric, for charts.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Bucket {
    /// Bucket start, unix seconds UTC (aligned to local time via `tz_offset_seconds`).
    pub start: f64,
    pub min: f64,
    pub max: f64,
    pub mean: f64,
    pub count: u32,
}

/// One day at a glance. `None` means "no data", never zero.
#[derive(Clone, Debug, Default, PartialEq, uniffi::Record)]
pub struct DaySummary {
    pub day_start: f64,
    /// The sleep window that ended during this day (the ring's `bedtime_period`).
    pub sleep_start: Option<f64>,
    pub sleep_end: Option<f64>,
    /// Time in bed, hours.
    pub time_in_bed_hours: Option<f64>,
    /// Asleep hours from the ring's own staging, when the ring staged the night.
    pub asleep_hours: Option<f64>,
    pub deep_hours: Option<f64>,
    pub light_hours: Option<f64>,
    pub rem_hours: Option<f64>,
    pub awake_hours: Option<f64>,
    /// Low (5th percentile) heart rate during sleep, or during the day without a sleep window.
    pub resting_hr: Option<f64>,
    pub average_hr: Option<f64>,
    pub max_hr: Option<f64>,
    /// Mean RMSSD during sleep (or the day).
    pub average_hrv: Option<f64>,
    /// Mean nocturnal skin temperature, °C.
    pub skin_temperature: Option<f64>,
    /// Difference from the mean of the previous 14 nights, °C.
    pub temperature_deviation: Option<f64>,
    pub average_spo2: Option<f64>,
    pub respiratory_rate: Option<f64>,
    /// Minutes at or above 2.5 MET.
    pub active_minutes: u32,
    /// Sum of (MET − 1) over active minutes.
    pub met_minutes: f64,
    /// Active energy estimate, kcal (MET-minutes × weight / 60).
    pub active_kcal: f64,
    /// Rough step estimate from MET intensity (the ring does not count steps itself).
    pub estimated_steps: u32,
    pub latest_battery: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct StoreStats {
    pub raw_events: u64,
    pub decoded_events: u64,
    pub samples: u64,
    pub first_sample_ts: Option<f64>,
    pub last_sample_ts: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct StoredDevice {
    pub serial: String,
    pub hardware_id: String,
    pub firmware: String,
    pub api_version: String,
    pub mac: String,
    pub last_sync_unix: i64,
    pub next_cursor: i64,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct EventTypeCount {
    pub name: String,
    pub total: u64,
    pub decoded: u64,
}

impl AuroraStore {
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        // A panic while holding the lock would poison it; the data is still a valid
        // SQLite handle, so keep going rather than bricking the app.
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub(crate) fn with_raw<R>(
        &self,
        f: impl FnOnce(&oura_store::Store) -> oura_store::Result<R>,
    ) -> Result<R, CoreError> {
        Ok(f(&self.lock().raw)?)
    }

    pub(crate) fn record_battery(&self, serial: &str, percent: u8) -> Result<(), CoreError> {
        let inner = self.lock();
        inner.raw.insert_reading(serial, "battery_percent", percent as f64, "%")?;
        // A synthetic sample, keyed by the sync time so it never collides with events.
        let now = now_unix();
        inner.conn.execute(
            "INSERT OR IGNORE INTO samples (kind, ts, end_ts, value, event_id, ord)
             VALUES (?1, ?2, NULL, ?3, 0, ?4)",
            params![MetricKind::Battery.id(), now as f64, percent as f64, now],
        )?;
        Ok(())
    }
}

fn get_meta(conn: &Connection, key: &str) -> rusqlite::Result<Option<String>> {
    conn.query_row(
        "SELECT value FROM aurora_meta WHERE key = ?1",
        params![key],
        |r| r.get(0),
    )
    .optional()
}

fn set_meta(conn: &Connection, key: &str, value: &str) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO aurora_meta (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
}

/// The rows `RingClock` needs, in `Store::decoded_events` order: JSON only for the
/// time anchors (0x42 time_sync, 0x85 rtc_beacon), plus raw ring_start rows.
fn clock_rows(conn: &Connection) -> rusqlite::Result<Vec<(i64, u8, String, i64)>> {
    let mut stmt = conn.prepare(
        "SELECT ring_timestamp, tag,
                CASE WHEN tag IN (66, 133) THEN COALESCE(decoded_json, '') ELSE '' END,
                captured_unix
         FROM events
         WHERE decoded_json IS NOT NULL OR (tag = 65 AND LENGTH(body) >= 14)
         ORDER BY captured_unix, id",
    )?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)? as u8,
                r.get::<_, String>(2)?,
                r.get::<_, i64>(3)?,
            ))
        })?
        .collect();
    rows
}

fn kind_of(id: &str) -> Option<MetricKind> {
    MetricKind::from_id(id)
}

fn row_to_sample(r: &rusqlite::Row<'_>) -> rusqlite::Result<Option<Sample>> {
    let kind: String = r.get(1)?;
    Ok(kind_of(&kind).map(|kind| Sample {
        id: r.get(0).unwrap_or_default(),
        kind,
        ts: r.get(2).unwrap_or_default(),
        end_ts: r.get(3).unwrap_or_default(),
        value: r.get(4).unwrap_or_default(),
        event_id: r.get(5).unwrap_or_default(),
    }))
}

fn percentile(sorted: &[f64], p: f64) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    let idx = ((sorted.len() - 1) as f64 * p).round() as usize;
    Some(sorted[idx.min(sorted.len() - 1)])
}

fn mean(xs: &[f64]) -> Option<f64> {
    (!xs.is_empty()).then(|| xs.iter().sum::<f64>() / xs.len() as f64)
}

fn round(v: Option<f64>, places: i32) -> Option<f64> {
    let m = 10f64.powi(places);
    v.map(|x| (x * m).round() / m)
}

impl Inner {
    fn values(&self, kind: MetricKind, from: f64, to: f64) -> rusqlite::Result<Vec<f64>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT value FROM samples WHERE kind = ?1 AND ts >= ?2 AND ts < ?3 ORDER BY ts",
        )?;
        let rows = stmt
            .query_map(params![kind.id(), from, to], |r| r.get::<_, f64>(0))?
            .collect();
        rows
    }

    /// Re-derive samples for new events and for recently captured ones.
    fn refresh(&self, full: bool) -> Result<u32, CoreError> {
        let clock = RingClock::from_events(&clock_rows(&self.conn)?);
        let last: i64 = if full {
            0
        } else {
            get_meta(&self.conn, "derived_through_event_id")?
                .and_then(|v| v.parse().ok())
                .unwrap_or(0)
        };
        let max_captured: i64 = self
            .conn
            .query_row("SELECT COALESCE(MAX(captured_unix), 0) FROM events", [], |r| r.get(0))?;
        let since_capture = if full { i64::MIN } else { max_captured - REDERIVE_WINDOW_S };

        let sql = format!(
            "SELECT id, tag, ring_timestamp, captured_unix, decoded_json FROM events
             WHERE decoded_json IS NOT NULL AND tag IN ({METRIC_TAGS})
               AND (id > ?1 OR captured_unix >= ?2)
             ORDER BY id"
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows: Vec<(i64, u8, i64, i64, String)> = stmt
            .query_map(params![last, since_capture], |r| {
                Ok((
                    r.get(0)?,
                    r.get::<_, i64>(1)? as u8,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                ))
            })?
            .collect::<rusqlite::Result<_>>()?;
        drop(stmt);

        let mut max_id = last;
        let mut stages = SleepStageAssembler::new();
        let mut derived: Vec<(i64, i64, RingPoint)> = Vec::new(); // (event id, captured, point)
        let mut captured_by_event = std::collections::HashMap::new();
        for (id, tag, ds, captured, json) in rows {
            max_id = max_id.max(id);
            let Ok(v) = serde_json::from_str::<Value>(&json) else {
                continue;
            };
            if tag == 0x5a {
                captured_by_event.insert(id, captured);
                stages.push(id, ds, &v);
                continue;
            }
            for p in points_for_event(tag, ds, &v) {
                derived.push((id, captured, p));
            }
        }
        for (id, p) in stages.finish() {
            let captured = captured_by_event.get(&id).copied().unwrap_or(max_captured);
            derived.push((id, captured, p));
        }

        let tx = self.conn.unchecked_transaction()?;
        let mut written = 0u32;
        {
            let mut upsert = tx.prepare_cached(
                "INSERT INTO samples (kind, ts, end_ts, value, event_id, ord)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(event_id, kind, ord) DO UPDATE SET
                   ts = excluded.ts, end_ts = excluded.end_ts, value = excluded.value
                 WHERE samples.ts IS NOT excluded.ts OR samples.value IS NOT excluded.value
                    OR samples.end_ts IS NOT excluded.end_ts",
            )?;
            let mut ord_by_key: std::collections::HashMap<(i64, MetricKind), i64> =
                std::collections::HashMap::new();
            for (event_id, captured, p) in derived {
                let ord = ord_by_key.entry((event_id, p.kind)).or_insert(0);
                let this_ord = *ord;
                *ord += 1;
                let start = clock.resolve(p.ds, captured);
                if start.source == ClockSource::Undated {
                    continue; // left for a later refresh once an anchor dates it
                }
                let end = p.end_ds.map(|e| clock.resolve(e, captured).unix);
                written += upsert.execute(params![
                    p.kind.id(),
                    start.unix,
                    end,
                    p.value,
                    event_id,
                    this_ord
                ])? as u32;
            }
        }
        set_meta(&tx, "derived_through_event_id", &max_id.to_string())?;
        tx.commit()?;
        Ok(written)
    }

    fn sleep_window(&self, from: f64, to: f64) -> rusqlite::Result<Option<(f64, f64)>> {
        // The longest bedtime window that ended inside [from, to).
        self.conn
            .query_row(
                "SELECT ts, end_ts FROM samples
                 WHERE kind = ?1 AND end_ts >= ?2 AND end_ts < ?3
                 ORDER BY (end_ts - ts) DESC LIMIT 1",
                params![MetricKind::SleepSession.id(), from, to],
                |r| Ok((r.get::<_, f64>(0)?, r.get::<_, f64>(1)?)),
            )
            .optional()
    }

    fn night_temperature(&self, from: f64, to: f64) -> rusqlite::Result<Option<f64>> {
        let window = self.sleep_window(from, to)?;
        let (s, e) = window.unwrap_or((from, to));
        Ok(mean(&self.values(MetricKind::SkinTemperature, s, e)?))
    }
}

#[uniffi::export]
impl AuroraStore {
    /// Open (or create) the database at `path`.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<std::sync::Arc<Self>, CoreError> {
        let raw = oura_store::Store::open(&path)?;
        let conn = Connection::open(&path)?;
        conn.busy_timeout(std::time::Duration::from_millis(5000))?;
        conn.execute_batch(SCHEMA)?;
        Ok(std::sync::Arc::new(Self {
            path,
            inner: Mutex::new(Inner { raw, conn }),
        }))
    }

    pub fn path(&self) -> String {
        self.path.clone()
    }

    /// Derive samples from events synced since the last call. Returns rows written.
    pub fn refresh_samples(&self) -> Result<u32, CoreError> {
        self.lock().refresh(false)
    }

    /// Re-derive every sample from the raw events (after an app update that
    /// improves decoding). Sample ids are kept for samples that still exist.
    pub fn rebuild_samples(&self) -> Result<u32, CoreError> {
        let inner = self.lock();
        inner.raw.redecode()?;
        inner.refresh(true)
    }

    /// Samples of `kind` with `from <= ts < to`, oldest first, at most `limit`.
    pub fn samples(
        &self,
        kind: MetricKind,
        from: f64,
        to: f64,
        limit: u32,
    ) -> Result<Vec<Sample>, CoreError> {
        let inner = self.lock();
        let mut stmt = inner.conn.prepare_cached(
            "SELECT id, kind, ts, end_ts, value, event_id FROM samples
             WHERE kind = ?1 AND ts >= ?2 AND ts < ?3 ORDER BY ts LIMIT ?4",
        )?;
        let rows = stmt
            .query_map(params![kind.id(), from, to, limit], row_to_sample)?
            .filter_map(|r| r.transpose())
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// The most recent sample of `kind`.
    pub fn latest(&self, kind: MetricKind) -> Result<Option<Sample>, CoreError> {
        let inner = self.lock();
        let s = inner
            .conn
            .query_row(
                "SELECT id, kind, ts, end_ts, value, event_id FROM samples
                 WHERE kind = ?1 ORDER BY ts DESC LIMIT 1",
                params![kind.id()],
                row_to_sample,
            )
            .optional()?
            .flatten();
        Ok(s)
    }

    /// Aggregate `kind` into buckets of `bucket_seconds`, aligned to local time
    /// (`tz_offset_seconds` east of UTC). Empty buckets are omitted.
    pub fn buckets(
        &self,
        kind: MetricKind,
        from: f64,
        to: f64,
        bucket_seconds: u32,
        tz_offset_seconds: i32,
    ) -> Result<Vec<Bucket>, CoreError> {
        let size = bucket_seconds.max(60) as f64;
        let off = tz_offset_seconds as f64;
        let inner = self.lock();
        let mut stmt = inner.conn.prepare_cached(
            "SELECT CAST((ts + ?4) / ?5 AS INTEGER) AS b, MIN(value), MAX(value), AVG(value), COUNT(*)
             FROM samples WHERE kind = ?1 AND ts >= ?2 AND ts < ?3
             GROUP BY b ORDER BY b",
        )?;
        let rows = stmt
            .query_map(params![kind.id(), from, to, off, size], |r| {
                let b: i64 = r.get(0)?;
                Ok(Bucket {
                    start: b as f64 * size - off,
                    min: r.get(1)?,
                    max: r.get(2)?,
                    mean: r.get(3)?,
                    count: r.get::<_, i64>(4)? as u32,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Summary of the day `[day_start, day_start + 24 h)`. `weight_kg` scales the
    /// energy estimate (pass 0 for the 75 kg default).
    pub fn day_summary(&self, day_start: f64, weight_kg: f64) -> Result<DaySummary, CoreError> {
        let inner = self.lock();
        let day_end = day_start + 86_400.0;
        let weight = if weight_kg > 0.0 { weight_kg } else { 75.0 };
        let mut s = DaySummary {
            day_start,
            ..Default::default()
        };

        let window = inner.sleep_window(day_start, day_end)?;
        if let Some((start, end)) = window {
            s.sleep_start = Some(start);
            s.sleep_end = Some(end);
            s.time_in_bed_hours = round(Some((end - start) / 3600.0), 2);
            let stages = inner.values(MetricKind::SleepStage, start - 3600.0, end + 3600.0)?;
            if !stages.is_empty() {
                let hours = |code: f64| {
                    round(
                        Some(stages.iter().filter(|c| **c == code).count() as f64 * 30.0 / 3600.0),
                        2,
                    )
                };
                s.deep_hours = hours(1.0);
                s.light_hours = hours(2.0);
                s.rem_hours = hours(3.0);
                s.awake_hours = hours(4.0);
                s.asleep_hours = round(
                    Some(stages.iter().filter(|c| **c != 4.0).count() as f64 * 30.0 / 3600.0),
                    2,
                );
            }
        }
        let (vs, ve) = window.unwrap_or((day_start, day_end));

        let mut night_hr = inner.values(MetricKind::HeartRate, vs, ve)?;
        night_hr.sort_by(|a, b| a.total_cmp(b));
        s.resting_hr = round(percentile(&night_hr, 0.05), 0);
        let day_hr = inner.values(MetricKind::HeartRate, day_start, day_end)?;
        s.average_hr = round(mean(&day_hr), 0);
        s.max_hr = day_hr.iter().copied().reduce(f64::max);
        s.average_hrv = round(mean(&inner.values(MetricKind::Hrv, vs, ve)?), 0);
        s.average_spo2 = round(mean(&inner.values(MetricKind::Spo2, vs, ve)?), 1);
        s.respiratory_rate = round(mean(&inner.values(MetricKind::RespiratoryRate, vs, ve)?), 1);

        s.skin_temperature = round(inner.night_temperature(day_start, day_end)?, 2);
        if let Some(t) = s.skin_temperature {
            let mut previous = Vec::new();
            for d in 1..=14 {
                let ds = day_start - d as f64 * 86_400.0;
                if let Some(v) = inner.night_temperature(ds, ds + 86_400.0)? {
                    previous.push(v);
                }
            }
            if previous.len() >= 3 {
                s.temperature_deviation = round(mean(&previous).map(|b| t - b), 2);
            }
        }

        for met in inner.values(MetricKind::ActivityMet, day_start, day_end)? {
            if met >= 2.5 {
                s.active_minutes += 1;
                s.met_minutes += met - 1.0;
            }
            // open_health's intensity-to-cadence rule (steps per minute).
            s.estimated_steps += if met >= 7.0 {
                150
            } else if met >= 2.5 {
                105
            } else {
                0
            };
        }
        s.met_minutes = (s.met_minutes * 10.0).round() / 10.0;
        s.active_kcal = (s.met_minutes * weight / 60.0).round();
        s.latest_battery = inner
            .values(MetricKind::Battery, day_start, day_end)?
            .last()
            .copied();
        Ok(s)
    }

    /// Samples with id greater than `after_id`, of the given kinds, by id. This is
    /// how export connectors page through new data.
    pub fn samples_after(
        &self,
        after_id: i64,
        kinds: Vec<MetricKind>,
        limit: u32,
    ) -> Result<Vec<Sample>, CoreError> {
        if kinds.is_empty() {
            return Ok(Vec::new());
        }
        let ids: Vec<String> = kinds.iter().map(|k| format!("'{}'", k.id())).collect();
        let sql = format!(
            "SELECT id, kind, ts, end_ts, value, event_id FROM samples
             WHERE id > ?1 AND kind IN ({}) ORDER BY id LIMIT ?2",
            ids.join(",")
        );
        let inner = self.lock();
        let mut stmt = inner.conn.prepare(&sql)?;
        let rows = stmt
            .query_map(params![after_id, limit], row_to_sample)?
            .filter_map(|r| r.transpose())
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Last sample id a connector has exported (0 if never).
    pub fn connector_cursor(&self, connector_id: String) -> Result<i64, CoreError> {
        let inner = self.lock();
        Ok(inner
            .conn
            .query_row(
                "SELECT cursor FROM connector_state WHERE connector_id = ?1",
                params![connector_id],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(0))
    }

    pub fn set_connector_cursor(&self, connector_id: String, cursor: i64) -> Result<(), CoreError> {
        let inner = self.lock();
        inner.conn.execute(
            "INSERT INTO connector_state (connector_id, cursor, updated_unix) VALUES (?1, ?2, ?3)
             ON CONFLICT(connector_id) DO UPDATE SET cursor = excluded.cursor,
               updated_unix = excluded.updated_unix",
            params![connector_id, cursor, now_unix()],
        )?;
        Ok(())
    }

    pub fn stats(&self) -> Result<StoreStats, CoreError> {
        let inner = self.lock();
        let (raw, decoded) = inner.raw.event_totals()?;
        let (n, first, last) = inner.conn.query_row(
            "SELECT COUNT(*), MIN(ts), MAX(ts) FROM samples WHERE kind != ?1",
            params![MetricKind::Battery.id()],
            |r| Ok((r.get::<_, i64>(0)?, r.get(1)?, r.get(2)?)),
        )?;
        Ok(StoreStats {
            raw_events: raw as u64,
            decoded_events: decoded as u64,
            samples: n as u64,
            first_sample_ts: first,
            last_sample_ts: last,
        })
    }

    /// The most recently synced ring.
    pub fn device(&self) -> Result<Option<StoredDevice>, CoreError> {
        let inner = self.lock();
        Ok(inner.raw.device_info()?.map(
            |(serial, hardware_id, firmware, api_version, mac, _, last_sync_unix, next_cursor)| {
                StoredDevice {
                    serial,
                    hardware_id,
                    firmware,
                    api_version,
                    mac,
                    last_sync_unix,
                    next_cursor,
                }
            },
        ))
    }

    /// Raw event counts by type, for the "raw data" screen.
    pub fn event_counts(&self) -> Result<Vec<EventTypeCount>, CoreError> {
        let inner = self.lock();
        let mut stmt = inner.conn.prepare(
            "SELECT name, COUNT(*), SUM(decoded_json IS NOT NULL) FROM events
             GROUP BY name ORDER BY COUNT(*) DESC",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(EventTypeCount {
                    name: r.get(0)?,
                    total: r.get::<_, i64>(1)? as u64,
                    decoded: r.get::<_, i64>(2)? as u64,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Restart history download from the beginning for `serial` (needed after a
    /// factory reset, when the ring's counter starts over). Duplicates are ignored.
    pub fn reset_sync_cursor(&self, serial: String) -> Result<(), CoreError> {
        self.lock().raw.set_cursor(&serial, 0)?;
        Ok(())
    }

    /// Write a self-contained copy of the database (no auth key inside) to `dest_path`.
    /// The copy opens in open_oura's and open_health's desktop tools.
    pub fn export_copy(&self, dest_path: String) -> Result<(), CoreError> {
        self.lock().raw.export_to(&dest_path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use oura_protocol::events::RingEvent;

    pub(crate) fn temp_db() -> (tempdir::Dir, std::sync::Arc<AuroraStore>) {
        let dir = tempdir::Dir::new();
        let store = AuroraStore::open(dir.path("t.db")).unwrap();
        (dir, store)
    }

    pub(crate) mod tempdir {
        pub struct Dir(std::path::PathBuf);
        impl Dir {
            pub fn new() -> Self {
                let p = std::env::temp_dir().join(format!(
                    "aurora-test-{}-{}",
                    std::process::id(),
                    rand_suffix()
                ));
                std::fs::create_dir_all(&p).unwrap();
                Dir(p)
            }
            pub fn path(&self, name: &str) -> String {
                self.0.join(name).to_string_lossy().into_owned()
            }
        }
        impl Drop for Dir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        fn rand_suffix() -> String {
            let mut b = [0u8; 6];
            getrandom::getrandom(&mut b).unwrap();
            hex::encode(b)
        }
    }

    fn ev(tag: u8, ds: u32, body: Vec<u8>) -> RingEvent {
        RingEvent {
            tag,
            name: oura_protocol::events::event_name(tag),
            timestamp: ds,
            decoded: oura_protocol::events::decode_event_body(tag, &body),
            body,
        }
    }

    #[test]
    fn events_become_dated_samples_with_stable_ids() {
        let (_d, store) = temp_db();
        let now = now_unix() as u32;
        // time_sync anchor: ring ds 1_000_000 == `now`.
        let mut anchor = now.to_le_bytes().to_vec();
        anchor.extend(b"phone");
        let events = vec![
            ev(0x42, 1_000_000, anchor),
            // hrv_event ending 10 minutes before the anchor
            ev(0x5d, 1_000_000 - 6_000, vec![52, 60, 50, 70]),
            ev(0x6f, 1_000_000 - 6_000, vec![1, 96, 98]),
        ];
        store
            .with_raw(|raw| raw.commit_batch("S1", &events, 1_000_001))
            .unwrap();
        assert_eq!(store.refresh_samples().unwrap(), 5);

        let hr = store
            .samples(MetricKind::HeartRate, 0.0, f64::MAX, 100)
            .unwrap();
        assert_eq!(hr.len(), 2);
        assert!((hr[1].ts - (now as f64 - 600.0)).abs() < 1.0, "{hr:?}");
        assert!((hr[0].ts - (now as f64 - 900.0)).abs() < 1.0);
        assert_eq!(store.latest(MetricKind::Spo2).unwrap().unwrap().value, 97.0);

        // Refreshing again rewrites nothing and keeps ids.
        let ids: Vec<i64> = hr.iter().map(|s| s.id).collect();
        assert_eq!(store.rebuild_samples().unwrap(), 0);
        let again: Vec<i64> = store
            .samples(MetricKind::HeartRate, 0.0, f64::MAX, 100)
            .unwrap()
            .iter()
            .map(|s| s.id)
            .collect();
        assert_eq!(ids, again);

        // Connector paging
        let page = store
            .samples_after(0, vec![MetricKind::HeartRate, MetricKind::Hrv], 10)
            .unwrap();
        assert_eq!(page.len(), 4);
        store.set_connector_cursor("nocturne".into(), page[1].id).unwrap();
        assert_eq!(store.connector_cursor("nocturne".into()).unwrap(), page[1].id);
        let rest = store
            .samples_after(page[1].id, vec![MetricKind::HeartRate, MetricKind::Hrv], 10)
            .unwrap();
        assert_eq!(rest.len(), 2);
    }

    #[test]
    fn undated_history_waits_for_an_anchor() {
        let (_d, store) = temp_db();
        // A whole boot downloaded at once with no anchor cannot be dated.
        let events = vec![
            ev(0x5d, 10_000, vec![55, 40]),
            ev(0x5d, 9_000_000, vec![56, 41]),
        ];
        store.with_raw(|raw| raw.commit_batch("S1", &events, 9_000_001)).unwrap();
        assert_eq!(store.refresh_samples().unwrap(), 0);
        // The next sync brings a time_sync anchor for the same boot.
        let now = now_unix() as u32;
        let anchor = ev(0x42, 9_000_100, now.to_le_bytes().to_vec());
        store.with_raw(|raw| raw.commit_batch("S1", &[anchor], 9_000_101)).unwrap();
        assert_eq!(store.refresh_samples().unwrap(), 4);
    }

    #[test]
    fn day_summary_uses_the_sleep_window() {
        let (_d, store) = temp_db();
        let now = now_unix();
        let day_start = (now / 86_400 * 86_400) as f64;
        let anchor_ds: u32 = 5_000_000;
        // Anchor the ring clock so that ds 5_000_000 == day_start + 9 h.
        let anchor_unix = (day_start + 9.0 * 3600.0) as u32;
        let ds_at = |unix: f64| (anchor_ds as f64 + (unix - anchor_unix as f64) * 10.0) as u32;
        let bed_start = ds_at(day_start + 3600.0); // 01:00
        let bed_end = ds_at(day_start + 7.0 * 3600.0); // 07:00
        let mut bed = bed_start.to_le_bytes().to_vec();
        bed.extend(bed_end.to_le_bytes());
        let mut events = vec![
            ev(0x42, anchor_ds, anchor_unix.to_le_bytes().to_vec()),
            ev(0x76, bed_end + 10, bed),
            // night: low HR 50, HRV 60 ; day: HR 90
            ev(0x5d, ds_at(day_start + 4.0 * 3600.0), vec![50, 60, 52, 64]),
            ev(0x5d, ds_at(day_start + 8.0 * 3600.0), vec![90, 20]),
            // 3 active minutes at 4 MET, 1 at 8 MET, 1 resting
            ev(0x50, ds_at(day_start + 8.5 * 3600.0), vec![0, 40, 40, 40, 80, 10]),
        ];
        events.sort_by_key(|e| e.timestamp);
        store.with_raw(|raw| raw.commit_batch("S1", &events, anchor_ds + 1)).unwrap();
        store.refresh_samples().unwrap();
        let s = store.day_summary(day_start, 70.0).unwrap();
        assert_eq!(s.time_in_bed_hours, Some(6.0));
        assert_eq!(s.resting_hr, Some(50.0));
        assert_eq!(s.average_hrv, Some(62.0));
        assert_eq!(s.max_hr, Some(90.0));
        assert_eq!(s.active_minutes, 4);
        assert_eq!(s.met_minutes, 16.0);
        assert_eq!(s.estimated_steps, 3 * 105 + 150);
        let b = store
            .buckets(MetricKind::HeartRate, day_start, day_start + 86_400.0, 3600, 0)
            .unwrap();
        assert_eq!(b.len(), 3); // 03:55, 04:00 and 08:00
        assert_eq!(b[0].min, 50.0);
    }
}
