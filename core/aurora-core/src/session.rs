//! One connected ring.
//!
//! [`RingSession`] wraps open_oura's `OuraClient` over the Swift-provided BLE pipe
//! and exposes the handful of flows the app needs: identify, check the key, pair a
//! factory-reset ring, full sync into an [`AuroraStore`], battery, latest values
//! and live heart rate. Calls are serialised: the ring protocol is strictly
//! request/response, so two overlapping requests would steal each other's replies.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use oura_link::transport::{transact_until, Transport};
use oura_link::OuraClient;
use oura_protocol::auth::{encrypt_nonce, AuthResult};
use oura_protocol::protocol::{self, feature, feature_mode, Packet};

use crate::store::AuroraStore;
use crate::transport::{FfiTransport, RingLink};
use crate::{parse_key, CoreError};

/// Identity of a ring, readable without authentication.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct RingInfo {
    pub serial: String,
    /// e.g. `BLB_03` (Gen 3), `..._05` (Ring 5).
    pub hardware_id: String,
    pub firmware_version: String,
    pub api_version: String,
    pub bootloader_version: String,
    pub bt_stack_version: String,
    pub mac: String,
    /// Whether the hardware id marks a Ring 5 (open_oura's own test).
    pub is_ring5: bool,
}

/// What the ring says about an auth key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum KeyStatus {
    /// The key matches: full access.
    Accepted,
    /// The ring has a different key installed (e.g. still onboarded to the Oura app).
    WrongKey,
    /// The ring is factory-reset and has no key: it can be paired.
    FactoryReset,
    /// The ring is bound to another onboarding.
    OtherDevice,
    /// The ring answered with an unknown state byte.
    Unknown,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BatteryStatus {
    pub percent: u8,
    /// The ring's charging-progress byte (non-zero while on the charger).
    pub charging_progress: u8,
    pub charging_recommended: bool,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct LatestValues {
    pub heart_rate: Option<u16>,
    pub spo2: Option<u8>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct FeatureState {
    pub name: String,
    /// off / automatic / requested / connected_live
    pub mode: String,
    /// idle / scanning / measuring / postprocessing
    pub state: String,
    pub enabled: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum SyncStage {
    Authenticating,
    PreparingRing,
    Downloading,
    Processing,
    Done,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct SyncReport {
    pub serial: String,
    /// Events the ring sent this sync.
    pub events_received: u32,
    /// Of those, events not already in the database.
    pub new_events: u32,
    /// Samples written or re-dated.
    pub samples_written: u32,
    pub battery_percent: Option<u8>,
    pub next_cursor: u32,
    /// Non-fatal problems (e.g. the clock could not be aligned).
    pub warnings: Vec<String>,
}

/// Progress callbacks during [`RingSession::sync`]. Called on a background thread.
#[uniffi::export(callback_interface)]
pub trait SyncListener: Send + Sync {
    fn on_stage(&self, stage: SyncStage);
    /// After every downloaded batch: events so far and the ring's bytes remaining.
    fn on_progress(&self, events_synced: u32, bytes_left: u32);
}

/// Live heart-rate callbacks. Called on a background thread.
#[uniffi::export(callback_interface)]
pub trait HeartRateListener: Send + Sync {
    fn on_heart_rate(&self, bpm: u16, ibi_ms: u16);
}

#[derive(uniffi::Object)]
pub struct RingSession {
    client: OuraClient<FfiTransport>,
    /// Serialises protocol operations (see module docs).
    op: tokio::sync::Mutex<()>,
    /// Set by `stop_live_heart_rate` to end a live stream early.
    stop_live: AtomicBool,
}

/// A live heart-rate packet: `0x2f` ext `0x28` for the daytime-HR feature, with a
/// 12-bit IBI and a 4-bit validity nibble (same layout open_oura's CLI uses).
/// Parsed per packet, not per notification, because Ring 5 packs several packets
/// into one notification.
pub(crate) fn parse_live_hr(p: &Packet) -> Option<(u16, u16)> {
    if p.tag != 0x2f || p.payload.len() < 8 || p.payload[0] != 0x28 || p.payload[1] != feature::DAYTIME_HR {
        return None;
    }
    let (lo, hi) = (p.payload[6], p.payload[7]);
    if (hi >> 4) & 0x0f != 1 {
        return None;
    }
    let ibi = (((hi & 0x0f) as u16) << 8) | lo as u16;
    (300..=2000).contains(&ibi).then(|| (60_000 / ibi, ibi))
}

fn mode_name(mode: u8) -> &'static str {
    match mode {
        0 => "off",
        1 => "automatic",
        2 => "requested",
        3 => "connected_live",
        _ => "unknown",
    }
}

fn state_name(state: u8) -> &'static str {
    match state {
        0 => "idle",
        1 => "scanning",
        2 => "measuring",
        3 => "postprocessing",
        _ => "unknown",
    }
}

impl RingSession {
    async fn ext_request(&self, req: &[u8], ext: u8) -> Result<Vec<Packet>, CoreError> {
        let frames = transact_until(
            self.client.transport(),
            req,
            oura_link::client::DEFAULT_QUIET,
            |f| Packet::parse_many(f).iter().any(|p| p.ext_tag() == Some(ext)),
        )
        .await?;
        Ok(frames.iter().flat_map(|f| Packet::parse_many(f)).collect())
    }

    async fn key_status_inner(&self, key: &[u8; 16]) -> Result<KeyStatus, CoreError> {
        let packets = self.ext_request(&protocol::req_auth_nonce(), 0x2c).await?;
        let nonce = packets
            .iter()
            .find(|p| p.ext_tag() == Some(0x2c) && p.payload.len() > 1)
            .map(|p| p.payload[1..].to_vec())
            .ok_or_else(|| CoreError::Ring {
                message: "the ring did not send an auth challenge".into(),
            })?;
        let encrypted = encrypt_nonce(key, &nonce);
        let packets = self
            .ext_request(&protocol::req_authenticate(&encrypted), 0x2e)
            .await?;
        let state = packets
            .iter()
            .find(|p| p.ext_tag() == Some(0x2e))
            .and_then(|p| p.payload.get(1).copied())
            .ok_or_else(|| CoreError::Ring {
                message: "the ring did not answer the auth response".into(),
            })?;
        Ok(match AuthResult::from(state) {
            AuthResult::Success => KeyStatus::Accepted,
            AuthResult::AuthenticationError => KeyStatus::WrongKey,
            AuthResult::InFactoryReset => KeyStatus::FactoryReset,
            AuthResult::NotOriginalOnboardedDevice => KeyStatus::OtherDevice,
            AuthResult::Unknown(_) => KeyStatus::Unknown,
        })
    }

    async fn authenticate(&self, key: &[u8; 16]) -> Result<(), CoreError> {
        match self.key_status_inner(key).await? {
            KeyStatus::Accepted => Ok(()),
            KeyStatus::WrongKey => Err(CoreError::Auth {
                message: "The ring rejected this key. It has a different key installed \
                          (for example it is still set up in the Oura app)."
                    .into(),
            }),
            KeyStatus::FactoryReset => Err(CoreError::Auth {
                message: "The ring is factory-reset and has no key yet. Pair it first.".into(),
            }),
            KeyStatus::OtherDevice => Err(CoreError::Auth {
                message: "The ring is bound to another phone's onboarding.".into(),
            }),
            KeyStatus::Unknown => Err(CoreError::Auth {
                message: "The ring answered the key check with an unknown state.".into(),
            }),
        }
    }

    async fn info_inner(&self) -> Result<RingInfo, CoreError> {
        let fw = self.client.firmware().await?;
        let serial = self.client.serial().await.unwrap_or_default();
        let hardware_id = self.client.hardware_id().await.unwrap_or_default();
        Ok(RingInfo {
            is_ring5: hardware_id.rsplit('_').next() == Some("05"),
            serial,
            hardware_id,
            firmware_version: fw.firmware_version,
            api_version: fw.api_version,
            bootloader_version: fw.bootloader_version,
            bt_stack_version: fw.bt_stack_version,
            mac: fw.mac,
        })
    }

    async fn enable_measurements_inner(&self) -> Vec<String> {
        let mut warnings = Vec::new();
        for (label, id) in [("heart rate", feature::DAYTIME_HR), ("SpO2", feature::SPO2)] {
            if let Err(e) = self.client.set_feature_mode(id, feature_mode::AUTOMATIC).await {
                warnings.push(format!("Could not enable {label}: {e}"));
            }
        }
        warnings
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl RingSession {
    /// Wrap a connected BLE link. Swift must forward every notification from the
    /// ring's notify characteristics to [`Self::push_notification`].
    #[uniffi::constructor]
    pub fn new(link: Box<dyn RingLink>) -> Arc<Self> {
        Arc::new(Self {
            client: OuraClient::new(FfiTransport::new(link)),
            op: tokio::sync::Mutex::new(()),
            stop_live: AtomicBool::new(false),
        })
    }

    /// Deliver one inbound BLE notification. Cheap and non-blocking.
    pub fn push_notification(&self, data: Vec<u8>) {
        self.client.transport().push(data);
    }

    /// Firmware, serial and hardware id. No key needed.
    pub async fn info(&self) -> Result<RingInfo, CoreError> {
        let _g = self.op.lock().await;
        self.info_inner().await
    }

    /// Ask the ring whether `key_hex` is its key, without failing on "no".
    pub async fn key_status(&self, key_hex: String) -> Result<KeyStatus, CoreError> {
        let key = parse_key(&key_hex)?;
        let _g = self.op.lock().await;
        self.key_status_inner(&key).await
    }

    /// Install `key_hex` on a factory-reset ring, verify it, and switch on the
    /// automatic heart-rate and SpO2 measurements the Oura app normally enables at
    /// onboarding. Returns non-fatal warnings.
    ///
    /// Save the key (Keychain) BEFORE calling this: once installed, it is the only
    /// way back into the ring short of another factory reset.
    pub async fn pair(&self, key_hex: String) -> Result<Vec<String>, CoreError> {
        let key = parse_key(&key_hex)?;
        let _g = self.op.lock().await;
        self.client.set_auth_key(&key).await.map_err(|e| CoreError::Auth {
            message: format!(
                "The ring refused the new key ({e}). Only a factory-reset ring accepts one."
            ),
        })?;
        self.authenticate(&key).await?;
        Ok(self.enable_measurements_inner().await)
    }

    /// Re-enable automatic heart rate and SpO2 measurement.
    pub async fn enable_measurements(&self, key_hex: String) -> Result<Vec<String>, CoreError> {
        let key = parse_key(&key_hex)?;
        let _g = self.op.lock().await;
        self.authenticate(&key).await?;
        Ok(self.enable_measurements_inner().await)
    }

    pub async fn features(&self, key_hex: String) -> Result<Vec<FeatureState>, CoreError> {
        let key = parse_key(&key_hex)?;
        let _g = self.op.lock().await;
        self.authenticate(&key).await?;
        let mut out = Vec::new();
        for (name, id) in [
            ("Daytime heart rate", feature::DAYTIME_HR),
            ("Exercise heart rate", feature::EXERCISE_HR),
            ("SpO2", feature::SPO2),
            ("Resting heart rate", feature::RESTING_HR),
        ] {
            if let Ok(s) = self.client.feature_status(id).await {
                out.push(FeatureState {
                    name: name.into(),
                    mode: mode_name(s.mode).into(),
                    state: state_name(s.state).into(),
                    enabled: s.mode != feature_mode::OFF,
                });
            }
        }
        Ok(out)
    }

    pub async fn battery(&self, key_hex: String) -> Result<BatteryStatus, CoreError> {
        let key = parse_key(&key_hex)?;
        let _g = self.op.lock().await;
        self.authenticate(&key).await?;
        let b = self.client.battery().await?;
        Ok(BatteryStatus {
            percent: b.percent,
            charging_progress: b.charging_progress,
            charging_recommended: b.charging_recommended != 0,
        })
    }

    /// The ring's most recent automatic HR and SpO2 readings (ring must be worn).
    pub async fn latest_values(&self, key_hex: String) -> Result<LatestValues, CoreError> {
        let key = parse_key(&key_hex)?;
        let _g = self.op.lock().await;
        self.authenticate(&key).await?;
        let hr = self.client.feature_latest(feature::DAYTIME_HR).await.ok();
        let spo2 = self.client.feature_latest(feature::SPO2).await.ok();
        Ok(LatestValues {
            heart_rate: hr.and_then(|v| v.bpm),
            spo2: spo2.and_then(|v| v.spo2_percent),
        })
    }

    /// Stream live heart rate for up to `seconds` (ring must be worn), until
    /// [`Self::stop_live_heart_rate`]. Puts the ring's heart-rate feature in its
    /// connected-live mode and restores automatic measurement afterwards. Returns
    /// the number of valid beats received. While no beats arrive, the ring's latest
    /// automatic reading is reported every few seconds with `ibi_ms == 0`.
    pub async fn live_heart_rate(
        &self,
        key_hex: String,
        seconds: u32,
        listener: Box<dyn HeartRateListener>,
    ) -> Result<u32, CoreError> {
        let key = parse_key(&key_hex)?;
        let _g = self.op.lock().await;
        self.authenticate(&key).await?;
        self.stop_live.store(false, Ordering::SeqCst);
        let transport = self.client.transport();
        let mut rx = transport.subscribe();
        transport
            .write(&protocol::req_set_feature_mode(feature::DAYTIME_HR, feature_mode::CONNECTED_LIVE))
            .await?;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds.clamp(5, 600) as u64);
        let mut beats = 0u32;
        let mut last_beat = tokio::time::Instant::now();
        let mut last_poll = tokio::time::Instant::now();
        while !self.stop_live.load(Ordering::SeqCst) {
            // No live beats for a while (ring still settling, loose fit, or a firmware
            // that does not stream): fall back to the ring's latest automatic reading,
            // reported with ibi_ms = 0 so the UI can label it as such.
            let now = tokio::time::Instant::now();
            if now - last_beat > Duration::from_secs(6) && now - last_poll > Duration::from_secs(5) {
                last_poll = now;
                if let Ok(v) = self.client.feature_latest(feature::DAYTIME_HR).await {
                    if let Some(bpm) = v.bpm.filter(|b| (30..=220).contains(b)) {
                        listener.on_heart_rate(bpm, 0);
                    }
                }
            }
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            match tokio::time::timeout(remaining.min(Duration::from_millis(500)), rx.recv()).await {
                Ok(Ok(frame)) => {
                    for p in Packet::parse_many(&frame) {
                        if let Some((bpm, ibi)) = parse_live_hr(&p) {
                            beats += 1;
                            last_beat = tokio::time::Instant::now();
                            listener.on_heart_rate(bpm, ibi);
                        }
                    }
                }
                Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => continue,
                Ok(Err(_)) => break, // link gone
                Err(_) => continue,  // no frame this half-second; check stop + deadline
            }
        }
        let _ = transport
            .write(&protocol::req_set_feature_mode(feature::DAYTIME_HR, feature_mode::AUTOMATIC))
            .await;
        Ok(beats)
    }

    /// End a running [`Self::live_heart_rate`] stream within half a second.
    pub fn stop_live_heart_rate(&self) {
        self.stop_live.store(true, Ordering::SeqCst);
    }

    /// Full sync: authenticate, run the Ring 5 app-style setup, align the ring
    /// clock (this is what dates the history), ask the ring to finish its sleep
    /// analysis, download every new history event into `store` (committing the
    /// cursor batch by batch, so an interrupted sync resumes), then derive samples.
    pub async fn sync(
        &self,
        key_hex: String,
        store: Arc<AuroraStore>,
        listener: Box<dyn SyncListener>,
    ) -> Result<SyncReport, CoreError> {
        let key = parse_key(&key_hex)?;
        let _g = self.op.lock().await;
        let mut warnings = Vec::new();

        listener.on_stage(SyncStage::Authenticating);
        self.authenticate(&key).await?;

        listener.on_stage(SyncStage::PreparingRing);
        if let Err(e) = self.client.setup_app_stream().await {
            warnings.push(format!("Ring stream setup incomplete: {e}"));
        }
        if self.client.sync_time_app().await.is_err() {
            if let Err(e) = self.client.sync_time().await {
                warnings.push(format!(
                    "Could not align the ring clock ({e}); the newest data may stay undated until the next sync."
                ));
            }
        }
        let _ = self.client.check_sleep_analysis(false).await;

        let info = self.client.firmware().await.ok();
        let serial = self
            .client
            .serial()
            .await
            .unwrap_or_else(|_| "unknown".into());
        let hardware = self.client.hardware_id().await.ok();
        store.with_raw(|raw| raw.upsert_device(&serial, hardware.as_deref(), info.as_ref()))?;

        let battery = self.client.battery().await.ok();
        if let Some(b) = &battery {
            store.record_battery(&serial, b.percent)?;
        }

        listener.on_stage(SyncStage::Downloading);
        let cursor = store.with_raw(|raw| raw.cursor(&serial))?;
        // std Mutex (not RefCell) so the drain future stays Send.
        let pending = Mutex::new(Vec::new());
        let inserted = Mutex::new(0u32);
        let store_err: Mutex<Option<CoreError>> = Mutex::new(None);
        let outcome = self
            .client
            .drain_events(
                cursor,
                |ev| {
                    pending.lock().unwrap().push(ev.clone());
                    true
                },
                |p| {
                    let events = std::mem::take(&mut *pending.lock().unwrap());
                    match store.with_raw(|raw| raw.commit_batch(&serial, &events, p.next_cursor)) {
                        Ok(n) => *inserted.lock().unwrap() += n,
                        Err(e) => {
                            *store_err.lock().unwrap() = Some(e);
                            return false;
                        }
                    }
                    listener.on_progress(p.events_synced, p.bytes_left);
                    true
                },
            )
            .await;
        if let Some(e) = store_err.into_inner().unwrap() {
            return Err(e);
        }
        let outcome = outcome?;
        store.with_raw(|raw| raw.set_cursor(&serial, outcome.next_cursor))?;

        listener.on_stage(SyncStage::Processing);
        let samples_written = store.refresh_samples()?;

        listener.on_stage(SyncStage::Done);
        Ok(SyncReport {
            serial,
            events_received: outcome.events_synced,
            new_events: inserted.into_inner().unwrap(),
            samples_written,
            battery_percent: battery.map(|b| b.percent),
            next_cursor: outcome.next_cursor,
            warnings,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::tests::{ScriptedLink, ScriptedRing};

    const KEY: &str = "4431967d8bacc2659743142b68391d9a";

    fn ring_with_auth() -> (Arc<ScriptedRing>, Arc<RingSession>) {
        let ring = ScriptedRing::new();
        // Nonce challenge and the known-answer ciphertext from open_oura's auth test.
        ring.on("2f012b", &["2f102c0e2d6a0a08c99b4365f458e6e97382"]);
        ring.on(
            "2f112da38a8772d3acb6db5c2b516dd56987c8",
            &["2f022e00"],
        );
        let session = RingSession::new(Box::new(ScriptedLink(ring.clone())));
        *ring.sink.lock().unwrap() = Some(session.clone());
        (ring, session)
    }

    #[tokio::test]
    async fn key_status_accepts_the_right_key() {
        let (_ring, s) = ring_with_auth();
        assert_eq!(s.key_status(KEY.into()).await.unwrap(), KeyStatus::Accepted);
    }

    #[tokio::test]
    async fn wrong_key_is_reported_not_thrown() {
        let (ring, s) = ring_with_auth();
        // Any other ciphertext gets "authentication error".
        let other = encrypt_nonce(&[0u8; 16], &hex::decode("0e2d6a0a08c99b4365f458e6e97382").unwrap());
        ring.on(&hex::encode(protocol::req_authenticate(&other)), &["2f022e01"]);
        assert_eq!(
            s.key_status(hex::encode([0u8; 16])).await.unwrap(),
            KeyStatus::WrongKey
        );
        assert!(matches!(
            s.battery(hex::encode([0u8; 16])).await,
            Err(CoreError::Auth { .. })
        ));
    }

    #[tokio::test]
    async fn live_heart_rate_parses_packed_notifications() {
        struct Beats(Arc<Mutex<Vec<u16>>>);
        impl HeartRateListener for Beats {
            fn on_heart_rate(&self, bpm: u16, _ibi_ms: u16) {
                self.0.lock().unwrap().push(bpm);
            }
        }
        let (ring, s) = ring_with_auth();
        let live = hex::encode(protocol::req_set_feature_mode(feature::DAYTIME_HR, feature_mode::CONNECTED_LIVE));
        // Two packets in one notification (Ring 5 packs them): IBI 1000 ms valid,
        // IBI 750 ms valid; then one invalid beat (validity nibble 2).
        ring.on(&live, &["2f08280200000000e8132f08280200000000ee12", "2f08280200000000e823"]);
        let got = Arc::new(Mutex::new(Vec::new()));
        let s2 = s.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            s2.stop_live_heart_rate();
        });
        let n = s
            .live_heart_rate(KEY.into(), 30, Box::new(Beats(got.clone())))
            .await
            .unwrap();
        assert_eq!(n, 2);
        assert_eq!(*got.lock().unwrap(), vec![60, 80]);
    }

    #[tokio::test]
    async fn battery_after_auth() {
        let (ring, s) = ring_with_auth();
        ring.on("0c00", &["0d034b0000"]);
        let b = s.battery(KEY.into()).await.unwrap();
        assert_eq!(b.percent, 75);
    }
}
