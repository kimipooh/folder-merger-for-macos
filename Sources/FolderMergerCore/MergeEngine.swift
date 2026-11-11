import Foundation
import Darwin

public struct MergeRequest: Sendable {
    public var inputs: [URL]
    public var destination: URL
    public var name: String
    public var options: MergeOptions
    public init(inputs: [URL], destination: URL, name: String, options: MergeOptions = MergeOptions()) {
        self.inputs = inputs; self.destination = destination; self.name = name; self.options = options
    }
    public var output: URL { destination.appendingPathComponent(name, isDirectory: true) }
}

public struct MergeProgress: Sendable {
    public let phase: String
    public let completed: Int
    public let total: Int
    public let bytesCopied: Int64
    public let currentItem: String
    public let counters: MergeCounters
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
    func check() throws { if isCancelled { throw MergeError("統合をキャンセルしました。", kind: .cancelled) } }
}

public struct MergeError: LocalizedError {
    public enum Kind: Sendable, Equatable { case failure, cancelled }
    public let message: String
    public let kind: Kind
    public init(_ message: String, kind: Kind = .failure) { self.message = message; self.kind = kind }
    public var errorDescription: String? { message }
}

private struct Identity: Hashable {
    let device: dev_t
    let inode: ino_t
    init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
}

private struct Entry {
    let relative: String
    let source: String
    let root: URL
    let info: stat
    var directory: Bool { info.st_mode & S_IFMT == S_IFDIR }
}

public final class MergeEngine {
    private let chunkSize = 1_048_576
    // Tests inject a competing creation at the actual publication boundary.
    var beforeCommit: (() throws -> Void)?
    // A narrow, injectable attribute syscall boundary. Return errno, or zero on success.
    var attributeOperation: (String, String, () -> Int32) -> Int32 = { _, _, operation in operation() }
    public init() {}

