//! Turning decoded ring events into typed health samples.
//!
//! open_oura decodes each event *body* into JSON (`oura_protocol::events`). This
//! module is the one place that knows which of those fields are user-facing
//! metrics, at what spacing they were measured, and how to place them in time.
//! Everything downstream (charts, daily summaries, export connectors) only sees
//! [`Sample`]s, so supporting a new event or a new ring generation is a change
//! here and nowhere else.
//!
//! Timing conventions follow open_health's validated analysis:
//! * packed 5-minute HR/HRV averages (`hrv_event`) END at the event timestamp
//!   and walk back;
//! * `activity_information` MET bins are one minute apart, walking forward;
//! * a `sleep_phase_data` page burst is written when the ring finishes analysing
//!   a sleep, so the run ends at its last page and walks back 30 s per epoch.

use serde_json::Value;

/// One kind of health measurement. The `id` strings are stable: they are stored in
/// the database and used by export connectors.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum MetricKind {
    /// Heart rate, beats per minute.
    HeartRate,
    /// Heart-rate variability (RMSSD), milliseconds.
    Hrv,
    /// Nocturnal skin temperature, °C.
    SkinTemperature,
    /// Blood-oxygen saturation, percent.
    Spo2,
    /// Breathing rate during sleep, breaths per minute.
    RespiratoryRate,
    /// Metabolic equivalent for one minute (1.0 = at rest).
    ActivityMet,
    /// A detected sleep window; `value` is its length in hours, `end_ts` its end.
    SleepSession,
    /// One 30-second sleep epoch from the ring's own staging: 1 deep, 2 light, 3 REM, 4 awake.
    SleepStage,
    /// Ring battery, percent (recorded at each sync).
    Battery,
}

impl MetricKind {
    pub const ALL: [MetricKind; 9] = [
        MetricKind::HeartRate,
        MetricKind::Hrv,
        MetricKind::SkinTemperature,
        MetricKind::Spo2,
        MetricKind::RespiratoryRate,
        MetricKind::ActivityMet,
        MetricKind::SleepSession,
        MetricKind::SleepStage,
        MetricKind::Battery,
    ];

    pub fn id(self) -> &'static str {
        match self {
            MetricKind::HeartRate => "heart_rate",
            MetricKind::Hrv => "hrv",
            MetricKind::SkinTemperature => "skin_temperature",
            MetricKind::Spo2 => "spo2",
            MetricKind::RespiratoryRate => "respiratory_rate",
            MetricKind::ActivityMet => "activity_met",
            MetricKind::SleepSession => "sleep_session",
            MetricKind::SleepStage => "sleep_stage",
            MetricKind::Battery => "battery",
        }
    }

    pub fn from_id(id: &str) -> Option<MetricKind> {
        MetricKind::ALL.into_iter().find(|k| k.id() == id)
    }

    pub fn unit(self) -> &'static str {
        match self {
            MetricKind::HeartRate => "bpm",
            MetricKind::Hrv => "ms",
            MetricKind::SkinTemperature => "°C",
            MetricKind::Spo2 | MetricKind::Battery => "%",
            MetricKind::RespiratoryRate => "br/min",
            MetricKind::ActivityMet => "MET",
            MetricKind::SleepSession => "h",
            MetricKind::SleepStage => "stage",
        }
    }
}

/// Stable string id of a metric kind (what the database and connectors use).
#[uniffi::export]
pub fn metric_kind_id(kind: MetricKind) -> String {
    kind.id().to_string()
}

/// Display unit of a metric kind.
#[uniffi::export]
pub fn metric_kind_unit(kind: MetricKind) -> String {
    kind.unit().to_string()
}

/// A dated health sample, as stored and as handed to Swift.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Sample {
    /// Database row id. Monotonic within one database.
    pub id: i64,
    pub kind: MetricKind,
    /// Start (or instant) of the measurement, unix seconds UTC.
    pub ts: f64,
    /// End of the measurement for interval kinds (sleep), unix seconds UTC.
    pub end_ts: Option<f64>,
    pub value: f64,
    /// The `events` row this sample was derived from, so exports can build stable
    /// de-duplication ids and anything can be traced back to raw bytes.
    pub event_id: i64,
}

/// A sample still in ring time (deciseconds of the ring's boot counter).
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct RingPoint {
    pub kind: MetricKind,
    pub ds: i64,
    pub end_ds: Option<i64>,
    pub value: f64,
}

fn point(kind: MetricKind, ds: i64, value: f64) -> RingPoint {
    RingPoint {
        kind,
        ds,
        end_ds: None,
        value,
    }
}

fn numbers(v: &Value, key: &str) -> Vec<f64> {
    v[key]
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_f64).collect())
        .unwrap_or_default()
}

fn median(mut xs: Vec<f64>) -> Option<f64> {
    if xs.is_empty() {
        return None;
    }
    xs.sort_by(|a, b| a.total_cmp(b));
    let n = xs.len();
    Some(if n % 2 == 1 {
        xs[n / 2]
    } else {
        (xs[n / 2 - 1] + xs[n / 2]) / 2.0
    })
}

