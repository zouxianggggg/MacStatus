import XCTest
import Darwin
@testable import MacStatus

final class DetailTests: XCTestCase {
    func testProcessCPUConvertsMachTicksAndRejectsPIDReuse() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = UInt64(2_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
        let old = ProcessCounter(start: 100, cpuTime: 0)
        XCTAssertEqual(ProcessCounter(start: 100, cpuTime: ticks).usage(since: old, elapsed: 1)!, 2, accuracy: 0.0001)
        XCTAssertNil(ProcessCounter(start: 101, cpuTime: ticks).usage(since: old, elapsed: 1))
        XCTAssertNil(old.usage(since: ProcessCounter(start: 100, cpuTime: 1), elapsed: 1))
        XCTAssertNil(old.usage(since: old, elapsed: 0))
    }

    func testCountryIsBoundToTheExactIPAndRequiresAValidCode() {
        let valid = Data(#"{"success":true,"ip":"203.0.113.8","country_code":"US","connection":{"isp":"Example","asn":123}}"#.utf8)
        let country = CountryQuery.parse(valid, address: "203.0.113.8")
        XCTAssertEqual(country?.flag, "🇺🇸")
        XCTAssertEqual(country?.asn, 123)
        XCTAssertNil(CountryQuery.parse(valid, address: "203.0.113.9"))
        XCTAssertNil(CountryQuery.parse(Data(#"{"success":false,"ip":"203.0.113.8","country_code":"US"}"#.utf8), address: "203.0.113.8"))
        XCTAssertNil(CountryQuery.parse(Data(#"{"success":true,"ip":"203.0.113.8","country_code":"ZZ"}"#.utf8), address: "203.0.113.8"))
        XCTAssertNil(CountryQuery.parse(Data("<html>offline</html>".utf8), address: "203.0.113.8"))
    }

    func testEquivalentIPv6AddressesCanReceiveTheSameCountry() {
        let data = Data(#"{"success":true,"ip":"2001:db8:0:0:0:0:0:8","country_code":"CN"}"#.utf8)
        XCTAssertEqual(CountryQuery.parse(data, address: "2001:db8::8")?.flag, "🇨🇳")
    }

    func testMenuSpeedModesAndUnits() {
        let network = NetworkReading(download: 1_048_576, upload: 2048, received: 0, sent: 0, interfaces: [])
        XCTAssertEqual(MenuSpeedMode.hidden.text(network: network), "")
        XCTAssertEqual(MenuSpeedMode.download.text(network: network), "↓ 1.0M/s")
        XCTAssertEqual(MenuSpeedMode.upload.text(network: network), "↑ 2K/s")
        XCTAssertEqual(MenuSpeedMode.both.text(network: network), "↓ 1.0M/s  ↑ 2K/s")
        XCTAssertEqual(DisplayFormat.menuRate(nil), "—")
        XCTAssertEqual(DisplayFormat.menuRate(.nan), "—")
    }
}
