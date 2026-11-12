import XCTest
import Darwin
@testable import FolderMergerCore

final class MergeLogTests: XCTestCase {
    func testTakeoutDefaultDecisionsAndBoundedScreen() throws {
        inputs = (1...3).map { base.appendingPathComponent("takeout-00\($0)") }
        let folder = "Takeout/Google フォト/アルバム"
        for (i, root) in inputs.enumerated() {
            let spelling = i == 1 ? folder.decomposedStringWithCanonicalMapping : folder
            try FileManager.default.createDirectory(atPath: root.path + "/" + spelling, withIntermediateDirectories: true)
            try write(i, spelling + "/only-\(i).jpg", "unique-\(i)")
            try write(i, spelling + "/same.jpg", "identical")
            try write(i, spelling + "/different.jpg", "different-\(i)")
        }
        let req = MergeRequest(inputs: inputs, output: destination)
        let log = MergeLog(request: req, detailed: false, language: "en")
        var screen = ConflictingFileDecisions()
        let result = MergeEngine().run(req, event: { if let d = $0.finalSelection { screen.append(d) } }, logEvent: log.record)
        log.finish(result)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(screen.count, 1)
        let decision = try XCTUnwrap(screen.items.first)
        XCTAssertEqual(decision.selectedInput, inputs[0])
        XCTAssertEqual(decision.rejectedInputs, Array(inputs.dropFirst()))
        XCTAssertEqual(decision.policy, .earlier)
        XCTAssertTrue(decision.scanCompleted)
        XCTAssertEqual(result.counters.skipped, 2)
        let out = try XCTUnwrap(result.output)
        for i in 0..<3 { XCTAssertTrue(FileManager.default.fileExists(atPath: out.path + "/" + folder + "/only-\(i).jpg")) }
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent(folder + "/different.jpg")), "different-0")
        let rows = try parse(exported(log, .csv)).filter { $0[1] == "Conflicting File Decisions" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][2], decision.relativePath)
        XCTAssertEqual(rows[0][3], decision.selectedInput.path)
        XCTAssertEqual(rows[0][4], decision.rejectedInputs.map(\.path).joined(separator: "; "))
        XCTAssertEqual(rows[0][6], "Prefer the input folder added first")
        XCTAssertTrue(rows[0][9].contains("finalized output"))
        let txt = String(decoding: try exported(log, .txt), as: UTF8.self)
        XCTAssertTrue(txt.contains("Conflicting paths: 1"))
        XCTAssertTrue(txt.contains("Relative Path: " + decision.relativePath))
        XCTAssertLessThan(try XCTUnwrap(txt.range(of: "\nConflicting File Decisions\n")).lowerBound,
                          try XCTUnwrap(txt.range(of: "\nActivity log (chronological)\n")).lowerBound)

        // Every record is journaled, while the screen model retains at most 1,000.
        let many = MergeLog(request: req, detailed: false, language: "en")
        var bounded = ConflictingFileDecisions()
        for _ in 0..<1007 {
            bounded.append(decision)
            many.record(MergeEvent(timestamp: Date(), kind: .finalSelection, relativePath: decision.relativePath,
                sourceInput: decision.selectedInput, bytes: nil, attribute: nil, reason: nil, message: "",
                counters: MergeCounters(), selection: nil, finalSelection: decision))
        }
        many.finish(result)
        XCTAssertEqual(bounded.count, 1007); XCTAssertEqual(bounded.items.count, 1000); XCTAssertEqual(bounded.omitted, 7)
        XCTAssertEqual(try parse(exported(many, .csv)).filter { $0[1] == "Conflicting File Decisions" }.count, 1007)
        XCTAssertTrue(String(decoding: try exported(many, .txt), as: UTF8.self).contains("Conflicting paths: 1007"))
    }

    func testDecisionProtectionAndRestoration() throws {
        for lead in ["=", "+", "-", "@", "\t", "\r", "\n", "＝", "＋", "－", "＠"] {
            let req = request(), log = MergeLog(request: req, detailed: false, language: "en")
            let selected = URL(string: lead + "selected") ?? URL(fileURLWithPath: "/synthetic")
            // Relative input URLs exercise dangerous leading input/compared cells as well as paths.
            let decision = ConflictingFileDecision(relativePath: lead + "photo.jpg", selectedInput: selected,
                rejectedInputs: [selected], policy: .earlier, scanCompleted: true)
            log.record(MergeEvent(timestamp: Date(), kind: .finalSelection, relativePath: decision.relativePath,
                sourceInput: selected, bytes: nil, attribute: nil, reason: nil, message: "", counters: MergeCounters(),
                selection: nil, finalSelection: decision))
            log.finish(MergeResult(status: .failure, output: nil, counters: MergeCounters(), warnings: [], error: MergeError("synthetic")))
            let row = try XCTUnwrap(parse(exported(log, .csv)).first { $0[1] == "Conflicting File Decisions" })
            XCTAssertTrue(row[10].contains("relative_path"))
            for (index, original) in [(2, decision.relativePath), (3, selected.path), (4, selected.path)] {
                let protected = row[10].split(separator: ";").contains(Substring(MergeLog.csvColumnIdentifiers[index]))
                XCTAssertEqual(protected ? String(row[index].dropFirst()) : row[index], original)
                XCTAssertEqual(protected, MergeLog.needsCSVProtection(original))
            }
            XCTAssertTrue(row[9].contains("Output is not finalized"))
            let txt = String(decoding: try exported(log, .txt), as: UTF8.self)
            XCTAssertTrue(txt.contains(decision.relativePath.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")))
        }
    }

    func testInterruptedScanAndConstructionDecisionsRemainUnfinalized() throws {
        try write(0, "same", "a"); try write(1, "same", "b"); try write(2, "same", "c")
        for mode in ["scan", "build", "cancel"] {
            let req = request(.later), engine = MergeEngine(), token = CancellationToken()
            let log = MergeLog(request: req, detailed: false, language: "en")
            var decisions: [ConflictingFileDecision] = []
            let result = engine.run(req, cancellation: token, event: { e in
                if let d = e.finalSelection { decisions.append(d) }
                if mode == "scan", e.kind == .fileSelected { token.cancel() }
                if e.kind == .phase, e.message == L("Build in temporary folder") {
                    if mode == "cancel" { token.cancel() }
                    if mode == "build" { try! FileManager.default.removeItem(at: self.inputs[2].appendingPathComponent("same")) }
                }
            }, logEvent: log.record)
            log.finish(result)
            XCTAssertNil(result.output)
            XCTAssertEqual(decisions.count, 1)
            XCTAssertEqual(decisions[0].scanCompleted, mode != "scan")
            let row = try XCTUnwrap(parse(exported(log, .csv)).first { $0[1] == "Conflicting File Decisions" })
            XCTAssertTrue(row[9].contains("Output is not finalized"))
            if mode == "scan" { XCTAssertEqual(row[5], "Scan incomplete; decisions so far only") }
            let txt = String(decoding: try exported(log, .txt), as: UTF8.self)
            XCTAssertTrue(txt.contains("Output is not finalized. These are selection decisions only."))
            if mode == "build" { try write(2, "same", "c") }
        }
    }

    func testCSVProtectionPredicate() {
        let dangerous = ["=", "+", "-", "@", "\t", "\r", "\n", "＝", "＋", "－", "＠"]
        for lead in dangerous {
            for prefix in ["", " ", "\u{00a0}", "\u{2003}", "\u{2028}", "\u{200B}", "\u{FEFF}", "\u{0000}", "\u{007f}", " \u{200B}\u{0001}"] {
                XCTAssertTrue(MergeLog.needsCSVProtection(prefix + lead + "日本語,\"資料\"\r\n"), (prefix + lead).debugDescription)
            }
        }
        for safe in ["", " ", "\u{200B}", " \u{0000}\u{FEFF}", "'quoted.txt", "''=x", "'=1", "日本語", "a=b", "a\t=1", "資料,\"名前\"\n=1", " ' =1"] {
            XCTAssertFalse(MergeLog.needsCSVProtection(safe), safe.debugDescription)
        }
        for id in MergeLog.csvColumnIdentifiers + ["Protected columns", "保護した列", MergeLog.csvColumnIdentifiers.joined(separator: ";")] {
            XCTAssertFalse(MergeLog.needsCSVProtection(id))
        }
    }

    func testAllCSVColumnsAndHeadersRoundTrip() throws {
        let originals = ["=1+1", "+1", "-1", "@SUM(1)", "\ttext", "\rtext", "\ntext", "＝1", " ＋1", "\u{200B}＠日本語,\"資料\"\r\n"]
        let data = Data([0xef, 0xbb, 0xbf]) + Data(MergeLog.csv(originals).utf8)
        let row = try XCTUnwrap(parse(data).first)
        XCTAssertEqual(row[10], MergeLog.csvColumnIdentifiers.joined(separator: ";"))
        XCTAssertEqual(row.prefix(10).map { String($0.dropFirst()) }, originals)
        // Even a translated heading starting with a formula is protected and recorded.
        let header = try XCTUnwrap(parse(Data([0xef, 0xbb, 0xbf]) + Data(MergeLog.csv(originals, metadataHeading: "Protected columns").utf8)).first)
        XCTAssertEqual(header[10], MergeLog.csvColumnIdentifiers.joined(separator: ";"))
        XCTAssertEqual(header.prefix(10), row.prefix(10))
    }

    func testEngineCSVRestoresJournalAndLeavesTXTAndEventsUnchanged() throws {
        let names = ["=1+1", "+1", "-1", "@SUM(1)", "＝1", "＋1", "－1", "＠1", " =1", "\u{200B}=1", "\tname", "\rname", "\nname", "'quoted.txt", "''=x", "日本語,\"資料\"\r\n.txt", "=日本語,\"資料\"\n.txt"]
        for name in names { try write(0, name, "synthetic") }
        let journalDirectory = base.appendingPathComponent("journals")
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        let log = MergeLog(request: request(), detailed: true, language: "en", temporaryDirectory: journalDirectory)
        var events: [MergeEvent] = []
        let result = MergeEngine().run(request(), detailedLog: true, event: { events.append($0) }, logEvent: log.record)
        log.finish(result)
        XCTAssertEqual(result.status, .success)
        let journal = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil).first)
        let originalRows = try Data(contentsOf: journal).split(separator: 10).map { try JSONDecoder().decode([String].self, from: Data($0)) }
        let journalBeforeExport = try Data(contentsOf: journal)
        let rows = try parse(exported(log, .csv))
        XCTAssertEqual(rows.count, originalRows.count + 1)
        for (row, original) in zip(rows.dropFirst(), originalRows) {
            let ids = row[10].split(separator: ";").map(String.init)
            XCTAssertEqual(ids, original.enumerated().compactMap { MergeLog.needsCSVProtection($0.element) ? MergeLog.csvColumnIdentifiers[$0.offset] : nil })
            for index in 0..<10 {
                let protected = ids.contains(MergeLog.csvColumnIdentifiers[index])
                XCTAssertEqual(Data((protected ? String(row[index].dropFirst()) : row[index]).utf8), Data(original[index].utf8))
                if protected { XCTAssertTrue(row[index].hasPrefix("'")) }
            }
        }
        let txt = String(decoding: try exported(log, .txt), as: UTF8.self)
        for name in names {
            let escaped = name.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
            XCTAssertTrue(txt.contains("Relative Path: " + escaped + " |"), name.debugDescription)
            XCTAssertTrue(events.contains { $0.kind == .copied && $0.relativePath == name })
            XCTAssertTrue(originalRows.contains { $0[1] == "Copied" && $0[2] == name && $0[3] == inputs[0].path })
        }
        XCTAssertFalse(txt.contains("Protected columns:"))
        XCTAssertEqual(try Data(contentsOf: journal), journalBeforeExport)
    }

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
    func clearOutput(_ output: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }
    }
    func request(_ policy: SamePathPolicy = .later) -> MergeRequest {
        MergeRequest(inputs: inputs, output: destination, options: MergeOptions(samePathPolicy: policy))
    }
    func write(_ index: Int, _ name: String, _ value: String) throws {
        try Data(value.utf8).write(to: inputs[index].appendingPathComponent(name))
    }
    func exported(_ log: MergeLog, _ format: MergeLogFormat, kind: MergeLogKind = .detailed) throws -> Data {
        let url = base.appendingPathComponent("export.\(format.rawValue)")
        try log.export(to: url, format: format, kind: kind)
        return try Data(contentsOf: url)
    }
    // RFC 4180 parser: quoted CR/LF remain within a field, escaped quotes round trip.
    func parse(_ data: Data, columns: Int = 11) throws -> [[String]] {
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
        XCTAssertTrue(rows.allSatisfy { $0.count == columns })
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
        XCTAssertEqual(rows[0], ["Time", "Action", "Relative Path", "Input", "Compared With", "Decision", "Applied Rule", "Input Modified", "Compared Modified", "Details", "Protected columns"])
        let selections = rows.filter { $0[1] == "File selection" }
        XCTAssertEqual(selections.count, 2)
        XCTAssertTrue(selections.allSatisfy { $0[2] == name && !$0[4].isEmpty && !$0[6].isEmpty })
        XCTAssertTrue(selections[0][7].contains(".123456781+09:00")); XCTAssertTrue(selections[0][8].contains(".123456780+09:00"))
        let final = rows.filter { $0[1] == "Conflicting File Decisions" }
        XCTAssertEqual(final.count, 1); XCTAssertEqual(final[0][3], inputs[2].path)
        XCTAssertEqual(rows.filter { $0[1] == "Skipped identical file" }.count, 2)
        XCTAssertTrue(rows.contains { $0[9].contains("Output finalized: " + req.output.path) })
        let txtData = try exported(log, .txt), txt = String(decoding: txtData, as: UTF8.self)
        XCTAssertFalse(txtData.starts(with: [0xef, 0xbb, 0xbf])); XCTAssertFalse(txt.contains("\r"))
        for value in ["File selection", "Skipped identical file", "Conflicting File Decisions", inputs[2].path, ".123456782+09:00", "Run conditions", "Activity log (chronological)", "Final result"] { XCTAssertTrue(txt.contains(value), value) }
    }
    func testFailuresCancellationAndCleanupFailureAreUnfinalized() throws {
        try write(0, "same", "a"); try write(1, "same", "b")
        for mode in ["conflict", "validation", "cancel", "cleanup"] {
            let req = request(mode == "conflict" ? .stop : .later)
            if mode == "validation" { try Data("occupied".utf8).write(to: req.output.appendingPathComponent("occupied")) }
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
                XCTAssertFalse(rows.contains { $0[1] == "Conflicting File Decisions" })
            }
            if mode == "cleanup" { XCTAssertTrue(txt.contains("cleanup failed")); XCTAssertTrue(result.cleanupFailed) }
            if mode == "validation" { try clearOutput(req.output) }
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
            for row in rows where row[1] == "File selection" || row[1] == "Conflicting File Decisions" {
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
        XCTAssertEqual(rows[0], ["時刻", "処理", "相対パス", "入力元", "比較対象", "判定", "適用ルール", "入力元の変更日時", "比較対象の変更日時", "詳細", "保護した列"])
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
            XCTAssertEqual(rows[0][10], language == "ja" ? "保護した列" : "Protected columns")
            XCTAssertTrue(rows.contains { $0[9].contains(language == "ja" ? "ログは不完全です" : "Incomplete log") })
            let txt = String(decoding: try exported(log, .txt), as: UTF8.self)
            XCTAssertTrue(txt.contains(language == "ja" ? "実行条件" : "Run conditions"))
            if let output = result.output { try clearOutput(output) }
        }
    }
}

