import Foundation

public enum MergeLogKind: String, CaseIterable { case summary, detailed }
public enum MergeLogFormat: String, CaseIterable { case csv, txt }

/// One worker owns the journal. Export retains a fixed buffer and one record, never all events.
public final class MergeLog: @unchecked Sendable {
    private struct Record: Codable {
        let type: String
        var values: [String]
        var outputFinalized: Bool? = nil
    }
    public let started = Date()
    public private(set) var recordingError: String?
    private let url: URL
    private let bundle: Bundle
    private let destination: URL
    private var writer: FileHandle?
    private var finished = false
    private var outputFinalized = false
    private var cleanupFailed = false
    private var finalizedCopyCount = 0
    private var decisionCount = 0
    private var pendingConflict: [String]?
    private var finalRows: [[String]] = []
    private var summaryResult = ""
    static let csvColumnIdentifiers = ["time", "action", "relative_path", "source", "destination", "decision", "reason", "notes"]
    static let summaryColumnIdentifiers = ["category", "source", "destination", "details"]

    public init(request: MergeRequest, detailed: Bool, language: String? = nil,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        destination = request.output
        url = temporaryDirectory.appendingPathComponent("FolderMerger-log-\(UUID().uuidString).jsonl")
        bundle = language.flatMap { Bundle.module.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:)) ?? .module
        do {
            try Data().write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            writer = try FileHandle(forWritingTo: url)
        } catch { recordingError = error.localizedDescription }
        condition("Start time", Self.time(started))
        for (i, input) in request.inputs.enumerated() { condition("Input order", "\(i + 1)", input: input.path) }
        let o = request.options
        for (key, enabled) in [("File creation and modification dates", o.fileDates), ("File permissions", o.filePermissions),
                               ("Folder creation and modification dates", o.directoryDates), ("Extended attributes and resource forks", o.extendedAttributes), ("Detailed per-file log (screen display)", detailed)] {
            condition(key, text(enabled ? "On" : "Off"))
        }
        condition("When different files have the same path", text(o.samePathPolicy.localizationKey))
    }
    deinit { try? writer?.close(); removeTemporaryLog() }
    public func removeTemporaryLog() { try? FileManager.default.removeItem(at: url) }
    private func text(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
    private func condition(_ key: String, _ value: String, input: String = "") {
        append("condition", [Self.time(started), text("Inputs and settings"), "", input, "", "", text(key) + ": " + value, ""])
    }
    private func append(_ type: String, _ row: [String]) {
        guard recordingError == nil else { return }
        do {
            var data = try JSONEncoder().encode(Record(type: type, values: row, outputFinalized: type == "result" ? outputFinalized : nil)); data.append(10)
            try writer?.write(contentsOf: data)
        } catch { recordingError = error.localizedDescription }
    }
    public func record(_ e: MergeEvent) {
        guard !finished else { return }
        var row = [Self.time(e.timestamp), "", e.relativePath ?? "", e.sourceFile?.path ?? e.sourceInput?.path ?? "",
                   e.destinationFile?.path ?? e.comparedInput?.path ?? "", "", "", ""]
        var type = "activity"
        switch e.kind {
        case .copied: type = "copy"; row[1] = text("Copy (temporary folder)"); row[7] = text("Planned copy destination (still inside the temporary folder at this point).")
        case .directoryCreated: row[1] = text("Create folder (temporary folder)")
        case .skipped: row[1] = text("Skip identical content")
        case .fileSelected:
            row[1] = text("Same-name file selection (intermediate)")
            if let s = e.selection {
                row[3] = s.selectedInput.path; row[4] = s.rejectedInput.path
                row[5] = selectionDecision(selected: s.selectedInput.path, rejected: [s.rejectedInput.path])
                row[6] = selectionReason(s.policy)
                if let selected = s.selectedModificationTime, let rejected = s.rejectedModificationTime {
                    row[6] = String(format: text("The selected file has a newer modification time (selected: %@ = %@; rejected: %@ = %@)."), s.selectedInput.path, Self.modificationTime(selected), s.rejectedInput.path, Self.modificationTime(rejected))
                }
            }
        case .finalSelection:
            type = "selection"; decisionCount += 1
            row[1] = text("Same-name file final selection")
            if let d = e.finalSelection {
                row[3] = d.selectedInput.path; row[4] = d.rejectedInputs.map(\.path).joined(separator: "; ")
                row[5] = selectionDecision(selected: d.selectedInput.path, rejected: d.rejectedInputs.map(\.path), final: true)
                row[6] = selectionReason(d.policy)
                if let selectedTime = d.selectedModificationTime {
                    let rejectedTimes = zip(d.rejectedInputs, d.rejectedModificationTimes).map { "\($0.path) = \(Self.modificationTime($1))" }.joined(separator: "; ")
                    row[6] = String(format: text("The selected file has a newer modification time (selected: %@ = %@; rejected: %@)."), d.selectedInput.path, Self.modificationTime(selectedTime), rejectedTimes)
                }
                row[7] = text(d.scanCompleted ? "Scan complete" : "Scan incomplete; decisions so far only")
            }
        case .conflict:
            pendingConflict = [e.relativePath ?? "", e.sourceInput?.path ?? "", e.comparedInput?.path ?? "", e.message]
            return
        case .warning:
            type = "warning"; row[1] = text("Warning")
            let attributeKey: String
            switch e.attribute {
            case "権限ビット": attributeKey = "File permissions"
            case "変更日": attributeKey = "Modification date"
            case "作成日": attributeKey = "Creation date"
            default: attributeKey = "Extended attributes and resource forks"
            }
            row[6] = text(attributeKey) + ": " + text("An attribute could not be preserved. The merge continued.")
            row[7] = [e.attribute, e.reason].compactMap { $0 }.joined(separator: ": ")
        case .error:
            type = "error"; row[1] = text("Error")
            if let conflict = pendingConflict {
                row[2] = conflict[0]; row[3] = conflict[1]; row[4] = conflict[2]
                let kind = conflict[3] == "Different same-name files" ? "Different same-name files" : "File and folder name conflict"
                row[6] = String(format: text("%@ at %@ from %@ and %@; merging stopped and output was not finalized."), text(kind), conflict[0], conflict[1], conflict[2])
                row[7] = String(format: text("Conflicting items:\nRelative path: %@\nInput: %@\nRelative path: %@\nInput: %@"), conflict[0], conflict[1], conflict[0], conflict[2])
                for key in ["Modification dates are equal.", "Modification dates cannot be compared."] where e.message.contains(L(key)) {
                    row[7] += "\n" + text(key)
                }
                pendingConflict = nil
            } else {
                row[6] = text(e.logOperation ?? (e.duringFinalization ? "Output publication failed. The merge stopped." : "An input/output or validation operation failed. The merge stopped.")) + " " + text("Target") + ": " + (e.affectedPath ?? destination.path)
                row[7] = e.message
            }
        case .cancelled:
            type = "error"; row[1] = text("Cancellation"); row[6] = text("The merge was cancelled.") + " " + text("Target") + ": " + (e.affectedPath ?? destination.path)
        case .outputFinalized: row[1] = text("Finalize output"); row[7] = text("Merge destination") + ": " + destination.path
        case .rollback: row[1] = text("Rollback"); row[7] = text("Merge destination") + ": " + destination.path; row[6] = text("Published items were returned to the temporary folder.")
        case .completed: row[1] = text("Processing finished")
        case .phase:
            row[1] = text("Processing stage")
            let keys = ["Validate and scan inputs", "Build in temporary folder", "Apply folder attributes (deepest first)", "Finalize with RENAME_EXCL"]
            row[6] = keys.first { L($0) == e.message }.map { text($0 == "Finalize with RENAME_EXCL" ? "Publish output" : $0) } ?? e.message
        }
        if type == "warning" { row[6] += " " + text("Target") + ": " + (e.affectedPath ?? e.sourceInput?.appendingPathComponent(e.relativePath ?? "").path ?? e.relativePath ?? "") }
        append(type, row)
    }
    private func selectionReason(_ policy: SamePathPolicy) -> String {
        switch policy {
        case .earlier: return text("The input folder added first has priority.")
        case .later: return text("The input folder added later has priority.")
        case .newer: return text("The selected file has a newer modification time.")
        case .stop: return text("Stop when same-name files differ.")
        }
    }
    private func selectionDecision(selected: String, rejected: [String], final: Bool = false) -> String {
        String(format: text(final ? "Final selected: %@ / Rejected: %@" : "Selected: %@ / Rejected: %@"), selected, rejected.isEmpty ? text("None") : rejected.joined(separator: "; "))
    }
    private var state: String { text(outputFinalized ? "Reflected in finalized output." : "Output is not finalized.") }
    public func finish(_ result: MergeResult) {
        guard !finished else { return }
        outputFinalized = result.output != nil
        cleanupFailed = result.cleanupFailed
        finalizedCopyCount = outputFinalized ? result.counters.copied : 0
        let status: String
        switch result.status { case .success: status = "Completed"; case .warnings: status = "Completed with warnings"
        case .failure: status = "Failed"; case .cancelled: status = "Cancelled" }
        let c = result.counters
        let counts = String(format: text("Copied: %lld · Identical files skipped: %lld · Warnings: %lld · Errors: %lld"), c.copied, c.skipped, c.warnings, c.errors)
        let publication = text(outputFinalized ? "Output finalized" : result.cleanupFailed
            ? "Output is not finalized; cleanup or rollback failed. Check remaining paths."
            : "Output is not finalized. Nothing was added to the destination.")
        let remaining = result.cleanupFailed ? " " + result.remainingPaths.joined(separator: "; ") : ""
        let details = counts + "; " + String(format: text("Conflicting paths: %lld"), decisionCount) + "; " + publication + remaining
        summaryResult = text(status) + "; " + text("Copied files") + ": \(outputFinalized ? c.copied : 0); " + publication + remaining
        let destinationNote = text("Merge destination") + ": " + destination.path
        let cleanupNotes = result.cleanupFailed ? ([result.error?.localizedDescription ?? ""] + result.remainingPaths).filter { !$0.isEmpty } : []
        finalRows = [[Self.time(Date()), text("Final result"), "", "", "", text(status), details,
                      ([destinationNote] + cleanupNotes).joined(separator: "\n")]]
        for row in finalRows { append("result", row) }
        finished = true
        do { try writer?.close() } catch { recordingError = error.localizedDescription }
        writer = nil
    }
    public var suggestedFilename: String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        return "FolderMerger-log-" + f.string(from: started)
    }
    public func suggestedFilename(kind: MergeLogKind) -> String {
        suggestedFilename.replacingOccurrences(of: "FolderMerger-log-", with: "FolderMerger-" + kind.rawValue + "-log-")
    }
    private func readRows(_ body: (String, [String]) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if recordingError != nil { return }
            throw CocoaError(.fileReadNoSuchFile)
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var buffer = Data()
        while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let record = try JSONDecoder().decode(Record.self, from: Data(buffer[..<newline]))
                try body(record.type, record.values)
                buffer.removeSubrange(...newline)
            }
        }
        if !buffer.isEmpty && recordingError == nil { throw CocoaError(.fileReadCorruptFile) }
    }
    public func export(to destination: URL, format: MergeLogFormat, kind: MergeLogKind = .detailed) throws {
        guard finished else { throw CocoaError(.fileWriteUnknown) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".FolderMerger-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data().write(to: temporary, options: .withoutOverwriting)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        func write(_ s: String) throws { try output.write(contentsOf: Data(s.utf8)) }
        func escape(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") }
        let summary = kind == .summary
        let labelSeparator = text("Log label separator")
        let headings = (summary ? ["Category", "Source", "Destination", "Summary details"] : ["Time", "Operation", "Relative Path", "Source / selected input", "Destination / rejected input", "Decision", "Reason", "Notes"]).map(text)
        let identifiers = summary ? Self.summaryColumnIdentifiers : Self.csvColumnIdentifiers
        func row(_ values: [String]) throws {
            if format == .csv { try write(Self.csv(values, identifiers: identifiers)) }
            else { try write(zip(headings, values).filter { !$0.1.isEmpty }.map { $0.0 + ": " + escape($0.1) }.joined(separator: " | ") + "\n") }
        }
        func section(_ key: String) throws { if format == .txt { try write(text(key) + "\n") } }
        if format == .csv {
            try output.write(contentsOf: Data([0xef, 0xbb, 0xbf]))
            try write(Self.csv(headings, metadataHeading: text("Protected columns"), identifiers: identifiers))
        }
        try section("Final result")
        if summary && format == .txt {
            let result = finalRows.first
            let status = result?[5] ?? text("Failed")
            try write(text("Status") + labelSeparator + status + "\n")
            try write(text("Copied files") + labelSeparator + "\(finalizedCopyCount) " + text(finalizedCopyCount == 1 ? "file" : "files") + "\n")
            try write(text("Merge destination") + labelSeparator + self.destination.path + "\n")
            if outputFinalized { try write(text("Output") + labelSeparator + text("Finalized") + "\n") }
            else if !cleanupFailed { try write(text("Output") + labelSeparator + text("Not finalized. Nothing was added to the destination.") + "\n") }
            else {
                let remaining = result?[7].components(separatedBy: "\n").dropFirst().joined(separator: "; ") ?? ""
                try write(text("Output") + labelSeparator + text("Not finalized; cleanup or rollback failed. Check remaining paths.") + (remaining.isEmpty ? "" : " " + remaining) + "\n")
            }
            try write(text("Inputs and settings are available in the detailed log.") + "\n")
        } else {
            for r in finalRows { try row(summary ? [r[1], "", self.destination.path, summaryResult] : r) }
        }
        if summary {
            try section("Copied files")
            var copiedCount = 0
            if outputFinalized {
                try readRows { type, r in
                    if type == "copy" {
                        copiedCount += 1
                        if format == .txt { try write(escape(r[3]) + " → " + escape(r[4]) + "\n") }
                        else { try row([text("Copy"), r[3], r[4], ""]) }
                    }
                }
            }
            if copiedCount == 0 {
                if format == .txt { try write(text("None") + "\n") }
                else { try row([text("Copied files"), "", "", text("None")]) }
            }
            try section("Warnings and errors")
            var issueCount = 0
            try readRows { type, r in
                if type == "warning" || type == "error" {
                    issueCount += 1
                    let details = r[6] + (r[7].isEmpty ? "" : " " + text("Notes") + ": " + escape(r[7]))
                    if format == .txt { try write(text(r[1]) + ": " + escape(details) + "\n") }
                    else { try row([r[1], r[3], r[4], details]) }
                }
            }
            if issueCount == 0 {
                if format == .txt { try write(text("None") + "\n") }
                else { try row([text("Warnings and errors"), "", "", text("None")]) }
            }
        } else {
            try section("Inputs and settings")
            try readRows { type, r in if type == "condition" { try row(r) } }
            try section("Activity log (chronological)")
            try readRows { type, original in
                guard type != "condition" && type != "result" else { return }
                var r = original
                if type == "selection" {
                    r[7] = r[7].isEmpty ? state : r[7] + " · " + state
                }
                if type == "copy" { r[7] = text("Planned copy destination (still inside the temporary folder at this point).") }
                try row(r)
            }
        }
        if let recordingError {
            let message = text("Incomplete log") + ": " + recordingError
            try row(summary ? [text("Warning"), "", "", message] : ["", text("Warning"), "", "", "", "", message, ""])
        }
        try output.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
    }

    static func needsCSVProtection(_ value: String) -> Bool {
        let dangerous = CharacterSet(charactersIn: "=+-@\t\r\n＝＋－＠")
        for scalar in value.unicodeScalars {
            // Test before skipping: a leading TAB/CR/LF is itself dangerous.
            if dangerous.contains(scalar) { return true }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            switch scalar.properties.generalCategory {
            case .control, .format: continue
            default: return false
            }
        }
        return false
    }

    /// Also accepts the localized metadata heading. Its metadata describes the
    /// data headings exactly as it does ordinary data rows.
    static func csv(_ row: [String], metadataHeading: String? = nil, identifiers: [String] = csvColumnIdentifiers) -> String {
        var protected: [String] = []
        var values = row.enumerated().map { index, value in
            if needsCSVProtection(value) {
                protected.append(identifiers[index])
                return "'" + value
            }
            return value
        }
        values.append(protected.isEmpty ? (metadataHeading ?? "") : protected.joined(separator: ";"))
        return values.map { value in
            value.rangeOfCharacter(from: CharacterSet(charactersIn: ",\"\r\n")) != nil
                ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }.joined(separator: ",") + "\r\n"
    }

    static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let offset = DateFormatter()
        offset.locale = Locale(identifier: "en_US_POSIX")
        offset.calendar = Calendar(identifier: .gregorian)
        offset.timeZone = timeZone
        offset.dateFormat = "xxxxx"
        let calendar = Calendar(identifier: .gregorian)
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let nanos = localCalendar.component(.nanosecond, from: date)
        return f.string(from: date) + String(format: ".%09d", nanos) + offset.string(from: date)
    }
    static func modificationTime(_ value: FileModificationTime, timeZone: TimeZone = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(value.seconds))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let offset = DateFormatter()
        offset.locale = Locale(identifier: "en_US_POSIX")
        offset.calendar = Calendar(identifier: .gregorian)
        offset.timeZone = timeZone
        offset.dateFormat = "xxxxx"
        return f.string(from: date) + String(format: ".%09d", value.nanoseconds) + offset.string(from: date)
    }
}
