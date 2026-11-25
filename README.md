# AuroraFarming · Aurora

Open-source iOS app that reads your **Oura Ring** directly over Bluetooth: no Oura
account, no cloud. Everything is stored on your iPhone, and can be forwarded to
diabetes tools (first: [Nocturne](https://getnocturne.dev); planned: Trio) to help
automate blood-sugar control.

The ring protocol comes from [open_oura](https://github.com/Th0rgal/open_oura)
(MIT), which reverse-engineered it and verified it on a Ring 3 and a **Ring 5**. Aurora
links open_oura's Rust crates directly, so it speaks exactly the protocol they tested.

## What you get

| Screen | Shows |
| --- | --- |
| **Today** | Last night's sleep window (and stages when the ring staged it), resting HR, HRV, skin-temperature deviation, breathing rate, SpO2, active minutes, active energy and estimated steps, today's heart-rate curve |
| **Trends** | Day / week / month / 3-month charts for every metric, with detail pages |
| **Ring** | Battery, firmware, sync progress, live beat-to-beat heart rate, automatic-measurement switches |
| **Share** | Export connectors (Nocturne today, Trio planned) |

Metrics come from the ring's own records: 5-minute HR + HRV averages, the Ring 5
quality-gated green-LED beat stream, nocturnal skin temperature, SpO2, per-minute MET
activity, the ring's detected sleep window, sleep stages when the ring emits them,
and breathing rate from its sleep windows.

## Before you start: the ring key

The ring only shares data with a phone that knows its 16-byte **auth key**. A ring
set up in the Oura app has a key only that app knows, so you need one of:

1. **Pair a factory-reset ring with Aurora** (the app does this for you). Reset it
   from the Oura app (Devices › your ring › Factory reset), then tap *Find my ring*
   in Aurora. This disconnects the ring from the Oura app; taking it back there
   means another reset. Sync anything you care about in the Oura app first.
2. **Paste a key you already have**, e.g. one extracted with open_oura's tools
   (`tools/android_oura_key_extract.py` works on a rooted Android phone that paired
   the ring). The app verifies the key against the ring before saving it.

The key lives in the iOS Keychain (this device only) and is never exported.

## Ring 5 status

open_oura reports the full flow working on a Ring 5 (firmware 2.1.x): pairing with a
client key, auth, battery, enabling measurements, history sync and live data. Ring 5
uses the same Bluetooth service, framing and auth as Ring 3/4, plus extra
characteristics and multi-event notifications, which open_oura (and so Aurora)
handles. Known gaps, inherited from the protocol work:

* Oura's sleep **stages** and its 0-100 Sleep / Readiness / Activity **scores** are
  computed by proprietary models in the Oura app, not by the ring. Aurora shows the
  ring's sleep window, the signals behind those scores, and stages only when the ring
  itself emits them. No scores are invented.
* The ring does not report a **step count**; steps are estimated from intensity.
* The roles of three new Ring 5 characteristics are not yet characterised upstream.
* Untested by this project on real hardware so far: please report what you see.

## Build and run (Mac)

Needs Xcode 15+, [Rust](https://rustup.rs) and XcodeGen (`brew install xcodegen`).

```sh
./ios/bootstrap.sh
```

That builds the Rust core for device + simulator (`ios/build-core.sh`), generates
`ios/Aurora.xcodeproj` and opens it. Set your Team under *Signing & Capabilities*
(change the bundle id if needed), pick your iPhone and Run. A free Apple ID works for
installing on your own phone (re-sign every 7 days); a paid developer account allows
TestFlight.

Rust tests run anywhere: `cargo test -p aurora-core`.

## How it is built

```
SwiftUI app (ios/Aurora)              Rust core (core/aurora-core)            open_oura crates
────────────────────────              ─────────────────────────────            ────────────────
CoreBluetooth link  ── bytes ──────▶  RingSession (UniFFI)  ─────────────────▶ oura-link: auth, Ring 5 setup,
                    ◀── writes ─────                                            time sync, history drain
Today / Trends / Ring views ◀──────  AuroraStore: samples, day summaries ◀──── oura-protocol: event decoders
Connectors (Nocturne, Trio) ◀──────  samples_after(cursor) per connector  ◀─── oura-store: lossless raw events
```

* Swift only moves Bluetooth bytes and draws screens. All protocol, storage and
  metric logic is Rust, unit-tested on any machine.
* Raw ring events are kept losslessly, so improved decoders can re-derive history
  (Settings › Re-process all data) without touching the ring.
* Export connectors read typed samples through a per-connector cursor. See
  [`docs/CONNECTORS.md`](docs/CONNECTORS.md) to add one, and
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the details.

## Credits and license

Ring protocol, decoders and storage: [open_oura](https://github.com/Th0rgal/open_oura)
by Thomas Marchand (MIT). Ring-clock dating adapted from
[open_health](https://github.com/Th0rgal/open_health) (MIT). Not affiliated with Oura.
Not a medical device: do not dose insulin from these numbers without your own checks.

See [LICENSE](LICENSE).
