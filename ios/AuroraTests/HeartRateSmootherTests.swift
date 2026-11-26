import XCTest
@testable import Aurora

final class HeartRateSmootherTests: XCTestCase {
    func testAveragesOverTheWindowAndDropsArtifacts() {
        var s = HeartRateSmoother()
        XCTAssertNil(s.add(ibiMs: 1000, at: 0))
        XCTAssertEqual(s.add(ibiMs: 900, at: 1), 63)   // 60000 / 950
        XCTAssertEqual(s.add(ibiMs: 1100, at: 2), 60)  // 60000 / 1000
        // A missed beat (double interval) is ignored.
        XCTAssertEqual(s.add(ibiMs: 2000, at: 4), 60)
        // Beats older than 5 s fall out of the average.
        XCTAssertEqual(s.add(ibiMs: 750, at: 6.5), 65) // only 1100 and 750 remain: 60000 / 925
    }
}
