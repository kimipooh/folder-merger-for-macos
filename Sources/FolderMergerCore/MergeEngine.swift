import Foundation
import Darwin

public struct MergeRequest: Sendable {
    public var inputs: [URL]
    public var destination: URL
    public var name: String
    public init(inputs: [URL], destination: URL, name: String) {
        self.inputs = inputs; self.destination = destination; self.name = name
    }
    public var output: URL { destination.appendingPathComponent(name, isDirectory: true) }
}

public struct MergeProgress: Sendable {
    public let phase: String
    public let completed: Int
    public let total: Int
    public let bytesCopied: Int64
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
        try Self.validate(request)
        try cancellation.check()
        var plan: [Entry] = []
        // Swift String equality normalizes Unicode. Raw UTF-8 keys are essential here.
        var paths: [Data: Int] = [:]
        var bytes: Int64 = 0
        var scanned = 0
        func report(_ phase: String, _ completed: Int, _ total: Int) {
            progress(MergeProgress(phase: phase, completed: completed, total: total, bytesCopied: bytes))
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
            var created: [Identity: Entry] = [:]
            for (index, entry) in plan.enumerated() {
                try cancellation.check()
                let targetPath = temporary.path + "/" + entry.relative
                let target = URL(fileURLWithPath: targetPath)
                let descriptor: Int32
                let result: Int32
                if entry.directory {
                    descriptor = -1
                    result = targetPath.withCString { mkdir($0, 0o777) }
                } else {
                    descriptor = targetPath.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
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
                }
                created[Identity(try Self.info(path: targetPath))] = entry
                report("構築中", index + 1, plan.count)
            }
            try cancellation.check()
            try beforeCommit?()
            try cancellation.check()
            guard temporary.withUnsafeFileSystemRepresentation({ chmod($0!, rootMode) }) == 0 else {
                throw Self.systemError("出力フォルダの権限を設定できません", temporary)
            }
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
        var times = [entry.info.st_atimespec, entry.info.st_mtimespec]
        guard futimens(output, &times) == 0 else { throw Self.systemError("更新日時を保持できません", URL(fileURLWithPath: entry.source)) }
        guard fchmod(output, entry.info.st_mode & 0o777) == 0 else {
            throw Self.systemError("パーミッションを保持できません", URL(fileURLWithPath: entry.source))
        }
    }
}
