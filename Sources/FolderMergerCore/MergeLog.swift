import Foundation

public enum MergeLogFormat: String, CaseIterable { case csv, txt }

/// Single-worker journal. Only one record and a fixed read buffer are retained.
/// The owner releases the previous journal at the next run; deinit removes it on exit.
public final class MergeLog: @unchecked Sendable {
    public let started: Date
    public private(set) var recordingError: String?
    private let url: URL
    private var writer: FileHandle?
    private let bundle: Bundle
    private let encoder = JSONEncoder()
    private var finished = false

    public init(request: MergeRequest, detailed: Bool, language: String? = nil,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        started = Date()
        url = temporaryDirectory.appendingPathComponent("FolderMerger-log-\(UUID().uuidString).jsonl")
        bundle = language.flatMap { Bundle.module.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:)) ?? .module
        do {
            try Data().write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            writer = try FileHandle(forWritingTo: url)
        } catch { recordingError = error.localizedDescription }
        condition("Start time", Self.time(started))
        for (i, input) in request.inputs.enumerated() { condition("Input order", "\(i + 1)", input: input.path) }
        condition("Final destination", request.output.path)
        let o = request.options
        for (key, enabled) in [("File creation and modification dates", o.fileDates), ("File permissions", o.filePermissions),
                               ("Folder creation and modification dates", o.directoryDates), ("Extended attributes and resource forks", o.extendedAttributes), ("Detailed per-file log", detailed)] {
            condition(key, text(enabled ? "On" : "Off"))
        }
        condition("When different files have the same path", text(o.samePathPolicy.localizationKey))
    }
    deinit { try? writer?.close(); removeTemporaryLog() }
    /// Unlink is also safe while a worker still has the journal open during termination.
    public func removeTemporaryLog() { try? FileManager.default.removeItem(at: url) }
    private func text(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
    private func condition(_ key: String, _ value: String, input: String = "") {
        append([Self.time(started), text("Run conditions"), "", input, "", "", "", "", "", text(key) + ": " + value])
    }
    private func append(_ row: [String]) {
        guard recordingError == nil else { return }
        do {
            var data = try encoder.encode(row); data.append(10)
            try writer?.write(contentsOf: data)
        } catch { recordingError = error.localizedDescription }
    }
    public func record(_ event: MergeEvent) {
        guard !finished else { return }
        let selection = event.selection
        let action: String
        switch event.kind {
        case .fileSelected: action = "File selection"
        case .finalSelection: action = "Final selected input"
        case .conflict: action = "Conflicting items"
        case .skipped: action = "Skipped identical file"
        case .copied: action = "Copied"
        case .directoryCreated: action = "Created folder"
        case .warning: action = "Warning"
        case .error: action = "Failed"
        case .cancelled: action = "Cancelled"
        case .completed: action = "Completed"
        case .phase: action = "Phase"
        }
        append([Self.time(event.timestamp), text(action), event.relativePath ?? "",
                selection?.selectedInput.path ?? event.sourceInput?.path ?? "",
                selection?.rejectedInput.path ?? event.comparedInput?.path ?? "",
                selection == nil ? "" : text("Selected / rejected"),
                selection.map { text($0.policy.localizationKey) } ?? "",
                selection?.selectedModificationTime.map { Self.modificationTime($0) } ?? "",
                selection?.rejectedModificationTime.map { Self.modificationTime($0) } ?? "", event.message])
    }
    public func finish(_ result: MergeResult) {
        guard !finished else { return }
        let end = Date()
        let status: String
        switch result.status { case .success: status = "Completed"; case .warnings: status = "Completed with warnings"
        case .failure: status = "Failed"; case .cancelled: status = "Cancelled" }
        let c = result.counters
        let counts = String(format: text("Copied: %lld · Identical files skipped: %lld · Warnings: %lld · Errors: %lld"), c.copied, c.skipped, c.warnings, c.errors)
        let output = result.output.map { text("Output finalized") + ": " + $0.path }
            ?? text(result.cleanupFailed ? "Output not finalized; temporary folder cleanup failed." : "Output not finalized; no temporary output remains.")
        append([Self.time(end), text("Final result"), "", "", "", text(status), "", "", "", counts + "; " + output])
        append([Self.time(end), text("Final result"), "", "", "", "", "", "", "", text("End time") + ": " + Self.time(end)])
        finished = true
        do { try writer?.close() } catch { recordingError = error.localizedDescription }
        writer = nil
    }
    public var suggestedFilename: String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        return "FolderMerger-log-" + f.string(from: started)
    }
    public func export(to destination: URL, format: MergeLogFormat) throws {
        guard finished else { throw CocoaError(.fileWriteUnknown) }
        // NSSavePanel owns replacement approval. Conversion writes to an adjacent temporary
        // file first, so errors never truncate an existing export.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".FolderMerger-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data().write(to: temporary, options: .withoutOverwriting)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        func write(_ s: String) throws { try output.write(contentsOf: Data(s.utf8)) }
        let headings = ["Time", "Action", "Relative Path", "Input", "Compared With", "Decision", "Applied Rule", "Input Modified", "Compared Modified", "Details"].map(text)
        func csv(_ row: [String]) -> String {
            row.map { value in
                value.rangeOfCharacter(from: CharacterSet(charactersIn: ",\"\r\n")) != nil ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }.joined(separator: ",") + "\r\n"
        }
        if format == .csv { try output.write(contentsOf: Data([0xef, 0xbb, 0xbf])); try write(csv(headings)) }
        else { try write(text("Run conditions") + "\n") }
        if let recordingError {
            let warning = text("Incomplete log") + ": " + recordingError
            if format == .csv { try write(csv(["", text("Warning"), "", "", "", "", "", "", "", warning])) }
            else { try write(warning + "\n") }
        }
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: url) }
        catch {
            guard recordingError != nil else { throw error }
            try output.close()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
            return
        }
        defer { try? input.close() }
        var buffer = Data()
        var section = text("Run conditions")
        func row(_ data: Data) throws {
            let values = try JSONDecoder().decode([String].self, from: data)
            if format == .csv { try write(csv(values)); return }
            let next = values[1] == text("Run conditions") ? text("Run conditions") : values[1] == text("Final result") ? text("Final result") : text("Activity log (chronological)")
            if next != section { section = next; try write("\n" + section + "\n") }
            // Keep each event on one physical TXT line even for unusual filenames.
            try write(zip(headings, values).filter { !$0.1.isEmpty }.map { $0.0 + ": " + $0.1.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") }.joined(separator: " | ") + "\n")
        }
        while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                try row(Data(buffer[..<newline])); buffer.removeSubrange(...newline)
            }
        }
        if !buffer.isEmpty && recordingError == nil { throw CocoaError(.fileReadCorruptFile) }
        try output.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
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