fn mean(xs: &[f64]) -> Option<f64> {
    (!xs.is_empty()).then(|| xs.iter().sum::<f64>() / xs.len() as f64)
}

/// Seconds-to-decisecond helper.
const DS_PER_S: i64 = 10;
/// Spacing of `activity_information` MET bins.
const MET_STEP_DS: i64 = 60 * DS_PER_S;
/// One ring sleep-staging epoch.
pub(crate) const STAGE_EPOCH_DS: i64 = 30 * DS_PER_S;

/// Metric points carried by a single decoded event. Events whose meaning spans
/// several records (sleep-stage page bursts) are handled by [`SleepStageAssembler`].
pub(crate) fn points_for_event(tag: u8, ds: i64, decoded: &Value) -> Vec<RingPoint> {
    let mut out = Vec::new();
    match tag {
        // hrv_event: packed (avg HR, avg RMSSD) per `interval_min`, ending at `ds`.
        0x5d => {
            let step = decoded["interval_min"].as_i64().unwrap_or(5).max(1) * 60 * DS_PER_S;
            for (key, kind, range) in [
                ("hr_bpm", MetricKind::HeartRate, 25.0..=230.0),
                ("rmssd_ms", MetricKind::Hrv, 1.0..=250.0),
            ] {
                let vals = numbers(decoded, key);
                let n = vals.len() as i64;
                for (i, v) in vals.into_iter().enumerate() {
                    if range.contains(&v) {
                        out.push(point(kind, ds - (n - 1 - i as i64) * step, v));
                    }
                }
            }
        }
        // green_ibi_quality_event (Ring 5): only beats the firmware's quality gate
        // accepted land in `hr_bpm`. One median per record keeps the series light.
        0x80 => {
            let accepted: Vec<f64> = numbers(decoded, "hr_bpm")
                .into_iter()
                .filter(|b| (30.0..=240.0).contains(b))
                .collect();
            if accepted.len() >= 3 {
                if let Some(m) = median(accepted) {
                    out.push(point(MetricKind::HeartRate, ds, m.round()));
                }
            }
        }
        // sleep_period_information_2: per-window sleep sample. Breathing is only
        // meaningful while asleep (sleep_state 1).
        0x6a => {
            if decoded["sleep_state"].as_i64() == Some(1) {
                if let Some(b) = decoded["breath"].as_f64().filter(|b| (4.0..=40.0).contains(b)) {
                    out.push(point(MetricKind::RespiratoryRate, ds, b));
                }
            }
        }
        // sleep_temp_event: the calibrated nocturnal skin-temperature stream. The
        // generic temp_event mixes device/ambient channels, so it is not charted.
        0x75 => {
            let temps: Vec<f64> = numbers(decoded, "temps_c")
                .into_iter()
                .filter(|c| (20.0..=42.0).contains(c))
                .collect();
            if let Some(m) = mean(&temps) {
                out.push(point(MetricKind::SkinTemperature, ds, (m * 100.0).round() / 100.0));
            }
        }
        // spo2_event: 1 Hz SpO2 percentages; one mean per record.
        0x6f => {
            let vals: Vec<f64> = numbers(decoded, "spo2_percent")
                .into_iter()
                .filter(|p| (70.0..=100.0).contains(p))
                .collect();
            if let Some(m) = mean(&vals) {
                out.push(point(MetricKind::Spo2, ds, (m * 10.0).round() / 10.0));
            }
        }
        // activity_information: one MET value per minute, walking forward.
        0x50 => {
            for (i, met) in numbers(decoded, "met").into_iter().enumerate() {
                if (0.0..=25.0).contains(&met) {
                    out.push(point(MetricKind::ActivityMet, ds + i as i64 * MET_STEP_DS, met));
                }
            }
        }
        // bedtime_period: the ring's detected sleep window, in ring time.
        0x76 => {
            if let (Some(s), Some(e)) = (
                decoded["bedtime_start_ds"].as_i64(),
                decoded["bedtime_end_ds"].as_i64(),
            ) {
                if e > s && e - s <= 20 * 3600 * DS_PER_S {
                    out.push(RingPoint {
                        kind: MetricKind::SleepSession,
                        ds: s,
                        end_ds: Some(e),
                        value: ((e - s) as f64 / 36000.0 * 100.0).round() / 100.0,
                    });
                }
            }
        }
        _ => {}
    }
    out
}

/// Assembles `sleep_phase_data` (`0x5a`) page bursts into dated stage epochs.
///
/// Pages are numbered by their `header` byte, counting up from zero within one
/// analysed sleep. A page carries only the moment the ring emitted it, so a run
/// ends at its last page and walks back 30 s per epoch.
#[derive(Default)]
pub(crate) struct SleepStageAssembler {
    runs: Vec<StageRun>,
    previous_page: i64,
}

pub(crate) struct StageRun {
    pub end_ds: i64,
    /// Event id of the last page, used as the samples' provenance.
    pub event_id: i64,
    pub codes: Vec<u8>,
}

