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
    func check() throws { if isCancelled { throw MergeError(L("Merge cancelled."), kind: .cancelled) } }
}

public struct MergeError: LocalizedError {
    public enum Kind: Sendable, Equatable { case failure, cancelled }
    public let message: String
    public let kind: Kind
    public let cleanupFailed: Bool
    public init(_ message: String, kind: Kind = .failure, cleanupFailed: Bool = false) { self.message = message; self.kind = kind; self.cleanupFailed = cleanupFailed }
    public var errorDescription: String? { message }
}

private struct Identity: Hashable {
    let device: dev_t
    let inode: ino_t
    init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
}

private struct Entry {
    var relative: String
    var hadDecision = false
    var rejectedInputs: [URL] = []
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
    // Timestamp boundary allows testing incomparable metadata without corrupting fixtures.
    var modificationTime: (stat) -> FileModificationTime = { FileModificationTime($0.st_mtimespec) }
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
        guard result == 0 else { throw systemError("Cannot inspect the item", URL(fileURLWithPath: path)) }
        return value
    }

    // Capture errno before any bundle lookup can change it.
    private static func systemError(_ action: String, _ url: URL, code: Int32 = errno) -> MergeError {
        MergeError(L("%@: %@\n%@", localizedText(action), url.path, String(cString: strerror(code))))
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
        guard !request.inputs.isEmpty else { throw MergeError(L("Add input folders.")) }
        guard validName(request.name) else { throw MergeError(L("Enter a single folder name that is not blank and does not contain ., .., /, :, or NUL.")) }
        let parent = try info(request.destination, follow: true)
        guard parent.st_mode & S_IFMT == S_IFDIR else {
            throw MergeError(L("Select a destination parent folder: %@", request.destination.path))
        }
        guard !exists(request.output) else {
            throw MergeError(L("An item with this name already exists at the destination: %@", request.output.path))
        }
        var roots: [(URL, Identity, Set<Identity>)] = []
        let destinationAncestors = try ancestors(request.destination)
        for input in request.inputs {
            let value = try info(input, follow: true)
            guard value.st_mode & S_IFMT == S_IFDIR else { throw MergeError(L("The input is not a folder: %@", input.path)) }
            let id = Identity(value)
            let chain = try ancestors(input)
            for (other, otherID, otherChain) in roots {
                if chain.contains(otherID) || otherChain.contains(id) {
                    throw MergeError(L("Input folders overlap or are nested:\n%@\n%@", other.path, input.path))
                }
            }
            if destinationAncestors.contains(id) {
                throw MergeError(L("The destination parent folder or output is inside an input:\n%@\n%@\n%@", input.path, request.destination.path, request.output.path))
            }
            roots.append((input, id, chain))
        }
        for input in request.inputs {
            if try info(input).st_mode & S_IFMT == S_IFLNK {
                throw MergeError(L("Symbolic links cannot be used as input roots: %@", input.path))
            }
        }
    }

    private static func normalizationInsensitive(at destination: URL, name: String) throws -> Bool {
        let probe = destination.appendingPathComponent(".foldermerger-probe-\(UUID().uuidString)")
        guard mkdir(probe.path, 0o700) == 0 else { throw systemError("Cannot create the temporary folder", probe) }
        func measure() throws -> Bool {
            let fd = open(probe.path + "/" + name.precomposedStringWithCanonicalMapping,
                          O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw systemError("Cannot create the temporary folder", probe) }
            defer { close(fd) }
            var original = stat(), alternate = stat()
            guard fstat(fd, &original) == 0 else { throw systemError("Cannot inspect the item", probe) }
            if lstat(probe.path + "/" + name, &alternate) == 0 { return Identity(original) == Identity(alternate) }
            let code = errno
            guard code == ENOENT else { throw systemError("Cannot inspect the item", probe, code: code) }
            return false
        }
        let result: Bool
        do { result = try measure() }
        catch {
            do { try FileManager.default.removeItem(at: probe) }
            catch let cleanup { throw MergeError(L("%@\nTemporary folder cleanup also failed: %@\n%@", error.localizedDescription, probe.path, cleanup.localizedDescription), cleanupFailed: true) }
            throw error
        }
        do { try FileManager.default.removeItem(at: probe) }
        catch { throw MergeError(error.localizedDescription, cleanupFailed: true) }
        return result
    }

    public func merge(_ request: MergeRequest, cancellation: CancellationToken = CancellationToken(),
                      progress: (MergeProgress) -> Void = { _ in }) throws -> URL {
        let result = run(request, cancellation: cancellation, progress: progress)
        if let output = result.output { return output }
        throw result.error ?? MergeError(L("Merge failed."))
    }

    public func run(_ request: MergeRequest, cancellation: CancellationToken = CancellationToken(),
                    detailedLog: Bool = false, event: @escaping (MergeEvent) -> Void = { _ in },
                    logEvent: @escaping (MergeEvent) -> Void = { _ in },
                    progress: (MergeProgress) -> Void = { _ in }) -> MergeResult {
        let context = EventContext(detailed: detailedLog, sink: event, logSink: logEvent)
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
            return MergeResult(status: status, output: nil, counters: context.counters, warnings: context.warnings, error: failure, cleanupFailed: context.cleanupFailed || failure.cleanupFailed)
        }
    }

    private func execute(_ request: MergeRequest, cancellation: CancellationToken, context: EventContext,
                         progress: (MergeProgress) -> Void) throws -> URL {
        context.emit(.phase, message: L("Validate and scan inputs"))
        try Self.validate(request)
        try cancellation.check()
        var plan: [Entry] = []
        // Probe the destination itself; never infer its behavior from Swift equality.
        var normalizationResults: [Data: Bool] = [:]
        func pathKey(_ path: String) throws -> Data {
            let components = try path.split(separator: "/").map { component -> String in
                let raw = String(component)
                let canonical = raw.precomposedStringWithCanonicalMapping
                let bytes = Data(raw.utf8)
                if bytes == Data(canonical.utf8) { return raw }
                let equivalent: Bool
                if let cached = normalizationResults[bytes] { equivalent = cached }
                else {
                    equivalent = try Self.normalizationInsensitive(at: request.destination, name: raw)
                    normalizationResults[bytes] = equivalent
                }
                return equivalent ? canonical : raw
            }
            return Data(components.joined(separator: "/").utf8)
        }
        var paths: [Data: Int] = [:]
        var bytes: Int64 = 0
        var scanned = 0
        var currentItem = ""
        func report(_ phase: String, _ completed: Int, _ total: Int) {
            progress(MergeProgress(phase: phase, completed: completed, total: total, bytesCopied: bytes, currentItem: currentItem, counters: context.counters))
        }
        func conflict(_ a: Entry, _ b: Entry) -> MergeError {
            context.emit(.conflict, relative: a.relative, source: a.root, compared: b.root, message: L("Conflicting items"), screen: false)
            return MergeError(L("Conflicting items:\nRelative path: %@\nInput: %@\nRelative path: %@\nInput: %@", a.relative, a.root.path, b.relative, b.root.path))
        }
        func scan(_ directory: String, root: URL, prefix: String) throws {
            try cancellation.check()
            guard let stream = opendir(directory) else {
                throw Self.systemError("Cannot scan the input folder", URL(fileURLWithPath: directory))
            }
            defer { closedir(stream) }
            var names: [String] = []
            while true {
                try cancellation.check()
                errno = 0
                guard let item = readdir(stream) else {
                    if errno != 0 { throw Self.systemError("Cannot scan the input folder", URL(fileURLWithPath: directory)) }
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
                    throw MergeError(L("Symbolic link or unsupported special file:\nRelative path: %@\nInput: %@\n%@", relative, root.path, url))
                }
                let entry = Entry(relative: relative, source: url, root: root, info: value)
                let key = try pathKey(relative)
                if let index = paths[key] {
                    let previous = plan[index]
                    guard previous.directory == entry.directory else { throw conflict(previous, entry) }
                    if !entry.directory {
                        let equal = try previous.info.st_size == value.st_size && equalFiles(previous.source, url, cancellation: cancellation) {
                            report(L("Comparing contents"), scanned, 0)
                        }
                        if equal {
                            context.counters.skipped += 1
                            context.emit(.skipped, relative: previous.relative, source: entry.root, compared: previous.root, bytes: Int64(value.st_size), message: L("Skipped identical file"), screen: context.detailed)
                        } else {
                            let policy = request.options.samePathPolicy
                            var useNext = false
                            switch policy {
                            case .stop: throw conflict(previous, entry)
                            case .earlier: break
                            case .later: useNext = true
                            case .newer:
                                let left = modificationTime(previous.info)
                                let right = modificationTime(entry.info)
                                guard left.isValid && right.isValid else {
                                    throw MergeError(conflict(previous, entry).message + "\n" + L("Modification dates cannot be compared."))
                                }
                                guard left != right else {
                                    throw MergeError(conflict(previous, entry).message + "\n" + L("Modification dates are equal."))
                                }
                                useNext = left < right
                            }
                            var selected = useNext ? entry : previous
                            selected.relative = previous.relative
                            let rejected = useNext ? previous : entry
                            context.decision(selected: selected, rejected: rejected, policy: policy)
                            selected.rejectedInputs = previous.rejectedInputs + [rejected.root]
                            selected.hadDecision = true
                            plan[index] = selected
                        }
                    }
                } else {
                    paths[key] = plan.count
                    plan.append(entry)
                }
                scanned += 1
                report(L("Scanning inputs"), scanned, 0)
                if entry.directory { try scan(url, root: root, prefix: plan[paths[key]!].relative) }
            }
        }
        func publishDecisions(scanCompleted: Bool) {
            for entry in plan where entry.hadDecision {
                let decision = ConflictingFileDecision(relativePath: entry.relative, selectedInput: entry.root,
                    rejectedInputs: entry.rejectedInputs, policy: request.options.samePathPolicy, scanCompleted: scanCompleted)
                context.deliver(MergeEvent(timestamp: Date(), kind: .finalSelection, relativePath: entry.relative,
                    sourceInput: entry.root, bytes: nil, attribute: nil, reason: nil, message: L("Conflicting File Decisions"),
                    counters: context.counters, selection: nil, finalSelection: decision))
            }
        }
        do { for input in request.inputs { try scan(input.path, root: input, prefix: "") } }
        catch { publishDecisions(scanCompleted: false); throw error }
        publishDecisions(scanCompleted: true)
        try cancellation.check()
        let temporary = request.destination.appendingPathComponent(".\(request.name).foldermerger-\(UUID().uuidString).tmp", isDirectory: true)
        guard temporary.withUnsafeFileSystemRepresentation({ mkdir($0!, 0o777) }) == 0 else {
            throw Self.systemError("Cannot create the temporary folder", temporary)
        }
        // mkdir applies the process umask. Keep this default mode for publication,
        // while restricting the unpublished construction tree to its owner.
        do {
            let rootMode = try Self.info(temporary).st_mode & 0o777
            guard temporary.withUnsafeFileSystemRepresentation({ chmod($0!, 0o700) }) == 0 else {
                throw Self.systemError("Cannot protect the temporary folder", temporary)
            }
            context.emit(.phase, message: L("Build in temporary folder"))
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
                    throw Self.systemError(L("Cannot exclusively create the output item (input: %@, relative path: %@)", entry.root.path, entry.relative), target, code: code)
                }
                if !entry.directory {
                    defer { close(descriptor) }
                    try copy(entry, to: descriptor, cancellation: cancellation) { amount in
                        bytes += Int64(amount)
                        report(L("Copying"), index, plan.count)
                    }
                    context.counters.copied += 1
                    context.detail(.copied, entry: entry, bytes: Int64(entry.info.st_size), message: L("Copied"))
                    try applyAttributes(entry, target: targetPath, options: request.options, context: context)
                } else {
                    context.detail(.directoryCreated, entry: entry, message: L("Created folder"))
                }
                created[Identity(try Self.info(path: targetPath))] = entry
                report(L("Building"), index + 1, plan.count)
            }
            context.emit(.phase, message: L("Apply folder attributes (deepest first)"))
            for entry in plan.filter({ $0.directory }).sorted(by: { $0.relative.split(separator: "/").count > $1.relative.split(separator: "/").count }) {
                try cancellation.check()
                try applyAttributes(entry, target: temporary.path + "/" + entry.relative, options: request.options, context: context)
            }
            try cancellation.check()
            try beforeCommit?()
            try cancellation.check()
            guard temporary.withUnsafeFileSystemRepresentation({ chmod($0!, rootMode) }) == 0 else {
                throw Self.systemError("Cannot set output folder permissions", temporary)
            }
            context.emit(.phase, message: L("Finalize with RENAME_EXCL"))
            let result = temporary.withUnsafeFileSystemRepresentation { source in
                request.output.withUnsafeFileSystemRepresentation { target in
                    renamex_np(source!, target!, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else { throw Self.systemError("Cannot finalize the output (existing items are never overwritten)", request.output) }
            return request.output
        } catch {
            // All I/O is synchronous on this worker. File descriptors are closed before cleanup.
            do { try FileManager.default.removeItem(at: temporary) }
            catch let cleanupError {
                context.cleanupFailed = true
                throw MergeError(L("%@\nCannot remove the temporary folder: %@\n%@", error.localizedDescription, temporary.path, cleanupError.localizedDescription))
            }
            throw error
        }
    }

    private func openSource(_ path: String) throws -> Int32 {
        let url = URL(fileURLWithPath: path)
        let fd = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else { throw Self.systemError("Cannot open the input", url) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
            close(fd); throw MergeError(L("The input is not a regular file: %@", url.path))
        }
        return fd
    }

    private func readChunk(_ fd: Int32, into buffer: inout [UInt8], url: String) throws -> Int {
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count >= 0 { return count }
            if errno != EINTR { throw Self.systemError("Cannot read the input", URL(fileURLWithPath: url)) }
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
                    guard written > 0 else { throw Self.systemError("Cannot write the copy", URL(fileURLWithPath: entry.source)) }
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
                let warning = AttributeWarning(relativePath: entry.relative, attribute: attribute, reason: L("The destination does not support this attribute."))
                context.warnings.append(warning); context.counters.warnings += 1
                context.emit(.warning, relative: entry.relative, source: entry.root, attribute: attribute, reason: warning.reason, message: L("%@: %@", attributeDisplayName(attribute), warning.reason))
            } else if code != 0 {
                throw Self.systemError(L("Cannot set attribute %@ (relative path: %@)", attributeDisplayName(attribute), entry.relative), URL(fileURLWithPath: target), code: code)
            }
        }
        if options.extendedAttributes {
            // Read failures are fatal; only destination application ENOTSUP is downgraded.
            let size = listxattr(entry.source, nil, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { throw Self.systemError("Cannot list extended attributes", URL(fileURLWithPath: entry.source)) }
            if size > 0 {
                var names = [CChar](repeating: 0, count: size)
                let count = listxattr(entry.source, &names, size, XATTR_NOFOLLOW)
                guard count >= 0 else { throw Self.systemError("Cannot list extended attributes", URL(fileURLWithPath: entry.source)) }
                for raw in names.prefix(count).split(separator: 0) {
                    let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    let length = getxattr(entry.source, name, nil, 0, 0, XATTR_NOFOLLOW)
                    guard length >= 0 else { throw Self.systemError("Cannot read extended attributes", URL(fileURLWithPath: entry.source)) }
                    var data = [UInt8](repeating: 0, count: length)
                    let read = data.withUnsafeMutableBytes { getxattr(entry.source, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
                    guard read == length else { throw Self.systemError("Cannot read extended attributes", URL(fileURLWithPath: entry.source)) }
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

public enum SamePathPolicy: String, Sendable, CaseIterable {
    case stop, earlier, later, newer
    public var localizationKey: String {
        switch self {
        case .stop: return "Stop the merge"
        case .earlier: return "Prefer the input folder added first"
        case .later: return "Prefer the input folder added later"
        case .newer: return "Prefer the file with the newer modification date"
        }
    }
    public var label: String { L(localizationKey) }
}

// Keep the exact stat timestamp rather than rounding through Date/Double.
public struct FileModificationTime: Sendable, Equatable, Comparable {
    public let seconds: Int
    public let nanoseconds: Int
    init(_ value: timespec) { seconds = value.tv_sec; nanoseconds = value.tv_nsec }
    var isValid: Bool { (0..<1_000_000_000).contains(nanoseconds) }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.seconds == rhs.seconds ? lhs.nanoseconds < rhs.nanoseconds : lhs.seconds < rhs.seconds
    }
}

public struct FileSelection: Sendable {
    public let selectedInput: URL
    public let rejectedInput: URL
    public let policy: SamePathPolicy
    public let selectedModificationTime: FileModificationTime?
    public let rejectedModificationTime: FileModificationTime?
}

public struct MergeOptions: Sendable, Equatable {
    public var samePathPolicy: SamePathPolicy
    public var fileDates: Bool
    public var filePermissions: Bool
    public var directoryDates: Bool
    public var extendedAttributes: Bool
    public init(fileDates: Bool = true, filePermissions: Bool = true, directoryDates: Bool = false, extendedAttributes: Bool = true, samePathPolicy: SamePathPolicy = .earlier) {
        self.samePathPolicy = samePathPolicy
        self.fileDates = fileDates; self.filePermissions = filePermissions
        self.directoryDates = directoryDates; self.extendedAttributes = extendedAttributes
    }
    public var descriptions: [String] {
        [(L("File creation and modification dates"), fileDates), (L("File permissions"), filePermissions),
         (L("Folder creation and modification dates"), directoryDates), (L("Extended attributes and resource forks"), extendedAttributes)]
            .map { L("%@: %@", $0.0, $0.1 ? L("Preserve") : L("Do not preserve")) } + [L("%@: %@", L("When different files have the same path"), samePathPolicy.label)]
    }
}

public enum MergeStatus: Sendable { case success, warnings, failure, cancelled
    public var label: String {
        switch self { case .success: return L("Completed"); case .warnings: return L("Completed with warnings")
        case .failure: return L("Failed"); case .cancelled: return L("Cancelled") }
    }
}
public struct MergeCounters: Sendable {
    public internal(set) var copied = 0
    public internal(set) var skipped = 0
    public internal(set) var warnings = 0
    public internal(set) var errors = 0
    public init() {}
    public var description: String { L("Copied: %lld · Identical files skipped: %lld · Warnings: %lld · Errors: %lld", copied, skipped, warnings, errors) }
}
public struct AttributeWarning: Sendable {
    public let relativePath: String
    public let attribute: String
    public let reason: String
    public var displayName: String { attributeDisplayName(attribute) }
}
public struct MergeResult {
    public let status: MergeStatus
    public let output: URL?
    public let counters: MergeCounters
    public let warnings: [AttributeWarning]
    public let error: MergeError?
    public var cleanupFailed: Bool = false
}
public struct MergeEvent: Sendable {
    public enum Kind: Sendable { case conflict, finalSelection, fileSelected, phase, directoryCreated, copied, skipped, warning, error, cancelled, completed }
    public let timestamp: Date
    public let kind: Kind
    public let relativePath: String?
    public let sourceInput: URL?
    public let bytes: Int64?
    public let attribute: String?
    public let reason: String?
    public let message: String
    public let counters: MergeCounters
    public let selection: FileSelection?
    public var comparedInput: URL? = nil
    public var finalSelection: ConflictingFileDecision? = nil
    public var line: String {
        L("%@ %@%@%@%@", timestamp.formatted(date: .omitted, time: .standard), message,
          relativePath.map { L(" %@", $0) } ?? "",
          sourceInput.map { L(" ← %@", $0.path) } ?? "",
          bytes.map { LC(" (%lld bytes)", $0) } ?? "")
    }
}
private final class EventContext {
    let detailed: Bool
    let sink: (MergeEvent) -> Void
    let logSink: (MergeEvent) -> Void
    var counters = MergeCounters()
    var warnings: [AttributeWarning] = []
    var cleanupFailed = false
    init(detailed: Bool, sink: @escaping (MergeEvent) -> Void, logSink: @escaping (MergeEvent) -> Void) { self.detailed = detailed; self.sink = sink; self.logSink = logSink }
    func deliver(_ event: MergeEvent, screen: Bool = true) {
        logSink(event)
        if screen { sink(event) }
    }
    func emit(_ kind: MergeEvent.Kind, relative: String? = nil, source: URL? = nil, compared: URL? = nil, bytes: Int64? = nil, attribute: String? = nil, reason: String? = nil, message: String, screen: Bool = true) {
        deliver(MergeEvent(timestamp: Date(), kind: kind, relativePath: relative, sourceInput: source, bytes: bytes, attribute: attribute, reason: reason, message: message, counters: counters, selection: nil, comparedInput: compared), screen: screen)
    }
    func decision(selected: Entry, rejected: Entry, policy: SamePathPolicy) {
        let selection = FileSelection(selectedInput: selected.root, rejectedInput: rejected.root, policy: policy,
                                      selectedModificationTime: policy == .newer ? FileModificationTime(selected.info.st_mtimespec) : nil,
                                      rejectedModificationTime: policy == .newer ? FileModificationTime(rejected.info.st_mtimespec) : nil)
        deliver(MergeEvent(timestamp: Date(), kind: .fileSelected, relativePath: selected.relative,
                        sourceInput: selected.root, bytes: Int64(selected.info.st_size), attribute: nil, reason: nil,
                        message: L("Selected input: %@; rejected input: %@; rule: %@", selected.root.path, rejected.root.path, policy.label),
                        counters: counters, selection: selection))
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
        let lines = request.inputs.enumerated().map { L("Input %lld (priority order): %@", $0.offset + 1, $0.element.path) }
            + [L("Final destination: %@", request.output.path)] + request.options.descriptions + [
                L("Inputs remain unchanged and nothing is overwritten. Same-path folders are merged, including canonical Unicode equivalents when the destination treats them as identical. The first spelling and folder attributes are kept. Identical files are deduplicated; file attributes come from the selected file."),
                L("Apply the selected rule only to different file contents. Newer-file priority stops on equal or incomparable modification dates. Stop on file/folder conflicts or other destination name collisions. Exclude .DS_Store at every level."),
                L("Copy method: POSIX open/read/write (1 MiB chunks). No external commands."),
                L("Create exclusively in a temporary folder on the same volume. Apply selected attributes only: contents → extended attributes → file permissions → modification date → creation date. Apply folder attributes after their children, deepest first. The output root is newly created."),
                L("Finalize with RENAME_EXCL only on success. Clean up the temporary folder on failure or cancellation. Unsupported attributes produce warnings; other errors stop the merge.")
            ]
        steps = lines.map { ExecutionStep(text: $0, arguments: nil) }
    }
}
