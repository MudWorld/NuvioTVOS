import XCTest
@testable import NuvioTV

final class PlaybackIssueReportStoreTests: XCTestCase {
    private func snapshot(position: Double = 12, duration: Double = 120) -> PlaybackIssueReport {
        PlaybackIssueReport(
            message: "HTTP 403 https://user:secret@example.com/private/movie.mkv?token=private-token Authorization: Bearer private-auth",
            streamURL: URL(string: "https://user:secret@example.com/private/movie.mkv?token=private-token"),
            engine: .aether, isLive: false, renderedFirstFrame: true,
            position: position, duration: duration
        )
    }

    func testSnapshotDoesNotPersistFreeFormErrorOrSourceData() throws {
        let data = try JSONEncoder().encode(snapshot())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for secret in ["secret", "example.com", "movie.mkv", "private-token", "private-auth", "Authorization"] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertTrue(text.contains("STREAM ACCESS DENIED"))
        XCTAssertLessThanOrEqual(data.count, PlaybackIssueReportStore.maximumReportBytes)
    }

    func testNonFiniteAndNegativeTimesDoNotPreventEncoding() throws {
        let report = snapshot(position: .nan, duration: -.infinity)
        XCTAssertNil(report.positionSeconds)
        XCTAssertNil(report.durationSeconds)
        XCTAssertNoThrow(try JSONEncoder().encode(report))
        XCTAssertNil(snapshot(position: -1).positionSeconds)
    }

    func testRetentionKeepsTwentyOwnedReportsAndUnrelatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = directory.appendingPathComponent("unrelated.json")
        try Data("keep".utf8).write(to: unrelated)
        for _ in 0..<25 {
            XCTAssertTrue(PlaybackIssueReportStore.write(snapshot(), to: directory))
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.lastPathComponent.hasPrefix("playback-") }.count, 20)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
    }

    func testFilesystemFailureReturnsFalse() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertFalse(PlaybackIssueReportStore.write(snapshot(), to: file))
    }
}
