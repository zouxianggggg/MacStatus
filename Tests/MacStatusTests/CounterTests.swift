import XCTest
@testable import MacStatus

final class CounterTests: XCTestCase {
    func testCPUDeltaIncludesNiceAndUsesInterval() {
        let before = CPUTicks(user: 5000, system: 3000, idle: 8000, nice: 100)
        let after = CPUTicks(user: 5020, system: 3010, idle: 8060, nice: 110)
        let usage = after.usage(since: before)!
        XCTAssertEqual(usage.user, 0.3, accuracy: 0.0001)
        XCTAssertEqual(usage.system, 0.1, accuracy: 0.0001)
        XCTAssertEqual(usage.total, 0.4, accuracy: 0.0001)
    }

    func testCPUCounterWrapDoesNotSpike() {
        let before = CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)
        let after = CPUTicks(user: 10, system: 0, idle: 80, nice: 0)
        XCTAssertEqual(after.usage(since: before)!.total, 0.2, accuracy: 0.0001)
        XCTAssertNil(before.usage(since: before))
    }

    func testNetworkReconnectDoesNotTurnLifetimeBytesIntoSpeed() {
        let before = NetworkBaseline(time: 100, interfaces: [NetworkInterface(name: "en0", received: 1000, sent: 400)])
        let after = NetworkBaseline(time: 102, interfaces: [
            NetworkInterface(name: "en0", received: 1600, sent: 600),
            NetworkInterface(name: "en5", received: 9_000_000, sent: 8_000_000)
        ])
        let rates = after.rates(since: before)!
        XCTAssertEqual(rates.0, 300)
        XCTAssertEqual(rates.1, 100)
    }

    func testNetworkResetAndZeroIntervalAreUnavailable() {
        let before = NetworkBaseline(time: 100, interfaces: [NetworkInterface(name: "en0", received: 1000, sent: 400)])
        let reset = NetworkBaseline(time: 102, interfaces: [NetworkInterface(name: "en0", received: 10, sent: 4)])
        XCTAssertNil(reset.rates(since: before))
        XCTAssertNil(before.rates(since: before))
        XCTAssertNil(NetworkBaseline(time: 102, interfaces: []).rates(since: before))
    }

    func testNetworkCountersRemainAccurateBeyondFourGiB() {
        let before = NetworkBaseline(time: 100, interfaces: [NetworkInterface(name: "en0", received: 4_294_967_000, sent: 8_000_000_000)])
        let after = NetworkBaseline(time: 102, interfaces: [NetworkInterface(name: "en0", received: 4_294_968_000, sent: 8_000_002_000)])
        let rates = after.rates(since: before)!
        XCTAssertEqual(rates.0, 500)
        XCTAssertEqual(rates.1, 1000)
    }
}