extension MergeLogTests {
    func testAllKindsAndFormatsAcrossOutcomes() throws {
        for mode in ["success", "warnings", "conflict", "cancel", "validation", "cleanup"] {
            for i in 0..<3 { try write(i, "same", "different-\(i)"); try write(i, "identical", "identical") }
            try FileManager.default.createDirectory(at: inputs[0].appendingPathComponent("folder"), withIntermediateDirectories: true)
            let req = request(mode == "conflict" ? .stop : .later)
            if mode == "validation" { try Data("occupied".utf8).write(to: req.output.appendingPathComponent("occupied")) }
            let log = MergeLog(request: req, detailed: false, language: "en")
            let engine = MergeEngine(), token = CancellationToken()
            if mode == "warnings" { engine.attributeOperation = { _, _, _ in ENOTSUP } }
            if mode == "cancel" { engine.beforeCommit = { token.cancel() } }
            if mode == "cleanup" {
                engine.beforeCommit = {
                    for url in try FileManager.default.contentsOfDirectory(at: self.destination, includingPropertiesForKeys: nil) where url.lastPathComponent.contains("foldermerger-") { try FileManager.default.removeItem(at: url) }
                    throw MergeError("synthetic cleanup failure")
                }
            }
            var screen: [MergeEvent.Kind] = []
            let result = engine.run(req, cancellation: token, detailedLog: false, event: { screen.append($0.kind) }, logEvent: log.record)
            log.finish(result)
            XCTAssertFalse(screen.contains(.copied)); XCTAssertFalse(screen.contains(.directoryCreated)); XCTAssertFalse(screen.contains(.skipped))
            XCTAssertEqual(result.status, mode == "success" ? .success : mode == "warnings" ? .warnings : mode == "cancel" ? .cancelled : .failure)
            for kind in MergeLogKind.allCases {
                let csv = try parse(exported(log, .csv, kind: kind), columns: kind == .summary ? 7 : 11)
                let txtData = try exported(log, .txt, kind: kind)
                let txt = String(decoding: txtData, as: UTF8.self)
                XCTAssertFalse(txtData.starts(with: [0xef, 0xbb, 0xbf])); XCTAssertFalse(txt.contains("\r"))
                let finalized = result.output != nil
                XCTAssertTrue(txt.contains(finalized ? "Output finalized" : "Output not finalized"))
                XCTAssertTrue(csv.contains { $0.last != nil && $0.joined().contains(finalized ? "Output finalized" : "Output not finalized") })
                if mode == "cleanup" { XCTAssertTrue(txt.contains("cleanup failed")) }
                if mode == "warnings" { XCTAssertTrue(csv.contains { $0[kind == .summary ? 0 : 1] == "Warning" }) }
                if mode == "conflict" { XCTAssertTrue(txt.contains("Conflicting items")); XCTAssertTrue(txt.contains("Failed")) }
                if kind == .summary {
                    for omitted in ["Category: Copied", "Created folder |", "Skipped identical file", "File selection", "Phase", "Activity log (chronological)"] { XCTAssertFalse(txt.contains(omitted), omitted) }
                    XCTAssertTrue(txt.contains("Copied:")); XCTAssertTrue(txt.contains("Created folders:"))
                    for heading in ["Run conditions", "Conflicting File Decisions", "Warnings and errors", "Final result"] { XCTAssertTrue(txt.contains("\n" + heading + "\n")) }
                    if !finalized { XCTAssertGreaterThanOrEqual(txt.components(separatedBy: "Output ").count - 1, 2) }
                    if mode == "success" || mode == "warnings" || mode == "cancel" || mode == "cleanup" {
                        let row = try XCTUnwrap(csv.first { $0[0] == "Conflicting File Decisions" && $0[1] == "same" })
                        XCTAssertEqual(row[2], inputs[2].path)
                        XCTAssertEqual(row[3], inputs.prefix(2).map(\.path).joined(separator: "; "))
                    }
                } else if finalized {
                    XCTAssertTrue(csv.contains { $0[1] == "Copied" }); XCTAssertTrue(csv.contains { $0[1] == "Created folder" })
                }
            }
            try clearOutput(req.output)
        }
    }