    public static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name != "." && name != ".." &&
        !name.contains("/") && !name.contains(":") && !name.contains("\0")
    }

    private static func info(_ url: URL, follow: Bool = false) throws -> stat {
        try info(path: url.path, follow: follow)
    }

    private static func info(path: String, follow: Bool = false) throws -> stat {
        var value = stat()
        let result = path.withCString { fstatat(AT_FDCWD, $0, &value, follow ? 0 : AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else { throw systemError("項目を確認できません", URL(fileURLWithPath: path)) }
        return value
    }

    private static func systemError(_ action: String, _ url: URL, code: Int32 = errno) -> MergeError {
        MergeError("\(action): \(url.path)\n\(String(cString: strerror(code)))")
    }

    private static func exists(_ url: URL) -> Bool {
        var value = stat()
        return url.withUnsafeFileSystemRepresentation { lstat($0!, &value) == 0 }
    }

    private static func ancestors(_ url: URL) throws -> Set<Identity> {
        var path = url.resolvingSymlinksInPath().standardizedFileURL
        var result = Set<Identity>()
        while true {
            let inserted = result.insert(Identity(try info(path, follow: true))).inserted
            if !inserted || path.path == "/" { return result }
            let parent = path.deletingLastPathComponent()
            if parent.path == path.path { return result }
            path = parent
        }
    }

    // This is read-only and may also be used by the GUI before enabling Merge.
    public static func validate(_ request: MergeRequest) throws {
        guard !request.inputs.isEmpty else { throw MergeError("入力フォルダを追加してください。") }
        guard validName(request.name) else { throw MergeError("出力名は空白だけにせず、.、..、/、:、NUL を使わない単一のフォルダ名にしてください。") }
        let parent = try info(request.destination, follow: true)
        guard parent.st_mode & S_IFMT == S_IFDIR else {
            throw MergeError("保存先親フォルダを選択してください: \(request.destination.path)")
        }
        guard !exists(request.output) else {
            throw MergeError("出力先に同名の項目が既に存在します: \(request.output.path)")
        }
        var roots: [(URL, Identity, Set<Identity>)] = []
        let destinationAncestors = try ancestors(request.destination)
        for input in request.inputs {
            let value = try info(input, follow: true)
            guard value.st_mode & S_IFMT == S_IFDIR else { throw MergeError("入力がフォルダではありません: \(input.path)") }
            let id = Identity(value)
            let chain = try ancestors(input)
            for (other, otherID, otherChain) in roots {
                if chain.contains(otherID) || otherChain.contains(id) {
                    throw MergeError("入力フォルダが重複または入れ子です:\n\(other.path)\n\(input.path)")
                }
            }
            if destinationAncestors.contains(id) {
                throw MergeError("保存先親フォルダまたは出力先が入力内にあります:\n\(input.path)\n\(request.destination.path)\n\(request.output.path)")
            }
            roots.append((input, id, chain))
        }
        for input in request.inputs {
            if try info(input).st_mode & S_IFMT == S_IFLNK {
                throw MergeError("入力ルートのシンボリックリンクは使用できません: \(input.path)")
            }
        }
    }

    public func merge(_ request: MergeRequest, cancellation: CancellationToken = CancellationToken(),
                      progress: (MergeProgress) -> Void = { _ in }) throws -> URL {
        let result = run(request, cancellation: cancellation, progress: progress)
        if let output = result.output { return output }
        throw result.error ?? MergeError("統合に失敗しました。")
    }

    public func run(_ request: MergeRequest, cancellation: CancellationToken = CancellationToken(),
                    detailedLog: Bool = false, event: @escaping (MergeEvent) -> Void = { _ in },
                    progress: (MergeProgress) -> Void = { _ in }) -> MergeResult {
        let context = EventContext(detailed: detailedLog, sink: event)
        do {
            let output = try execute(request, cancellation: cancellation, context: context, progress: progress)
            let status: MergeStatus = context.warnings.isEmpty ? .success : .warnings
            context.emit(.completed, message: status.label)
            return MergeResult(status: status, output: output, counters: context.counters, warnings: context.warnings, error: nil)
        } catch {
            let failure = (error as? MergeError) ?? MergeError(error.localizedDescription)
            let cancelled = failure.kind == .cancelled
            if !cancelled { context.counters.errors += 1 }
            context.emit(cancelled ? .cancelled : .error, message: failure.localizedDescription)
            let status: MergeStatus = cancelled ? .cancelled : .failure
            context.emit(.completed, message: status.label)
            return MergeResult(status: status, output: nil, counters: context.counters, warnings: context.warnings, error: failure)
        }
    }

    private func execute(_ request: MergeRequest, cancellation: CancellationToken, context: EventContext,
                         progress: (MergeProgress) -> Void) throws -> URL {
        context.emit(.phase, message: "入力を検証・走査")
        try Self.validate(request)
        try cancellation.check()
        var plan: [Entry] = []
        // Swift String equality normalizes Unicode. Raw UTF-8 keys are essential here.
        var paths: [Data: Int] = [:]
        var bytes: Int64 = 0
        var scanned = 0
        var currentItem = ""
        func report(_ phase: String, _ completed: Int, _ total: Int) {
            progress(MergeProgress(phase: phase, completed: completed, total: total, bytesCopied: bytes, currentItem: currentItem, counters: context.counters))
        }
        func conflict(_ a: Entry, _ b: Entry) -> MergeError {
            MergeError("項目が衝突しています:\n相対パス: \(a.relative)\n入力: \(a.root.path)\n相対パス: \(b.relative)\n入力: \(b.root.path)")
        }
        func scan(_ directory: String, root: URL, prefix: String) throws {
            try cancellation.check()
            guard let stream = opendir(directory) else {
                throw Self.systemError("入力フォルダを走査できません", URL(fileURLWithPath: directory))
            }
            defer { closedir(stream) }
            var names: [String] = []
            while true {
                try cancellation.check()
                errno = 0
                guard let item = readdir(stream) else {
                    if errno != 0 { throw Self.systemError("入力フォルダを走査できません", URL(fileURLWithPath: directory)) }
                    break
                }
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name != "." && name != ".." { names.append(name) }
            }
            for name in names {
                try cancellation.check()
                if name == ".DS_Store" { continue }
                let url = directory + "/" + name
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                currentItem = relative
                let value = try Self.info(path: url)
                let kind = value.st_mode & S_IFMT
                guard kind == S_IFDIR || kind == S_IFREG else {
                    throw MergeError("シンボリックリンクまたは非対応の特殊ファイルです:\n相対パス: \(relative)\n入力: \(root.path)\n\(url)")
                }
                let entry = Entry(relative: relative, source: url, root: root, info: value)
                let key = Data(relative.utf8)
                if let index = paths[key] {
                    let previous = plan[index]
                    guard previous.directory == entry.directory else { throw conflict(previous, entry) }
                    if !entry.directory {
                        guard previous.info.st_size == value.st_size else { throw conflict(previous, entry) }
                        let equal = try equalFiles(previous.source, url, cancellation: cancellation) {
                            report("内容を比較中", scanned, 0)
                        }
                        guard equal else { throw conflict(previous, entry) }
                        context.counters.skipped += 1
                        context.detail(.skipped, entry: entry, bytes: Int64(value.st_size), message: "同一ファイルを省略")
                    }
                } else {
                    paths[key] = plan.count
                    plan.append(entry)
                }
                scanned += 1
                report("入力を走査中", scanned, 0)
                if entry.directory { try scan(url, root: root, prefix: relative) }
            }
        }
        for input in request.inputs { try scan(input.path, root: input, prefix: "") }
        try cancellation.check()
        let temporary = request.destination.appendingPathComponent(".\(request.name).foldermerger-\(UUID().uuidString).tmp", isDirectory: true)
        guard temporary.withUnsafeFileSystemRepresentation({ mkdir($0!, 0o777) }) == 0 else {
            throw Self.systemError("一時フォルダを作成できません", temporary)
        }
        // mkdir applies the process umask. Keep this default mode for publication,
        // while restricting the unpublished construction tree to its owner.
        let rootMode = try Self.info(temporary).st_mode & 0o777
        guard temporary.withUnsafeFileSystemRepresentation({ chmod($0!, 0o700) }) == 0 else {
            let error = Self.systemError("一時フォルダを保護できません", temporary)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        do {
            context.emit(.phase, message: "一時フォルダで構築")
            var created: [Identity: Entry] = [:]
            for (index, entry) in plan.enumerated() {
                currentItem = entry.relative
                try cancellation.check()
                let targetPath = temporary.path + "/" + entry.relative
                let target = URL(fileURLWithPath: targetPath)
                let descriptor: Int32
                let result: Int32
                if entry.directory {
                    descriptor = -1
                    result = targetPath.withCString { mkdir($0, 0o777) }
                } else {
                    descriptor = targetPath.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o666) }
                    result = descriptor < 0 ? -1 : 0
                }
                if result != 0 {
                    let code = errno
                    if code == EEXIST, let existing = try? Self.info(path: targetPath), let previous = created[Identity(existing)] {
                        throw conflict(previous, entry)
                    }
                    throw Self.systemError("出力項目を排他的に作成できません（入力: \(entry.root.path)、相対パス: \(entry.relative)）", target, code: code)
                }
                if !entry.directory {
                    defer { close(descriptor) }
                    try copy(entry, to: descriptor, cancellation: cancellation) { amount in
                        bytes += Int64(amount)
                        report("コピー中", index, plan.count)
                    }
                    context.counters.copied += 1
                    context.detail(.copied, entry: entry, bytes: Int64(entry.info.st_size), message: "コピー")
                    try applyAttributes(entry, target: targetPath, options: request.options, context: context)
                } else {
                    context.detail(.directoryCreated, entry: entry, message: "フォルダ作成")
                }
                created[Identity(try Self.info(path: targetPath))] = entry
                report("構築中", index + 1, plan.count)
            }
            context.emit(.phase, message: "フォルダ属性を設定（深い階層から）")
            for entry in plan.filter({ $0.directory }).sorted(by: { $0.relative.split(separator: "/").count > $1.relative.split(separator: "/").count }) {
                try cancellation.check()
                try applyAttributes(entry, target: temporary.path + "/" + entry.relative, options: request.options, context: context)
            }
            try cancellation.check()
            try beforeCommit?()
            try cancellation.check()
            guard temporary.withUnsafeFileSystemRepresentation({ chmod($0!, rootMode) }) == 0 else {
                throw Self.systemError("出力フォルダの権限を設定できません", temporary)
            }
            context.emit(.phase, message: "RENAME_EXCL で確定")
            let result = temporary.withUnsafeFileSystemRepresentation { source in
                request.output.withUnsafeFileSystemRepresentation { target in
                    renamex_np(source!, target!, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else { throw Self.systemError("出力を確定できません（既存項目は上書きしません）", request.output) }
            return request.output
        } catch {
            // All I/O is synchronous on this worker. File descriptors are closed before cleanup.
            do { try FileManager.default.removeItem(at: temporary) }
            catch let cleanupError {
                throw MergeError("\(error.localizedDescription)\n一時フォルダを削除できません: \(temporary.path)\n\(cleanupError.localizedDescription)")
            }
            throw error
        }
    }

    private func openSource(_ path: String) throws -> Int32 {
        let url = URL(fileURLWithPath: path)
        let fd = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else { throw Self.systemError("入力を開けません", url) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
            close(fd); throw MergeError("入力が通常ファイルではありません: \(url.path)")
        }
        return fd
    }

    private func readChunk(_ fd: Int32, into buffer: inout [UInt8], url: String) throws -> Int {
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count >= 0 { return count }
            if errno != EINTR { throw Self.systemError("入力を読み取れません", URL(fileURLWithPath: url)) }
        }
    }

    private func equalFiles(_ a: String, _ b: String, cancellation: CancellationToken, tick: () -> Void) throws -> Bool {
        let left = try openSource(a); defer { close(left) }
        let right = try openSource(b); defer { close(right) }
        var bufferA = [UInt8](repeating: 0, count: chunkSize)
        var bufferB = bufferA
        while true {
            try cancellation.check()
            let ca = try readChunk(left, into: &bufferA, url: a)
            let cb = try readChunk(right, into: &bufferB, url: b)
            tick()
            guard ca == cb, bufferA.prefix(ca).elementsEqual(bufferB.prefix(cb)) else { return false }
            if ca == 0 { return true }
        }
    }

    private func copy(_ entry: Entry, to output: Int32, cancellation: CancellationToken, tick: (Int) -> Void) throws {
        let input = try openSource(entry.source); defer { close(input) }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try cancellation.check()
            let count = try readChunk(input, into: &buffer, url: entry.source)
            if count == 0 { break }
            try buffer.withUnsafeBytes { data in
                var offset = 0
                while offset < count {
                    try cancellation.check()
                    let written = Darwin.write(output, data.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw Self.systemError("コピーを書き込めません", URL(fileURLWithPath: entry.source)) }
                    offset += written
                }
            }
            tick(count)
        }
    }

    private func applyAttributes(_ entry: Entry, target: String, options: MergeOptions, context: EventContext) throws {
        func apply(_ attribute: String, _ operation: () -> Int32) throws {
            let code = attributeOperation(entry.relative, attribute, operation)
            if code == ENOTSUP || code == EOPNOTSUPP {
                let warning = AttributeWarning(relativePath: entry.relative, attribute: attribute, reason: String(cString: strerror(code)))
                context.warnings.append(warning); context.counters.warnings += 1
                context.emit(.warning, relative: entry.relative, source: entry.root, attribute: attribute, reason: warning.reason, message: "\(attribute): \(warning.reason)")
            } else if code != 0 {
                throw Self.systemError("属性 \(attribute) を設定できません（相対パス: \(entry.relative)）", URL(fileURLWithPath: target), code: code)
            }
        }
        if options.extendedAttributes {
            // Read failures are fatal; only destination application ENOTSUP is downgraded.
            let size = listxattr(entry.source, nil, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { throw Self.systemError("拡張属性を列挙できません", URL(fileURLWithPath: entry.source)) }
            if size > 0 {
                var names = [CChar](repeating: 0, count: size)
                let count = listxattr(entry.source, &names, size, XATTR_NOFOLLOW)
                guard count >= 0 else { throw Self.systemError("拡張属性を列挙できません", URL(fileURLWithPath: entry.source)) }
                for raw in names.prefix(count).split(separator: 0) {
                    let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    let length = getxattr(entry.source, name, nil, 0, 0, XATTR_NOFOLLOW)
                    guard length >= 0 else { throw Self.systemError("拡張属性を読めません", URL(fileURLWithPath: entry.source)) }
                    var data = [UInt8](repeating: 0, count: length)
                    let read = data.withUnsafeMutableBytes { getxattr(entry.source, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
                    guard read == length else { throw Self.systemError("拡張属性を読めません", URL(fileURLWithPath: entry.source)) }
                    try apply(name) {
                        let result = data.withUnsafeBytes { setxattr(target, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
                        return result == 0 ? 0 : errno
                    }
                }
            }
        }
        if !entry.directory && options.filePermissions {
            try apply("権限ビット") { chmod(target, entry.info.st_mode & 0o777) == 0 ? 0 : errno }
        }
        if entry.directory ? options.directoryDates : options.fileDates {
            try apply("変更日") {
                var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), entry.info.st_mtimespec]
                return utimensat(AT_FDCWD, target, &times, AT_SYMLINK_NOFOLLOW) == 0 ? 0 : errno
            }
            try apply("作成日") {
                var attributes = attrlist()
                attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
                var time = entry.info.st_birthtimespec
                return setattrlist(target, &attributes, &time, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW)) == 0 ? 0 : errno
            }
        }
    }
}

public struct MergeOptions: Sendable, Equatable {
    public var fileDates: Bool
    public var filePermissions: Bool
    public var directoryDates: Bool
    public var extendedAttributes: Bool
    public init(fileDates: Bool = true, filePermissions: Bool = true, directoryDates: Bool = false, extendedAttributes: Bool = false) {
        self.fileDates = fileDates; self.filePermissions = filePermissions
        self.directoryDates = directoryDates; self.extendedAttributes = extendedAttributes
    }
    public var descriptions: [String] {
        [("ファイルの作成日・変更日", fileDates), ("ファイルのアクセス権", filePermissions),
         ("フォルダの作成日・変更日", directoryDates), ("拡張属性・リソースフォーク", extendedAttributes)]
            .map { "\($0.0): \($0.1 ? "保持" : "保持しない")" }
    }
}

public enum MergeStatus: Sendable { case success, warnings, failure, cancelled
    public var label: String {
        switch self { case .success: return "完了"; case .warnings: return "警告ありで完了"
        case .failure: return "失敗"; case .cancelled: return "キャンセル" }
    }
}
public struct MergeCounters: Sendable {
    public internal(set) var copied = 0
    public internal(set) var skipped = 0
    public internal(set) var warnings = 0
    public internal(set) var errors = 0
    public init() {}
    public var description: String { "コピー \(copied) 件・同一ファイル省略 \(skipped) 件・警告 \(warnings) 件・エラー \(errors) 件" }
}
public struct AttributeWarning: Sendable {
    public let relativePath: String
    public let attribute: String
    public let reason: String
}
public struct MergeResult {
    public let status: MergeStatus
    public let output: URL?
    public let counters: MergeCounters
    public let warnings: [AttributeWarning]
    public let error: MergeError?
}
public struct MergeEvent: Sendable {
    public enum Kind: Sendable { case phase, directoryCreated, copied, skipped, warning, error, cancelled, completed }
    public let timestamp: Date
    public let kind: Kind
    public let relativePath: String?
    public let sourceInput: URL?
    public let bytes: Int64?
    public let attribute: String?
    public let reason: String?
    public let message: String
    public let counters: MergeCounters
    public var line: String {
        "\(timestamp.formatted(date: .omitted, time: .standard)) \(message)\(relativePath.map { " \($0)" } ?? "")\(sourceInput.map { " ← \($0.path)" } ?? "")\(bytes.map { " (\($0) bytes)" } ?? "")"
    }
}
private final class EventContext {
    let detailed: Bool
    let sink: (MergeEvent) -> Void
    var counters = MergeCounters()
    var warnings: [AttributeWarning] = []
    init(detailed: Bool, sink: @escaping (MergeEvent) -> Void) { self.detailed = detailed; self.sink = sink }
    func emit(_ kind: MergeEvent.Kind, relative: String? = nil, source: URL? = nil, bytes: Int64? = nil, attribute: String? = nil, reason: String? = nil, message: String) {
        sink(MergeEvent(timestamp: Date(), kind: kind, relativePath: relative, sourceInput: source, bytes: bytes, attribute: attribute, reason: reason, message: message, counters: counters))
    }
    func detail(_ kind: MergeEvent.Kind, entry: Entry, bytes: Int64? = nil, message: String) {
        if detailed { emit(kind, relative: entry.relative, source: entry.root, bytes: bytes, message: message) }
    }
}
public struct ExecutionStep: Sendable {
    public let text: String
    public let arguments: [String]?
}
public struct MergePlanDescription: Sendable {
    public let request: MergeRequest
    public let steps: [ExecutionStep]
    public init(request: MergeRequest) {
        self.request = request
        let lines = request.inputs.enumerated().map { "入力 \($0.offset + 1)（属性の優先順）: \($0.element.path)" }
            + ["確定先: \(request.output.path)"] + request.options.descriptions + [
                "入力不変・非上書き。内容はバイト比較し、同一相対パスの同一ファイルを1件にまとめ、ファイル・フォルダの属性は先頭入力から採用。",
                "内容差・ファイル/フォルダ・保存先 FS の名前衝突は中止。.DS_Store は全階層で除外。",
                "コピー方式: POSIX open/read/write（1 MiB チャンク）。外部コマンドなし。",
                "同一ボリュームの一時フォルダに排他的に作成。選択した属性のみ適用: 内容 → 拡張属性 → ファイル権限 → 変更日 → 作成日。フォルダ属性は子の完了後、深い順。出力ルートは新規作成。",
                "成功時のみ RENAME_EXCL で確定。失敗・キャンセル時は一時フォルダを後片付け。属性非対応は警告で継続、それ以外は中止。"
            ]
        steps = lines.map { ExecutionStep(text: $0, arguments: nil) }
    }
}
