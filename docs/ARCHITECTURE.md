# Architecture

## Layers

| Layer | Where | Owns |
| --- | --- | --- |
| Bluetooth | `ios/Aurora/Ring/RingBluetooth.swift` | Scanning, connecting, subscribing to every notify characteristic of the Oura service (`98ed0001-…`), writing request frames to `98ed0002-…`. Remembers the ring's peripheral id. |
| Ring session | `core/aurora-core/src/session.rs` | open_oura's `OuraClient` over the Swift link: key check, pairing, Ring 5 app-stream setup, time sync, sleep-analysis trigger, history drain, battery, live HR, measurement switches. Operations are serialised. |
| Transport bridge | `core/aurora-core/src/transport.rs` | `RingLink` (Swift → implements `write`) and `push_notification` (Swift → Rust). Implements open_oura's `Transport` trait. |
| Store | `core/aurora-core/src/store.rs` | One SQLite file: open_oura's `oura-store` tables (raw events + cursor) plus `samples` and `connector_state`. Day summaries and chart buckets. |
| Metrics | `core/aurora-core/src/metrics.rs` | Event → typed `Sample` mapping and timing conventions. The only place that knows what a field means. |
| Ring clock | `core/aurora-core/src/ring_time.rs` | Vendored from open_health: ring decisecond counter → UTC using `time_sync` / `rtc_beacon` anchors, handling reboots and stalls. Undatable samples wait for an anchor instead of being misplaced. |
| UI | `ios/Aurora/UI` | SwiftUI + Swift Charts. |
| Connectors | `ios/Aurora/Connectors` | Export targets. |

## A sync

1. `RingBluetooth.connect()` finds the ring and returns a `RingSession`.
2. `RingSession.sync(key, store, listener)`:
   authenticate → Ring 5 stream/category registration → app-style time sync (this
   writes the anchor that dates history) → ask the ring to finish its sleep analysis →
   battery → drain history from the stored cursor, committing each batch with its
   cursor in one transaction (an interrupted sync resumes) → derive samples.
3. `ConnectorManager.exportAll()` sends new samples to every enabled connector.

Sync runs on app launch / foreground when the last one is older than 15 minutes, on
pull-to-refresh, and opportunistically as a background refresh task.

## Samples

`samples(id, kind, ts, end_ts, value, event_id, ord)` with `UNIQUE(event_id, kind, ord)`.
Re-deriving updates rows in place, so ids are stable and connectors can page by id.
Events captured in the last three days are re-derived on every refresh so a late time
anchor re-dates them.

| Kind | Source event | Timing |
| --- | --- | --- |
| `heart_rate` | `hrv_event` (5-min avg), `green_ibi_quality_event` (Ring 5, median of quality-gated beats) | hrv_event samples end at the event and walk back |
| `hrv` | `hrv_event` RMSSD | same |
| `skin_temperature` | `sleep_temp_event` | at event |
| `spo2` | `spo2_event` (mean of 1 Hz values) | at event |
| `respiratory_rate` | `sleep_period_information_2` while asleep | at event |
| `activity_met` | `activity_information` | 1 per minute, walking forward |
| `sleep_session` | `bedtime_period` | start/end from the event body |
| `sleep_stage` | `sleep_phase_data` page bursts | run ends at last page, 30 s epochs |
| `battery` | battery read at each sync | sync time |

## Updating open_oura

The crates are pinned by git revision in `core/aurora-core/Cargo.toml`. To pick up
protocol fixes: bump the `rev`, run `cargo test -p aurora-core`, then
`ios/build-core.sh`. Raw events are stored losslessly, so new decoders apply to old
data after *Settings › Re-process all data*.
