import XCTest
import Darwin
@testable import MacStatus

final class NetworkTests: XCTestCase {
    func testValidAddressesKeepTheirFamily() {
        let v4 = Data(#"{"ip":"203.0.113.8"}"#.utf8)
        let v6 = Data(#"{"ip":"2001:db8::8"}"#.utf8)
        XCTAssertEqual(EgressQuery.parse(v4, family: AF_INET), "203.0.113.8")
        XCTAssertEqual(EgressQuery.parse(v6, family: AF_INET6), "2001:db8::8")
        XCTAssertNil(EgressQuery.parse(v4, family: AF_INET6))
        XCTAssertNil(EgressQuery.parse(v6, family: AF_INET))
    }

    func testInvalidProviderResponsesNeverBecomeDisplayedIPs() {
        for body in [#"{"ip":"999.1.2.3"}"#, #"{"ip":"<script>oops</script>"}"#, "<html>proxy login</html>", #"{"error":"rate limited"}"#] {
            XCTAssertNil(EgressQuery.parse(Data(body.utf8), family: AF_INET))
        }
        XCTAssertNil(EgressQuery.parse(Data(repeating: 32, count: 1025), family: AF_INET))
    }

    func testCacheExpiresAndNetworkChangesInvalidateIt() {
        let now = Date(timeIntervalSince1970: 1000)
        let reading = EgressReading(ipv4: EgressResult(address: "203.0.113.8"), checkedAt: now, identity: "network-A")
        XCTAssertFalse(reading.needsRefresh(for: "network-A", at: now.addingTimeInterval(299)))
        XCTAssertTrue(reading.needsRefresh(for: "network-A", at: now.addingTimeInterval(300)))
        XCTAssertTrue(reading.needsRefresh(for: "network-B", at: now))
        XCTAssertTrue(EgressReading().needsRefresh(for: "network-A", at: now))
    }

    func testLoadingDoesNotStartDuplicateQueries() {
        XCTAssertFalse(EgressReading(loading: true, identity: "network-A").needsRefresh(for: "network-A"))
    }

    func testChangingLinkMeasurementsDoesNotInvalidateAddressCache() {
        var info = ConnectionInfo(primaryInterface: "en0", router: "192.0.2.1", addresses: ["192.0.2.2"])
        let identity = info.identity
        info.wifiRate = 866
        info.wifiRSSI = -45
        XCTAssertEqual(identity, info.identity)
        info.proxy = "SOCKS"
        XCTAssertNotEqual(identity, info.identity)
    }

    func testPhysicalNetworkChangeInvalidatesCacheEvenWithTheSameTunnel() {
        var info = ConnectionInfo(primaryInterface: "utun4", router: "198.19.0.1", addresses: ["198.19.0.1"])
        info.physicalAddresses = ["en0:192.0.2.2"]
        let identity = info.identity
        info.physicalAddresses = ["en0:192.0.2.3"]
        XCTAssertNotEqual(identity, info.identity)
    }
}