    func testSummaryProtectionHeadersAndIncompleteScan() throws {
        for language in ["en", "ja"] {
            for lead in ["=", "+", "-", "@", "\t", "\r", "\n", "＝", "＋", "－", "＠", " \u{200B}="] {
                let name = lead + "日本語,\"資料\"\r\n"
                let selected = try XCTUnwrap(URL(string: name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!))
                let log = MergeLog(request: request(), detailed: false, language: language)
                let decision = ConflictingFileDecision(relativePath: name, selectedInput: selected, rejectedInputs: [selected, selected], policy: .later, scanCompleted: false)
                log.record(MergeEvent(timestamp: Date(), kind: .finalSelection, relativePath: name, sourceInput: selected, bytes: nil, attribute: nil, reason: nil, message: "", counters: MergeCounters(), selection: nil, finalSelection: decision))
                log.finish(MergeResult(status: .failure, output: nil, counters: MergeCounters(), warnings: [], error: MergeError("synthetic")))
                let rows = try parse(exported(log, .csv, kind: .summary), columns: 7)
                XCTAssertEqual(rows[0], language == "en" ? ["Category", "Relative Path", "Selected Input", "Rejected Inputs", "Applied Rule", "Details", "Protected columns"] : ["区分", "相対パス", "採用元", "不採用元", "適用ルール", "詳細", "保護した列"])
                let row = try XCTUnwrap(rows.first { $0[1].hasSuffix(name) })
                let originals = [name, selected.path, [selected.path, selected.path].joined(separator: "; ")]
                for (offset, original) in originals.enumerated() {
                    let index = offset + 1
                    let protected = row[6].split(separator: ";").contains(Substring(MergeLog.summaryColumnIdentifiers[index]))
                    XCTAssertEqual(protected, MergeLog.needsCSVProtection(original))
                    XCTAssertEqual(protected ? String(row[index].dropFirst()) : row[index], original)
                }
                XCTAssertTrue(row[5].contains(language == "en" ? "Scan incomplete" : "走査未完了"))
            }
        }
    }

