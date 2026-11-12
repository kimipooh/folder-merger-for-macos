import XCTest
import Darwin
@testable import FolderMergerCore

final class MergeLogTests: XCTestCase {
    func testTimestampFormattingUsesInjectedTimezoneAndNanoseconds() {
        let zone = TimeZone(secondsFromGMT: 9 * 60 * 60)!
        let value = FileModificationTime(timespec(tv_sec: 1_794_445_201, tv_nsec: 123_456_789))
        let formatted = MergeLog.modificationTime(value, timeZone: zone)
        XCTAssertEqual(formatted, "2026-11-12T10:00:01.123456789+09:00")
        XCTAssertFalse(formatted.contains("Z"))
        let eventTime = MergeLog.time(Date(timeIntervalSince1970: 1_794_445_201), timeZone: zone)
        XCTAssertEqual(eventTime, "2026-11-12T10:00:01.000000000+09:00")
        XCTAssertFalse(eventTime.contains("Z"))
        let utc = TimeZone(secondsFromGMT: 0)!
        let utcTime = MergeLog.time(Date(timeIntervalSince1970: 1_794_445_201), timeZone: utc)
        XCTAssertEqual(utcTime, "2026-11-12T01:00:01.000000000+00:00")
        XCTAssertFalse(utcTime.contains("Z"))
        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(MergeLog.modificationTime(FileModificationTime(timespec(tv_sec: 1_768_478_400, tv_nsec: 0)), timeZone: pacific), "2026-01-15T04:00:00.000000000-08:00")
        XCTAssertEqual(MergeLog.modificationTime(FileModificationTime(timespec(tv_sec: 1_784_116_800, tv_nsec: 0)), timeZone: pacific), "2026-07-15T05:00:00.000000000-07:00")
    }
    var base: URL!
    var inputs: [URL] = []
    var destination: URL!
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("MergeLogTests-\(UUID())")
        inputs = (0..<3).map { base.appendingPathComponent("input\($0)") }
        destination = base.appendingPathComponent("destination")
        for url in inputs + [destination!] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    func request(_ policy: SamePathPolicy = .later) -> MergeRequest {
        MergeRequest(inputs: inputs, destination: destination, name: "out", options: MergeOptions(samePathPolicy: policy))
    }
    func write(_ index: Int, _ name: String, _ value: String) throws {
        try Data(value.utf8).write(to: inputs[index].appendingPathComponent(name))
    }
    func exported(_ log: MergeLog, _ format: MergeLogFormat) throws -> Data {
        let url = base.appendingPathComponent("export.\(format.rawValue)")
        try log.export(to: url, format: format)
        return try Data(contentsOf: url)
    }
    // RFC 4180 parser: quoted CR/LF remain within a field, escaped quotes round trip.
    func parse(_ data: Data) throws -> [[String]] {
        XCTAssertEqual(Array(data.prefix(3)), [0xef, 0xbb, 0xbf])
        let chars = Array(try XCTUnwrap(String(data: data.dropFirst(3), encoding: .utf8)))
        var rows: [[String]] = [], fields: [String] = [], field = "", quoted = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if !quoted && c == "," { fields.append(field); field = "" }
            else if !quoted && c == "\r\n" {
                fields.append(field); rows.append(fields); fields = []; field = ""
            } else if !quoted && (c == "\n" || c == "\r") { XCTFail("Non-CRLF CSV record separator") }
            else { field.append(c) }
            i += 1
        }
        XCTAssertFalse(quoted); XCTAssertTrue(field.isEmpty); XCTAssertTrue(fields.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.count == 10 })
        return rows
    }
    func testSelectionsSkippedNewerDatesAndSpecialPathsInBothFormats() throws {
        let name = "日本語,\"資料\"\r\n.txt"
        for i in 0..<3 {
            try write(i, name, "different-\(i)")
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: 1_600_000_000, tv_nsec: 123456780 + i)]
            XCTAssertEqual(utimensat(AT_FDCWD, inputs[i].appendingPathComponent(name).path, &times, AT_SYMLINK_NOFOLLOW), 0)
            try write(i, "identical", "same")
        }
        let req = request(.newer), log = MergeLog(request: request(.newer), detailed: false, language: "en")
        var displayedSkips = 0
        let result = MergeEngine().run(req, event: { if $0.kind == .skipped { displayedSkips += 1 } }, logEvent: log.record)
        log.finish(result)
        XCTAssertEqual(result.status, .success); XCTAssertEqual(displayedSkips, 0)
        let rows = try parse(exported(log, .csv))
        XCTAssertEqual(rows[0], ["Time", "Action", "Relative Path", "Input", "Compared With", "Decision", "Applied Rule", "Input Modified", "Compared Modified", "Details"])
        let selections = rows.filter { $0[1] == "File selection" }
        XCTAssertEqual(selections.count, 2)
        XCTAssertTrue(selections.allSatisfy { $0[2] == name && !$0[4].isEmpty && !$0[6].isEmpty })
        XCTAssertTrue(selections[0][7].contains(".123456781+09:00")); XCTAssertTrue(selections[0][8].contains(".123456780+09:00"))
        let final = rows.filter { $0[1] == "Final selected input" }
        XCTAssertEqual(final.count, 1); XCTAssertEqual(final[0][3], inputs[2].path)
        XCTAssertEqual(rows.filter { $0[1] == "Skipped identical file" }.count, 2)
        XCTAssertTrue(rows.contains { $0[9].contains("Output finalized: " + req.output.path) })
        let txtData = try exported(log, .txt), txt = String(decoding: txtData, as: UTF8.self)
        XCTAssertFalse(txtData.starts(with: [0xef, 0xbb, 0xbf])); XCTAssertFalse(txt.contains("\r"))
        for value in ["File selection", "Skipped identical file", "Final selected input", inputs[2].path, ".123456782+09:00", "Run conditions", "Activity log (chronological)", "Final result"] { XCTAssertTrue(txt.contains(value), value) }
    }
    func testFailuresCancellationAndCleanupFailureAreUnfinalized() throws {
        try write(0, "same", "a"); try write(1, "same", "b")
        for mode in ["conflict", "validation", "cancel", "cleanup"] {
            let req = request(mode == "conflict" ? .stop : .later)
            if mode == "validation" { try FileManager.default.createDirectory(at: req.output, withIntermediateDirectories: true) }
            let token = CancellationToken(), engine = MergeEngine()
            if mode == "cancel" { engine.beforeCommit = { token.cancel() } }
            if mode == "cleanup" {
                engine.beforeCommit = {
                    for url in try FileManager.default.contentsOfDirectory(at: self.destination, includingPropertiesForKeys: nil) where url.lastPathComponent.contains("foldermerger-") { try FileManager.default.removeItem(at: url) }
                    throw MergeError("synthetic failure")
                }
            }
            let log = MergeLog(request: req, detailed: false, language: "en")
            let result = engine.run(req, cancellation: token, logEvent: log.record); log.finish(result)
            XCTAssertNil(result.output)
            XCTAssertEqual(result.status, mode == "cancel" ? .cancelled : .failure)
            let rows = try parse(exported(log, .csv))
            XCTAssertTrue(rows.contains { $0[1] == "Final result" && $0[9].contains("Output not finalized") })
            let txt = String(decoding: try exported(log, .txt), as: UTF8.self)
            XCTAssertTrue(txt.contains("Output not finalized"))
            if mode == "conflict" {
                let row = try XCTUnwrap(rows.first { $0[1] == "Conflicting items" })
                XCTAssertEqual(row[2], "same"); XCTAssertEqual(row[3], inputs[0].path); XCTAssertEqual(row[4], inputs[1].path)
                XCTAssertFalse(rows.contains { $0[1] == "Final selected input" })
            }
            if mode == "cleanup" { XCTAssertTrue(txt.contains("cleanup failed")); XCTAssertTrue(result.cleanupFailed) }
            if mode == "validation" { try FileManager.default.removeItem(at: req.output) }
        }
    }
    func testAll6100CopiesAreExportedAndTemporaryJournalIsRemoved() throws {
        for i in 0..<6100 { try write(0, "file\(i)", "") }
        let journalDirectory = base.appendingPathComponent("journals")
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        var log: MergeLog? = MergeLog(request: request(), detailed: true, language: "en", temporaryDirectory: journalDirectory)
        let result = MergeEngine().run(request(), detailedLog: true, logEvent: { log!.record($0) })
        log!.finish(result)
        XCTAssertEqual(result.counters.copied, 6100)
        let rows = try parse(exported(log!, .csv))
        XCTAssertEqual(rows.filter { $0[1] == "Copied" }.count, 6100)
        let txt = String(decoding: try exported(log!, .txt), as: UTF8.self)
        XCTAssertEqual(txt.components(separatedBy: "Action: Copied").count - 1, 6100)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: journalDirectory.path).count, 1)
        log = nil
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: journalDirectory.path).isEmpty)
    }
    func testSelectionUsesOutputSpelling() throws {
        let first = "café.txt", later = "cafe\u{301}.txt"
        for (index, name) in [(0, first), (1, later)] {
            let fd = open(inputs[index].path + "/" + name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            var byte: UInt8 = UInt8(index)
            XCTAssertEqual(Darwin.write(fd, &byte, 1), 1); close(fd)
        }
        let log = MergeLog(request: request(), detailed: false, language: "en")
        var decisions: [MergeEvent] = []
        let result = MergeEngine().run(request(), logEvent: { log.record($0); if $0.kind == .fileSelected { decisions.append($0) } })
        log.finish(result)
        XCTAssertNotNil(result.output)
        // The destination probe decides whether canonical equivalents collide.
        if let decision = decisions.first {
            XCTAssertEqual(Data(decision.relativePath!.utf8), Data(first.utf8))
            let rows = try parse(exported(log, .csv))
            for row in rows where row[1] == "File selection" || row[1] == "Final selected input" {
                XCTAssertEqual(Data(row[2].utf8), Data(first.utf8)); XCTAssertEqual(row[3], inputs[1].path)
            }
        } else { XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: result.output!.path).count, 2) }
    }

    func testJapaneseSuccessfulExportAndWarning() throws {
        try write(0, "file", "synthetic")
        let log = MergeLog(request: request(), detailed: false, language: "ja")
        let engine = MergeEngine()
        engine.attributeOperation = { _, _, _ in ENOTSUP }
        let result = engine.run(request(), logEvent: log.record); log.finish(result)
        XCTAssertEqual(result.status, .warnings)
        let rows = try parse(exported(log, .csv))
        XCTAssertEqual(rows[0], ["時刻", "処理", "相対パス", "入力元", "比較対象", "判定", "適用ルール", "入力元の変更日時", "比較対象の変更日時", "詳細"])
        XCTAssertTrue(rows.contains { $0[1] == "警告" && $0[2] == "file" })
        XCTAssertTrue(rows.contains { $0[1] == "最終結果" && $0[5] == "警告ありで完了" })
        let txt = String(decoding: try exported(log, .txt), as: UTF8.self)
        for heading in ["実行条件", "作業ログ（時系列）", "最終結果"] { XCTAssertTrue(txt.contains(heading)) }
        // Replacing an existing export preserves a valid BOM and all rows.
        XCTAssertEqual(try exported(log, .csv), try exported(log, .csv))
    }

    func testJapaneseHeadersAndIncompleteJournal() throws {
        for language in ["en", "ja"] {
            let log = MergeLog(request: request(), detailed: false, language: language, temporaryDirectory: base.appendingPathComponent("missing"))
            let result = MergeEngine().run(request())
            log.finish(result)
            XCTAssertNotNil(log.recordingError)
            let rows = try parse(exported(log, .csv))
            XCTAssertEqual(rows[0][0], language == "ja" ? "時刻" : "Time")
            XCTAssertEqual(rows[0][9], language == "ja" ? "詳細" : "Details")
            XCTAssertTrue(rows.contains { $0[9].contains(language == "ja" ? "ログは不完全です" : "Incomplete log") })
            let txt = String(decoding: try exported(log, .txt), as: UTF8.self)
            XCTAssertTrue(txt.contains(language == "ja" ? "実行条件" : "Run conditions"))
            if let output = result.output { try FileManager.default.removeItem(at: output) }
        }
    }
}
