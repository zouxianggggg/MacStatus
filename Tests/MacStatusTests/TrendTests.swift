import XCTest
@testable import MacStatus

final class TrendTests: XCTestCase {
    private let end = Date(timeIntervalSince1970: 1000)

    private func point(_ secondsAgo: Double, _ value: Double?) -> HistoryPoint {
        HistoryPoint(date: end.addingTimeInterval(-secondsAgo), cpu: value, memory: value, download: value)
    }

    func testStartupSamplesOccupyOnlyRightEdgeInsteadOfFullWidth() {
        let first = TrendSeries.horizontalPosition(date: end.addingTimeInterval(-2), endingAt: end)
        let last = TrendSeries.horizontalPosition(date: end, endingAt: end)
        XCTAssertGreaterThan(first, 0.98)
        XCTAssertEqual(last, 1)
        XCTAssertLessThan(last - first, 0.02)
    }

    func testSingleSampleAndEmptyHistoryNeverInventAnotherPoint() {
        XCTAssertTrue(TrendSeries.segments(points: [], metric: \.cpu, endingAt: end).isEmpty)
        let segments = TrendSeries.segments(points: [point(0, 0.4)], metric: \.cpu, endingAt: end)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].count, 1)
        XCTAssertEqual(TrendSeries.horizontalPosition(date: segments[0][0].date, endingAt: end), 1)
    }

    func testUnavailableSamplesAndSleepGapsBreakTheLine() {
        let points = [point(110, 0.2), point(108, nil), point(106, 0.3), point(20, 0.4), point(18, 0.5)]
        let segments = TrendSeries.segments(points: points, metric: \.cpu, endingAt: end)
        XCTAssertEqual(segments.map(\.count), [1, 1, 2])
    }

    func testOldAndFutureSamplesAreOutsideTheFixedWindow() {
        let segments = TrendSeries.segments(points: [point(122, 0.1), point(120, 0.2), point(0, 0.3), point(-2, 0.4)], metric: \.cpu, endingAt: end)
        XCTAssertEqual(segments.flatMap { $0 }.map(\.value), [0.2, 0.3])
        XCTAssertEqual(TrendSeries.horizontalPosition(date: end.addingTimeInterval(-120), endingAt: end), 0)
    }
}
