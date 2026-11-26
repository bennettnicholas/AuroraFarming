# Export connectors

A connector forwards ring data to another service. The data layer does the hard
parts; a connector only maps samples to the service's format.

## How they work

* `ConnectorManager` (Swift) runs after every sync. For each enabled, configured
  connector it reads the connector's cursor (`AuroraStore.connectorCursor`), pages
  `samplesAfter(cursor, exportedKinds, 500)`, calls `upload(page)`, and only then
  advances the cursor. A failed upload leaves the cursor, so the page is retried next
  time. Status and last error are shown on the Share tab.
* Sample ids are stable (re-dating a sample updates it in place), so a connector never
  re-sends unless asked ("Send everything again" resets its cursor).
* Secrets go in the Keychain (`Keychain.set`), settings in `UserDefaults`.

## Adding one

1. Create `ios/Aurora/Connectors/MyConnector.swift` implementing `HealthConnector`
   (`id` must never change: it keys the cursor).
2. Add it to the list in `ConnectorManager.init`.
3. Add a settings screen in `ConnectorsView.destination(for:)`.
4. Keep the mapping in `static` pure functions and unit-test them (see
   `AuroraTests/NocturneConnectorTests.swift`).

## Nocturne (implemented)

[Nocturne](https://getnocturne.dev) is a .NET rewrite of the Nightscout API
([source](https://github.com/nightscout/nocturne)). Aurora uses its V4 health API:

| Aurora sample | Endpoint | Record |
| --- | --- | --- |
| `heart_rate` | `POST /api/v4/HeartRate` | `{timestamp, utcOffset, bpm, accuracy, device, app, dataSource, syncIdentifier}` |
| `activity_met` (optional) | `POST /api/v4/StepCount` | `{timestamp, utcOffset, metric, source: 0, …}`: steps per minute estimated from MET |

* `dataSource` = `aurora-oura-ring`, `syncIdentifier` = `hr-<unix seconds>` /
  `steps-<unix seconds>`. Nocturne updates records with the same pair in place, so
  re-sends never duplicate.
* Auth: `api-secret` header. A Nocturne access token (`noc_…`) is sent as is; a legacy
  Nightscout API secret is SHA-1 hashed. The token needs health write scope.
* Nocturne has no V4 types yet for HRV, skin temperature, SpO2 or sleep, so those stay
  on the phone. If Nocturne adds them, they are a few lines in `NocturneConnector`.

## Trio (planned)

[Trio](https://github.com/nightscout/Trio) is an open-source iOS automated insulin
delivery app. It has no plug-in API for outside data today. Options, roughly in order
of effort:

1. **Via Nightscout/Nocturne.** With the Nocturne connector on, heart rate and
   activity already sit next to Trio's glucose, insulin and carbs data, which helps
   review and reports. Trio itself does not use them for dosing today.
2. **Via Apple Health.** An `AppleHealthConnector` (HealthKit write of heart rate, HRV,
   sleep, active energy) is straightforward and useful on its own. Useful for Trio only
   if Trio starts reading those types.
3. **In Trio.** A small Trio change that reads activity / heart rate (from Health or
   from Aurora through an App Group) and feeds it to its sensitivity / exercise logic.
   Dosing-adjacent: needs care, testing, and the Trio maintainers.

`TrioConnector` is a placeholder in the Share tab until one of these is chosen.
