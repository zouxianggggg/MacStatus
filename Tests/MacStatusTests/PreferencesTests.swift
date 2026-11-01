import XCTest
@testable import MacStatus

final class PreferencesTests: XCTestCase {
    func testCardOrderSurvivesUnknownAndDuplicateStoredIdentifiers() {
        let layout = CardLayout(order: ["network", "network", "future-module", "cpu"], hidden: ["disk", "future-module"])
        XCTAssertEqual(layout.order, [.network, .cpu, .memory, .disk, .battery, .system])
        XCTAssertEqual(layout.visible, [.network, .cpu, .memory, .battery, .system])
    }
    func testReorderingPreservesHiddenStateAndGuardsEdges() {
        var layout = CardLayout(hidden: ["memory"])
        layout.move(.cpu, by: -1)
        XCTAssertEqual(layout.order.first, .cpu)
        layout.move(.network, by: -1)
        XCTAssertEqual(layout.visible, [.cpu, .network, .disk, .battery, .system])
        layout.move(.system, by: 1)
        XCTAssertEqual(layout.order.last, .system)
        XCTAssertEqual(layout.hidden, [.memory])
    }
    func testEveryCardCanBeHiddenWithoutLosingItsOrder() {
        let layout = CardLayout(order: ["system"], hidden: Metric.allCases.map(\.rawValue))
        XCTAssertTrue(layout.visible.isEmpty)
        XCTAssertEqual(layout.order.count, Metric.allCases.count)
        XCTAssertEqual(layout.order.first, .system)
    }
    func testMenuSpeedDoesNotRaiseTheBackgroundFullSamplingRate() {
        var policy = SamplingPolicy()
        XCTAssertEqual(policy.next(at: 100, visible: false, showsSpeed: true, lowPower: false), .full)
        for time in stride(from: 102.0, to: 110.0, by: 2) {
            XCTAssertEqual(policy.next(at: time, visible: false, showsSpeed: true, lowPower: false), .networkOnly)
        }
        XCTAssertEqual(policy.next(at: 110, visible: false, showsSpeed: true, lowPower: false), .full)
        XCTAssertEqual(policy.next(at: 112, visible: true, showsSpeed: true, lowPower: false), .full)
    }
    func testEcoPolicyAndWakeRebuildTheFullBaseline() {
        var policy = SamplingPolicy()
        XCTAssertEqual(policy.next(at: 0, visible: false, showsSpeed: true, lowPower: true), .full)
        for time in stride(from: 5.0, to: 30.0, by: 5) {
            XCTAssertEqual(policy.next(at: time, visible: false, showsSpeed: true, lowPower: true), .networkOnly)
        }
        XCTAssertEqual(policy.next(at: 30, visible: false, showsSpeed: true, lowPower: true), .full)
        policy.reset()
        XCTAssertEqual(policy.next(at: 31, visible: false, showsSpeed: true, lowPower: true), .full)
        XCTAssertEqual(SamplingPolicy.interval(visible: false, showsSpeed: false, lowPower: true), 30)
        XCTAssertEqual(SamplingPolicy.interval(visible: false, showsSpeed: true, lowPower: true), 5)
    }
    func testFeedbackReportContainsOnlyTheSpecifiedEnvironment() {
        let machine = MachineInfo(model: "TestMac", chip: "TestChip", cores: 8, memory: 16 * 1024 * 1024 * 1024, os: "TestOS")
        let report = SupportReport.make(machine: machine, lowPower: true, menuMode: .both, version: "0.5-test")
        XCTAssertTrue(report.contains("0.5-test"))
        XCTAssertTrue(report.contains("TestOS"))
        XCTAssertTrue(report.contains("TestMac"))
        XCTAssertTrue(report.contains("节能"))
        XCTAssertTrue(report.contains("上传与下载"))
        XCTAssertFalse(report.contains("/Users/"))
        XCTAssertTrue(report.contains("复现步骤："))
    }
    func testTimerLeewayDoesNotDelayAnEcoSampleByFiveMoreSeconds() {
        var policy = SamplingPolicy()
        XCTAssertEqual(policy.next(at: 0.2, visible: false, showsSpeed: true, lowPower: true), .full)
        XCTAssertEqual(policy.next(at: 29.9, visible: false, showsSpeed: true, lowPower: true), .networkOnly)
        XCTAssertEqual(policy.next(at: 30.1, visible: false, showsSpeed: true, lowPower: true), .full)
    }
}
