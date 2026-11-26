import XCTest
@testable import Aurora

@MainActor
final class NocturneConnectorTests: XCTestCase {
    private func sample(_ kind: MetricKind, ts: Double, value: Double, id: Int64 = 1) -> Sample {
        Sample(id: id, kind: kind, ts: ts, endTs: nil, value: value, eventId: 7)
    }

    func testHeartRateRecordsAreStableAndOnlyHeartRate() throws {
        let utc = TimeZone(identifier: "UTC")!
        let records = NocturneConnector.heartRateRecords(
            [sample(.heartRate, ts: 1_764_000_000.4, value: 57.6), sample(.hrv, ts: 1_764_000_000, value: 40)],
            device: "Oura Ring 5", timeZone: utc)
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.bpm, 58)
        XCTAssertEqual(r.utcOffset, 0)
        XCTAssertEqual(r.dataSource, NocturneConnector.dataSource)
        XCTAssertEqual(r.syncIdentifier, "hr-1764000000")
        XCTAssertTrue(r.timestamp.hasPrefix("2025-11-24T"))

        // camelCase keys, as Nocturne's V4 API expects
        let json = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        XCTAssertTrue(json.contains("\"syncIdentifier\""))
        XCTAssertTrue(json.contains("\"utcOffset\""))
    }

    func testStepEstimatesSkipRestingMinutes() {
        let records = NocturneConnector.stepRecords(
            [sample(.activityMet, ts: 0, value: 1.2), sample(.activityMet, ts: 60, value: 3.5),
             sample(.activityMet, ts: 120, value: 8)],
            device: "x", timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(records.map(\.metric), [105, 150])
        XCTAssertEqual(records.map(\.source), [0, 0])
    }

    func testApiSecretHeader() {
        XCTAssertEqual(NocturneConnector.apiSecretHeader(for: "noc_abc123"), "noc_abc123")
        // SHA-1("test") — what Nightscout expects for a legacy API secret.
        XCTAssertEqual(NocturneConnector.apiSecretHeader(for: "test"), "a94a8fe5ccb19ba61c4c0873d391e987982fbbd3")
        XCTAssertEqual(NocturneConnector.apiSecretHeader(for: "A94A8FE5CCB19BA61C4C0873D391E987982FBBD3"),
                       "a94a8fe5ccb19ba61c4c0873d391e987982fbbd3")
    }

    func testChunking() {
        XCTAssertEqual(Array(0..<5).chunked(into: 2), [[0, 1], [2, 3], [4]])
    }

    func testCoreRoundTrip() throws {
        XCTAssertTrue(coreVersion().hasPrefix("aurora-core"))
        XCTAssertTrue(isValidAuthKey(hexKey: try generateAuthKey()))
        let path = FileManager.default.temporaryDirectory.appending(path: "t-\(UUID()).db").path(percentEncoded: false)
        let store = try AuroraStore.open(path: path)
        XCTAssertEqual(try store.stats().rawEvents, 0)
        XCTAssertNil(try store.latest(kind: .heartRate))
    }
}