impl SleepStageAssembler {
    pub fn new() -> Self {
        Self {
            runs: Vec::new(),
            previous_page: -1,
        }
    }

    pub fn push(&mut self, event_id: i64, ds: i64, decoded: &Value) {
        let Some(page) = decoded["header"].as_i64() else {
            return;
        };
        let codes: Vec<u8> = decoded["phases"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|p| match p.as_str() {
                        Some("deep") => 1,
                        Some("light") => 2,
                        Some("rem") => 3,
                        Some("awake") => 4,
                        _ => 0,
                    })
                    .collect()
            })
            .unwrap_or_default();
        match self.runs.last_mut() {
            Some(run) if page == self.previous_page + 1 => {
                run.end_ds = ds;
                run.event_id = event_id;
                run.codes.extend(codes);
            }
            _ => self.runs.push(StageRun {
                end_ds: ds,
                event_id,
                codes,
            }),
        }
        self.previous_page = page;
    }

    /// `(event_id, point)` for every staged epoch. Unknown (0) epochs are dropped:
    /// they mean "not analysed", not "awake".
    pub fn finish(self) -> Vec<(i64, RingPoint)> {
        let mut out = Vec::new();
        for run in self.runs {
            let start = run.end_ds - run.codes.len() as i64 * STAGE_EPOCH_DS;
            for (i, code) in run.codes.iter().enumerate() {
                if *code == 0 {
                    continue;
                }
                let ds = start + i as i64 * STAGE_EPOCH_DS;
                out.push((
                    run.event_id,
                    RingPoint {
                        kind: MetricKind::SleepStage,
                        ds,
                        end_ds: Some(ds + STAGE_EPOCH_DS),
                        value: *code as f64,
                    },
                ));
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use oura_protocol::events::decode_event_body;

    #[test]
    fn hrv_event_walks_back_from_packet_time() {
        // 3 samples: (60 bpm, 40 ms), (58, 45), (0 = no estimate, 0)
        let v = decode_event_body(0x5d, &[60, 40, 58, 45, 0, 0]).unwrap();
        let pts = points_for_event(0x5d, 100_000, &v);
        let hr: Vec<_> = pts.iter().filter(|p| p.kind == MetricKind::HeartRate).collect();
        assert_eq!(hr.len(), 2);
        assert_eq!(hr[0].ds, 100_000 - 2 * 3000);
        assert_eq!(hr[1].ds, 100_000 - 3000);
        assert_eq!(hr[1].value, 58.0);
        assert_eq!(pts.iter().filter(|p| p.kind == MetricKind::Hrv).count(), 2);
    }

    #[test]
    fn met_bins_walk_forward_one_minute() {
        let v = decode_event_body(0x50, &[0x00, 10, 25, 0x90]).unwrap();
        let pts = points_for_event(0x50, 5_000, &v);
        assert_eq!(pts.len(), 3);
        assert_eq!(pts[1].ds, 5_600);
        assert_eq!(pts[1].value, 2.5);
        assert_eq!(pts[2].value, 16.0);
    }

    #[test]
    fn spo2_and_temperature() {
        let v = decode_event_body(0x6f, &[0x01, 97, 98, 0xff]).unwrap();
        assert_eq!(points_for_event(0x6f, 1, &v)[0].value, 97.5);
        // 34.50 °C and 34.70 °C as centi-degrees LE
        let v = decode_event_body(0x75, &[0x7a, 0x0d, 0x8e, 0x0d]).unwrap();
        assert_eq!(points_for_event(0x75, 1, &v)[0].value, 34.6);
    }

    #[test]
    fn bedtime_period_becomes_a_session() {
        let mut body = 10_000u32.to_le_bytes().to_vec();
        body.extend(298_000u32.to_le_bytes()); // 8 h later
        let v = decode_event_body(0x76, &body).unwrap();
        let p = &points_for_event(0x76, 300_000, &v)[0];
        assert_eq!(p.kind, MetricKind::SleepSession);
        assert_eq!((p.ds, p.end_ds), (10_000, Some(298_000)));
        assert_eq!(p.value, 8.0);
    }

    #[test]
    fn sleep_stage_pages_end_at_last_page() {
        let mut asm = SleepStageAssembler::new();
        // page 0: deep, light, rem, awake ; page 1: light x4
        asm.push(1, 50_000, &decode_event_body(0x5a, &[0, 0b00_01_10_11]).unwrap());
        asm.push(2, 50_010, &decode_event_body(0x5a, &[1, 0b01_01_01_01]).unwrap());
        let pts = asm.finish();
        assert_eq!(pts.len(), 8);
        assert_eq!(pts[0].1.ds, 50_010 - 8 * STAGE_EPOCH_DS);
        assert_eq!(pts[0].1.value, 1.0);
        assert_eq!(pts[3].1.value, 4.0);
        assert!(pts.iter().all(|(id, _)| *id == 2));
    }

    #[test]
    fn kind_ids_round_trip() {
        for k in MetricKind::ALL {
            assert_eq!(MetricKind::from_id(k.id()), Some(k));
        }
    }
}