    func testSummaryLargeJournalAndMissingJournal() throws {
        let log = MergeLog(request: request(), detailed: false, language: "en")
        let decision = ConflictingFileDecision(relativePath: "file", selectedInput: inputs[0], rejectedInputs: Array(inputs.dropFirst()), policy: .earlier, scanCompleted: true)
        for _ in 0..<6101 {
            log.record(MergeEvent(timestamp: Date(), kind: .finalSelection, relativePath: "file", sourceInput: inputs[0], bytes: nil, attribute: nil, reason: nil, message: "", counters: MergeCounters(), selection: nil, finalSelection: decision))
        }
        log.finish(MergeResult(status: .success, output: request().output, counters: MergeCounters(), warnings: [], error: nil))
        XCTAssertEqual(try parse(exported(log, .csv, kind: .summary), columns: 7).filter { $0[1] == "file" }.count, 6101)
        XCTAssertTrue(String(decoding: try exported(log, .txt, kind: .summary), as: UTF8.self).contains("Conflicting paths: 6101"))
        XCTAssertEqual(try parse(exported(log, .csv)).filter { $0[1] == "Conflicting File Decisions" }.count, 6101)
        let missing = MergeLog(request: request(), detailed: false, language: "en", temporaryDirectory: base.appendingPathComponent("missing"))
        missing.finish(MergeResult(status: .cancelled, output: nil, counters: MergeCounters(), warnings: [], error: nil))
        for format in MergeLogFormat.allCases {
            let text = String(decoding: try exported(missing, format, kind: .summary), as: UTF8.self)
            XCTAssertTrue(text.contains("Incomplete log")); XCTAssertTrue(text.contains("Output not finalized"))
        }
        XCTAssertTrue(log.suggestedFilename(kind: .summary).hasPrefix("FolderMerger-summary-log-"))
        XCTAssertTrue(log.suggestedFilename(kind: .detailed).hasPrefix("FolderMerger-detailed-log-"))
    }
}
