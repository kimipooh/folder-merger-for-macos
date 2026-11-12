import XCTest
import Darwin
@testable import FolderMergerCore

final class MergeLogTests: XCTestCase {
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
    func parse(_ data: Data, columns: Int = 9) throws -> [[String]] {
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


    func run(_ policy: SamePathPolicy = .later, language: String = "en", engine: MergeEngine = MergeEngine(),
             token: CancellationToken = CancellationToken(), event: @escaping (MergeEvent) -> Void = { _ in }) -> (MergeLog, MergeResult) {
        let req = request(policy), log = MergeLog(request: req, detailed: false, language: language)
        let result = engine.run(req, cancellation: token, event: event, logEvent: log.record)
        log.finish(result)
        return (log, result)
    }
    func restored(_ row: [String], _ ids: [String]) -> [String] {
        let protected = row.last!.split(separator: ";").map(String.init)
        return row.dropLast().enumerated().map { protected.contains(ids[$0.offset]) ? String($0.element.dropFirst()) : $0.element }
    }
    func assertLogs(_ log: MergeLog, finalized: Bool, copies: Int, language: String = "en") throws {
        let ja = language == "ja"
        let summary = String(decoding: try exported(log, .txt, kind: .summary), as: UTF8.self)
        XCTAssertTrue(summary.hasPrefix(ja ? "最終結果\n" : "Final result\n"))
        for heading in ja ? ["コピーしたファイル", "警告・エラー"] : ["Copied files", "Warnings and errors"] {
            XCTAssertTrue(summary.contains("\n" + heading + "\n"))
        }
        for omitted in ["Inputs and settings\n", "入力と設定\n", "intermediate", "コピー（一時フォルダ）", "Processing stage", "Identical files skipped", "Conflicting paths"] { XCTAssertFalse(summary.contains(omitted), omitted) }
        XCTAssertEqual(summary.components(separatedBy: " → ").count - 1, finalized ? copies : 0)
        XCTAssertTrue(summary.contains(ja ? "状態：" : "Status:"))
        XCTAssertTrue(summary.contains(ja ? "出力：" : "Output:"))
        let csv = try parse(exported(log, .csv, kind: .summary), columns: 5)
        XCTAssertEqual(csv[0], ja ? ["区分", "コピー元", "コピー先", "内容", "保護した列"] : ["Category", "Source", "Destination", "Details", "Protected columns"])
        XCTAssertEqual(csv.filter { $0[0] == (ja ? "コピー" : "Copy") }.count, finalized ? copies : 0)
        let detailed = String(decoding: try exported(log, .txt), as: UTF8.self)
        let first = try XCTUnwrap(detailed.range(of: ja ? "最終結果\n" : "Final result\n"))
        let second = try XCTUnwrap(detailed.range(of: ja ? "入力と設定\n" : "Inputs and settings\n"))
        let third = try XCTUnwrap(detailed.range(of: ja ? "作業ログ（時系列）\n" : "Activity log (chronological)\n"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound); XCTAssertLessThan(second.lowerBound, third.lowerBound)
        if !finalized {
            XCTAssertTrue(String(detailed[..<second.lowerBound]).contains(ja ? "出力は確定していません" : "Output is not finalized"))
            XCTAssertTrue(summary.contains(ja ? "確定していません" : "Not finalized"))
        }
        for internalName in ["fileSelected", "finalSelection", "directoryCreated", "RENAME_EXCL"] { XCTAssertFalse(detailed.contains(internalName)) }
        let rows = try parse(exported(log, .csv))
        XCTAssertEqual(rows[0], ja ? ["時刻", "処理", "相対パス", "コピー元・採用元", "コピー先・不採用元", "判定", "理由", "補足", "保護した列"] : ["Time", "Operation", "Relative Path", "Source / selected input", "Destination / rejected input", "Decision", "Reason", "Notes", "Protected columns"])
        XCTAssertEqual(rows[1][1], ja ? "最終結果" : "Final result")
        for kind in MergeLogKind.allCases {
            let data = try exported(log, .txt, kind: kind)
            XCTAssertFalse(data.starts(with: [0xef, 0xbb, 0xbf])); XCTAssertFalse(data.contains(13))
        }
    }
    func testOrdinaryCopyAndJournalPaths() throws {
        try write(0, "photo.txt", "synthetic")
        try FileManager.default.createDirectory(at: inputs[0].appendingPathComponent("empty"), withIntermediateDirectories: false)
        var copied: [MergeEvent] = [], screen: [MergeEvent.Kind] = []
        let req = request(), log = MergeLog(request: req, detailed: false, language: "en", temporaryDirectory: base)
        let result = MergeEngine().run(req, event: { screen.append($0.kind) }, logEvent: { log.record($0); if $0.kind == .copied { copied.append($0) } })
        log.finish(result)
        XCTAssertEqual(result.status, .success); XCTAssertFalse(screen.contains(.copied))
        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(copied[0].sourceFile?.path, inputs[0].appendingPathComponent("photo.txt").path)
        XCTAssertEqual(copied[0].destinationFile?.path, destination.appendingPathComponent("photo.txt").path)
        try assertLogs(log, finalized: true, copies: 1)
        let detailedRows = try parse(exported(log, .csv))
        let resultRow = try XCTUnwrap(detailedRows.first { $0[1] == "Final result" })
        XCTAssertTrue(resultRow[4].isEmpty)
        XCTAssertTrue(resultRow[7].contains("Merge destination: \(destination.path)"))
        let copyRow = try XCTUnwrap(detailedRows.first { $0[1] == "Copy (temporary folder)" })
        XCTAssertTrue(copyRow[7].contains("Planned copy destination"))
        let summaryText = String(decoding: try exported(log, .txt, kind: .summary), as: UTF8.self)
        XCTAssertTrue(summaryText.contains("Merge destination: \(destination.path)"))
        XCTAssertFalse(summaryText.contains("Merge destination: \(base.appendingPathComponent("export.txt").path)"))
        let files = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        let journal = try XCTUnwrap(files.first { $0.pathExtension == "jsonl" })
        let before = try Data(contentsOf: journal)
        XCTAssertTrue(String(decoding: before, as: UTF8.self).contains("Output finalized"))
        _ = try exported(log, .csv)
        XCTAssertEqual(before, try Data(contentsOf: journal))
    }
    func testThreeInputsChangeSelectionAndCopyOnlyFinalSource() throws {
        for policy in [SamePathPolicy.earlier, .later, .newer] {
            for i in 0..<3 {
                try write(i, "same", "different-\(i)"); try write(i, "identical", "identical")
                var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: 1_600_000_000, tv_nsec: 123456780 + i)]
                XCTAssertEqual(utimensat(AT_FDCWD, inputs[i].appendingPathComponent("same").path, &times, AT_SYMLINK_NOFOLLOW), 0)
            }
            let (log, result) = run(policy)
            XCTAssertEqual(result.status, .success); XCTAssertEqual(result.counters.skipped, 2)
            let expected = policy == .earlier ? 0 : 2
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("same")), "different-\(expected)")
            let detailed = try parse(exported(log, .csv))
            let decisions = detailed.filter { $0[1] == "Same-name file selection (intermediate)" }
            XCTAssertEqual(decisions.count, 2)
            let final = try XCTUnwrap(detailed.first { $0[1] == "Same-name file final selection" })
            XCTAssertEqual(final[3], inputs[expected].path); XCTAssertTrue(final[7].contains("finalized output"))
            if policy == .newer {
                XCTAssertTrue(decisions[0][6].contains(".123456781")); XCTAssertTrue(decisions[0][6].contains(".123456780"))
                XCTAssertTrue(final[6].contains(".123456780")); XCTAssertTrue(final[6].contains(".123456781")); XCTAssertTrue(final[6].contains(".123456782"))
                XCTAssertTrue(decisions[1][6].contains(".123456782")); XCTAssertTrue(decisions[1][6].contains(".123456781"))
            }
            let summary = try parse(exported(log, .csv, kind: .summary), columns: 5)
            let copies = summary.filter { $0[0] == "Copy" && $0[2].hasSuffix("/same") }
            XCTAssertEqual(copies.count, 1); XCTAssertEqual(copies[0][1], inputs[expected].appendingPathComponent("same").path)
            try assertLogs(log, finalized: true, copies: 2)
            try clearOutput(destination)
        }
    }
    func testFailuresCancellationAndPublicationRaces() throws {
        try write(0, "same", "a"); try write(1, "same", "b")
        for mode in ["conflict", "race", "cancel", "rollback", "cleanup", "io", "scan"] {
            let engine = MergeEngine(), token = CancellationToken()
            if mode == "race" { engine.beforeCommit = { try Data().write(to: self.destination.appendingPathComponent("competitor")) } }
            if mode == "cancel" { engine.beforeCommit = { token.cancel() } }
            if mode == "rollback" {
                try write(0, "aaa", "first")
                engine.beforePublishItem = { name, index in if index == 1 { try Data().write(to: self.destination.appendingPathComponent(name)) } }
            }
            if mode == "cleanup" { engine.beforeCommit = {
                for url in try FileManager.default.contentsOfDirectory(at: self.destination, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: url) }
                throw MergeError("synthetic cleanup failure")
            } }
            let (log, result) = run(mode == "conflict" ? .stop : .later, engine: engine, token: token, event: { e in
                if mode == "scan" && e.kind == .fileSelected { token.cancel() }
                if mode == "io" && e.kind == .phase && e.message == L("Build in temporary folder") { try! FileManager.default.removeItem(at: self.inputs[1].appendingPathComponent("same")) }
            })
            XCTAssertNil(result.output)
            XCTAssertEqual(result.status, mode == "cancel" || mode == "scan" ? .cancelled : .failure)
            if mode == "cleanup" { XCTAssertTrue(result.cleanupFailed); XCTAssertFalse(result.remainingPaths.isEmpty) }
            try assertLogs(log, finalized: false, copies: 0)
            let rows = try parse(exported(log, .csv))
            XCTAssertTrue(rows.contains { $0[1] == "Error" || $0[1] == "Cancellation" })
            if mode == "conflict" {
                let errors = rows.filter { $0[1] == "Error" }
                XCTAssertEqual(errors.count, 1)
                XCTAssertEqual(errors[0][2], "same")
                XCTAssertEqual(errors[0][3], inputs[0].path)
                XCTAssertEqual(errors[0][4], inputs[1].path)
                XCTAssertTrue(errors[0][5].contains("Rejected") == false)
                XCTAssertFalse(errors[0][7].isEmpty)
                let summaryRows = try parse(exported(log, .csv, kind: .summary), columns: 5)
                XCTAssertEqual(summaryRows.filter { $0[0] == "Error" }.count, 1)
                let summaryText = String(decoding: try exported(log, .txt, kind: .summary), as: UTF8.self)
                XCTAssertTrue(summaryText.contains("Error: Different same-name files"))
                XCTAssertFalse(summaryText.contains("。;"))
            }
            if mode == "scan" { XCTAssertTrue(rows.contains { $0[7].contains("Scan incomplete") }) }
            if mode == "rollback" { XCTAssertTrue(rows.contains { $0[1] == "Rollback" }) }
            if mode == "io" { try write(1, "same", "b") }
            try clearOutput(destination)
        }
    }
    func testRollbackFailureListsRemainingPaths() throws {
        try write(0, "aaa", "synthetic first"); try write(0, "zzz", "synthetic last")
        let engine = MergeEngine()
        engine.beforePublishItem = { name, index in
            if index == 1 {
                let temporary = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: self.destination, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".foldermerger-") })
                try Data("block rollback".utf8).write(to: temporary.appendingPathComponent("aaa"))
                try Data("competitor".utf8).write(to: self.destination.appendingPathComponent(name))
            }
        }
        let (log, result) = run(engine: engine)
        XCTAssertTrue(result.cleanupFailed); XCTAssertNil(result.output)
        XCTAssertTrue(result.remainingPaths.contains(destination.appendingPathComponent("aaa").path))
        for kind in MergeLogKind.allCases {
            let txt = String(decoding: try exported(log, .txt, kind: kind), as: UTF8.self)
            XCTAssertTrue(txt.contains("cleanup or rollback failed"))
            XCTAssertFalse(txt.contains("Nothing was added"))
            for path in result.remainingPaths { XCTAssertTrue(txt.contains(path)); XCTAssertTrue(FileManager.default.fileExists(atPath: path)) }
        }
    }
    func testUnicodeSpellingRecordsActualSource() throws {
        let first = "café.txt", later = "cafe\u{301}.txt"
        try write(0, first, "first"); try write(1, later, "later")
        var copyEvents: [MergeEvent] = []
        let req = request(), log = MergeLog(request: req, detailed: false, language: "en")
        let result = MergeEngine().run(req, logEvent: { log.record($0); if $0.kind == .copied { copyEvents.append($0) } }); log.finish(result)
        let actualNames = try FileManager.default.contentsOfDirectory(atPath: inputs[1].path)
        let actual = inputs[1].path + "/" + actualNames[0]
        let selected = try XCTUnwrap(copyEvents.first { $0.sourceInput == inputs[1] })
        XCTAssertEqual(Array(selected.sourceFile!.path.utf8), Array(actual.utf8))
        let rows = try parse(exported(log, .csv, kind: .summary), columns: 5)
        XCTAssertTrue(rows.contains { Array($0[1].utf8) == Array(actual.utf8) })
    }
    func testCSVProtectionAndRestorationBothSchemas() throws {
        for ids in [MergeLog.csvColumnIdentifiers, MergeLog.summaryColumnIdentifiers] {
            for lead in ["=", "+", "-", "@", "\t", "\r", "\n", "＝", "＋", "－", "＠", " \u{200B}="] {
                let originals = ids.map { lead + $0 + "日本語,\"資料\"\r\n" }
                let data = Data([0xef, 0xbb, 0xbf]) + Data(MergeLog.csv(originals, identifiers: ids).utf8)
                let row = try XCTUnwrap(parse(data, columns: ids.count + 1).first)
                XCTAssertEqual(restored(row, ids), originals)
                XCTAssertEqual(row.last!, ids.joined(separator: ";"))
            }
        }
        for name in ["=日本語,\"資料\"\n", "\rname", "'quoted.txt", "＠name"] { try write(0, name, "synthetic") }
        let (log, result) = run(); XCTAssertNotNil(result.output)
        for kind in MergeLogKind.allCases {
            let rows = try parse(exported(log, .csv, kind: kind), columns: kind == .summary ? 5 : 9)
            let copies = rows.filter { $0[kind == .summary ? 0 : 1] == (kind == .summary ? "Copy" : "Copy (temporary folder)") }
            XCTAssertEqual(copies.count, 4)
            for row in copies {
                let restored = restored(row, kind == .summary ? MergeLog.summaryColumnIdentifiers : MergeLog.csvColumnIdentifiers)
                let source = restored[kind == .summary ? 1 : 3]
                XCTAssertTrue(FileManager.default.fileExists(atPath: source))
            }
        }
    }
    func testAll6101FilesStreamAndJournalLifetime() throws {
        for i in 0..<6101 { try write(0, "file\(i)", "") }
        let journalDirectory = base.appendingPathComponent("journals")
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        var log: MergeLog? = MergeLog(request: request(), detailed: false, language: "en", temporaryDirectory: journalDirectory)
        let result = MergeEngine().run(request(), logEvent: { log!.record($0) }); log!.finish(result)
        XCTAssertEqual(result.counters.copied, 6101)
        for kind in MergeLogKind.allCases {
            let rows = try parse(exported(log!, .csv, kind: kind), columns: kind == .summary ? 5 : 9)
            XCTAssertEqual(rows.filter { $0[kind == .summary ? 0 : 1] == (kind == .summary ? "Copy" : "Copy (temporary folder)") }.count, 6101)
            let txt = String(decoding: try exported(log!, .txt, kind: kind), as: UTF8.self)
            XCTAssertEqual(txt.components(separatedBy: kind == .summary ? " → " : "Operation: Copy (temporary folder)").count - 1, 6101)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: journalDirectory.path).count, 1)
        log = nil
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: journalDirectory.path).isEmpty)
    }
    func testBoundedScreenStillExportsEveryDecision() throws {
        let log = MergeLog(request: request(), detailed: false, language: "en")
        let d = ConflictingFileDecision(relativePath: "file", selectedInput: inputs[0], rejectedInputs: Array(inputs.dropFirst()), policy: .earlier, scanCompleted: true)
        var screen = ConflictingFileDecisions()
        for _ in 0..<1007 {
            screen.append(d)
            log.record(MergeEvent(timestamp: Date(), kind: .finalSelection, relativePath: d.relativePath, sourceInput: d.selectedInput, bytes: nil, attribute: nil, reason: nil, message: "", counters: MergeCounters(), selection: nil, finalSelection: d))
        }
        log.finish(MergeResult(status: .success, output: destination, counters: MergeCounters(), warnings: [], error: nil))
        XCTAssertEqual(screen.items.count, 1000); XCTAssertEqual(screen.omitted, 7)
        XCTAssertEqual(try parse(exported(log, .csv)).filter { $0[1] == "Same-name file final selection" }.count, 1007)
    }
    func testTakeoutDefaultDecisionsAndBoundedScreen() throws {
        let req = MergeRequest(inputs: inputs, output: destination)
        let takeout = "Takeout/Google Photos/Album"
        for index in 0..<3 {
            let folder = inputs[index].appendingPathComponent(takeout)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("different-\(index)".utf8).write(to: folder.appendingPathComponent("changed.jpg"))
            try Data("same".utf8).write(to: folder.appendingPathComponent("identical.json"))
            try Data("unique-\(index)".utf8).write(to: folder.appendingPathComponent("unique-\(index).txt"))
        }
        var eventKinds: [MergeEvent.Kind] = []
        let log = MergeLog(request: req, detailed: false, language: "en", temporaryDirectory: base)
        let result = MergeEngine().run(req, event: { eventKinds.append($0.kind) }, logEvent: log.record)
        log.finish(result)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.counters.copied, 5)
        XCTAssertEqual(result.counters.skipped, 2)
        let outputFolder = destination.appendingPathComponent(takeout)
        XCTAssertEqual(try String(contentsOf: outputFolder.appendingPathComponent("changed.jpg")), "different-0")
        for index in 0..<3 { XCTAssertEqual(try String(contentsOf: outputFolder.appendingPathComponent("unique-\(index).txt")), "unique-\(index)") }
        XCTAssertEqual(try String(contentsOf: outputFolder.appendingPathComponent("identical.json")), "same")
        XCTAssertEqual(eventKinds.filter { $0 == .finalSelection }.count, 1)
        let detailRows = try parse(exported(log, .csv))
        let final = try XCTUnwrap(detailRows.first { $0[1] == "Same-name file final selection" })
        XCTAssertEqual(final[3], inputs[0].path)
        XCTAssertTrue(final[4].contains(inputs[1].path))
        XCTAssertTrue(final[5].contains("Final selected:"))
        XCTAssertTrue(final[6].contains("input folder added first"))
        XCTAssertTrue(final[7].contains("Reflected in finalized output"))
        let summaryRows = try parse(exported(log, .csv, kind: .summary), columns: 5)
        let selectedCopy = try XCTUnwrap(summaryRows.first { $0[0] == "Copy" && $0[2].hasSuffix("/changed.jpg") })
        XCTAssertEqual(selectedCopy[1], inputs[0].appendingPathComponent(takeout).appendingPathComponent("changed.jpg").path)
        let summaryText = String(decoding: try exported(log, .txt, kind: .summary), as: UTF8.self)
        XCTAssertTrue(summaryText.contains("None"))
    }
    func testZeroCopySectionsSayNone() throws {
        let req = request()
        let log = MergeLog(request: req, detailed: false, language: "en", temporaryDirectory: base)
        let result = MergeEngine().run(req, logEvent: log.record)
        log.finish(result)
        let summary = String(decoding: try exported(log, .txt, kind: .summary), as: UTF8.self)
        XCTAssertEqual(summary.components(separatedBy: "None").count - 1, 2)
        XCTAssertEqual(result.counters.copied, 0)
    }
    func testJapaneseWarningsAndMissingJournalBothKinds() throws {
        try write(0, "file", "synthetic")
        let engine = MergeEngine(); engine.attributeOperation = { _, _, _ in ENOTSUP }
        let (log, result) = run(language: "ja", engine: engine)
        XCTAssertEqual(result.status, .warnings)
        try assertLogs(log, finalized: true, copies: 1, language: "ja")
        let txt = String(decoding: try exported(log, .txt), as: UTF8.self)
        XCTAssertTrue(txt.contains("統合は続行しました")); XCTAssertTrue(txt.contains("対象"))
        XCTAssertEqual(try exported(log, .csv), try exported(log, .csv))
        for language in ["en", "ja"] {
            let missing = MergeLog(request: request(), detailed: false, language: language, temporaryDirectory: base.appendingPathComponent("missing"))
            missing.finish(MergeResult(status: .cancelled, output: nil, counters: MergeCounters(), warnings: [], error: nil))
            for kind in MergeLogKind.allCases {
                for format in MergeLogFormat.allCases {
                    let text = String(decoding: try exported(missing, format, kind: kind), as: UTF8.self)
                    XCTAssertTrue(text.contains(language == "en" ? "Incomplete log" : "ログは不完全です"))
                }
            }
        }
        XCTAssertTrue(log.suggestedFilename(kind: .summary).hasPrefix("FolderMerger-summary-log-"))
    }
    // Optional output is explicitly requested by the task; fixtures remain in the temporary directory.
    func testReadableSamplesInBothLanguages() throws {
        for language in ["en", "ja"] {
            for scenario in ["ordinary", "conflict", "newer", "failure", "cancel"] {
                for root in inputs { try clearOutput(root) }
                try clearOutput(destination)
                if scenario == "ordinary" { try write(0, "photo.txt", "synthetic"); try write(1, "notes.txt", "synthetic notes") }
                else {
                    for i in 0..<3 {
                        try write(i, "photo.txt", "synthetic-\(i)")
                        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: 1_600_000_000 + i * 3600, tv_nsec: 123456789)]
                        XCTAssertEqual(utimensat(AT_FDCWD, inputs[i].appendingPathComponent("photo.txt").path, &times, AT_SYMLINK_NOFOLLOW), 0)
                    }
                }
                let policy: SamePathPolicy = scenario == "failure" ? .stop : scenario == "newer" ? .newer : .later
                let token = CancellationToken()
                let req = request(policy), log = MergeLog(request: req, detailed: false, language: language)
                let result = MergeEngine().run(req, cancellation: token, event: { event in
                    if scenario == "cancel" && event.kind == .fileSelected { token.cancel() }
                }, logEvent: log.record)
                log.finish(result)
                try assertLogs(log, finalized: result.output != nil, copies: scenario == "ordinary" ? 2 : scenario == "cancel" || scenario == "failure" ? 0 : 1, language: language)
                if let sampleRoot = ProcessInfo.processInfo.environment["FM_LOG_SAMPLE_DIR"] {
                    let folder = URL(fileURLWithPath: sampleRoot).appendingPathComponent(language).appendingPathComponent(scenario)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    for kind in MergeLogKind.allCases { for format in MergeLogFormat.allCases {
                        try log.export(to: folder.appendingPathComponent(kind.rawValue + "." + format.rawValue), format: format, kind: kind)
                    } }
                }
            }
        }
    }
}
