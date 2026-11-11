import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import FolderMergerCore

final class MergeEngineTests: XCTestCase {
    var base: URL!
    var a: URL!
    var b: URL!
    var parent: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        let testRoot = ProcessInfo.processInfo.environment["FM_CASE_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fm.temporaryDirectory
        base = testRoot.appendingPathComponent("FolderMergerTests-\(UUID().uuidString)")
        a = base.appendingPathComponent("任意の資料A")
        b = base.appendingPathComponent("別名の資料B")
        parent = base.appendingPathComponent("保存先")
        for url in [a!, b!, parent!] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
    }
    override func tearDownWithError() throws { try fm.removeItem(at: base) }
    var request: MergeRequest { MergeRequest(inputs: [a, b], destination: parent, name: "統合資料") }

    func write(_ root: URL, _ path: String, _ data: Data = Data("content".utf8)) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Foundation URL construction decomposes Unicode on macOS. Use raw POSIX
        // names so fixtures actually contain both original NFC/NFD spellings.
        let rawPath = root.path + "/" + path
        let fd = open(rawPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let amount = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                guard amount > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                offset += amount
            }
        }
        var times = [timespec(tv_sec: 1_600_000_000, tv_nsec: 123456789), timespec(tv_sec: 1_600_000_000, tv_nsec: 123456789)]
        XCTAssertEqual(futimens(fd, &times), 0)
    }
    struct Snapshot: Equatable {
        let path: Data
        let hash: String
        let mtime: Int
        let nanoseconds: Int
        let mode: mode_t
    }
    func snapshot(_ root: URL) throws -> [Snapshot] {
        var values: [Snapshot] = []
        func walk(_ url: URL, relative: String) throws {
            var info = stat()
            XCTAssertEqual(lstat(url.path, &info), 0)
            let kind = info.st_mode & S_IFMT
            var hash = ""
            if kind == S_IFREG {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var digest = SHA256()
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
                hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            } else if kind == S_IFLNK { hash = try fm.destinationOfSymbolicLink(atPath: url.path) }
            values.append(Snapshot(path: Data(relative.utf8), hash: hash, mtime: info.st_mtimespec.tv_sec,
                                   nanoseconds: info.st_mtimespec.tv_nsec, mode: info.st_mode))
            if kind == S_IFDIR {
                for child in try fm.contentsOfDirectory(atPath: url.path).sorted() {
                    try walk(url.appendingPathComponent(child), relative: relative + "/" + child)
                }
            }
        }
        try walk(root, relative: "")
        return values
    }
    func assertNoTemporary(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: parent.path).contains { $0.contains(".foldermerger-") }, file: file, line: line)
    }
    func assertFailure(_ req: MergeRequest? = nil, containing: [String] = [], engine: MergeEngine = MergeEngine(),
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let beforeA = try snapshot(a), beforeB = try snapshot(b)
        XCTAssertThrowsError(try engine.merge(req ?? request), file: file, line: line) { error in
            for part in containing { XCTAssertNotNil(Data(error.localizedDescription.utf8).range(of: Data(part.utf8)), error.localizedDescription, file: file, line: line) }
        }
        XCTAssertEqual(try snapshot(a), beforeA, file: file, line: line)
        XCTAssertEqual(try snapshot(b), beforeB, file: file, line: line)
        try assertNoTemporary(file: file, line: line)
    }

    func testMergeRelativePathsEmptyDirectoriesMtimeAndUnchangedInputs() throws {
        try write(a, "報告書/本文.pdf")
        try write(b, "報告書/図.png", Data([0, 255, 12]))
        try fm.createDirectory(at: a.appendingPathComponent("空フォルダ"), withIntermediateDirectories: true)
        try write(a, ".hidden")
        let before = try [snapshot(a), snapshot(b)]
        let output = try MergeEngine().merge(request)
        XCTAssertEqual(output.lastPathComponent, "統合資料")
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("空フォルダ").path))
        for (root, path) in [(a!, "報告書/本文.pdf"), (b!, "報告書/図.png"), (a!, ".hidden")] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), try Data(contentsOf: output.appendingPathComponent(path)))
            let sourceInfo = try fm.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            let outputInfo = try fm.attributesOfItem(atPath: output.appendingPathComponent(path).path)
            XCTAssertEqual(sourceInfo[.modificationDate] as? Date, outputInfo[.modificationDate] as? Date)
        }
        XCTAssertEqual(try [snapshot(a), snapshot(b)], before)
        try assertNoTemporary()
    }

    func testOutputModesUseSourceFilesAndDefaultDirectoryMode() throws {
        try write(a, "内側/実行可能", Data("run".utf8))
        try write(b, "内側/読み取り専用", Data("read".utf8))
        XCTAssertEqual((a.path + "/内側/実行可能").withCString { chmod($0, 0o755) }, 0)
        XCTAssertEqual((b.path + "/内側/読み取り専用").withCString { chmod($0, 0o640) }, 0)

        let expectedDirectory = parent.appendingPathComponent("directory-mode-probe")
        XCTAssertEqual(expectedDirectory.path.withCString { mkdir($0, 0o777) }, 0)
        var expectedInfo = stat()
        XCTAssertEqual(lstat(expectedDirectory.path, &expectedInfo), 0)
        try fm.removeItem(at: expectedDirectory)

        let output = try MergeEngine().merge(request)
        func mode(_ path: String) throws -> mode_t {
            var value = stat()
            XCTAssertEqual(lstat(path, &value), 0)
            return value.st_mode & 0o777
        }
        XCTAssertEqual(try mode(output.path), expectedInfo.st_mode & 0o777)
        XCTAssertEqual(try mode(output.appendingPathComponent("内側").path), expectedInfo.st_mode & 0o777)
        XCTAssertEqual(try mode(output.appendingPathComponent("内側/実行可能").path), 0o755)
        XCTAssertEqual(try mode(output.appendingPathComponent("内側/読み取り専用").path), 0o640)
    }

    func testTakeoutAndDSStore() throws {
        let roots = (0..<3).map { base.appendingPathComponent($0 == 0 ? "Takeout" : "Takeout \($0 + 1)") }
        let paths = ["Google フォト/アルバム/IMG.jpg", "Google フォト/アルバム/動画.mp4", "Google フォト/アルバム/IMG.jpg.json"]
        for (index, root) in roots.enumerated() {
            try write(root, paths[index], Data("\(index)".utf8))
            try write(root, ".DS_Store", Data("\(index)".utf8))
            try write(root, "Google フォト/.DS_Store", Data("\(index)".utf8))
        }
        let before = try roots.map(snapshot)
        let output = try MergeEngine().merge(MergeRequest(inputs: roots, destination: parent, name: "Takeout"))
        for path in paths { XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent(path).path)) }
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent(".DS_Store").path))
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("Google フォト/.DS_Store").path))
        XCTAssertEqual(try roots.map(snapshot), before)
    }

    func testIdenticalFilesDeduplicateWithChunkComparison() throws {
        let data = Data(repeating: 91, count: 2_500_000)
        try write(a, "same", data); try write(b, "same", data)
        let before = try [snapshot(a), snapshot(b)]
        var comparisons = 0
        let output = try MergeEngine().merge(request) { if $0.phase == "内容を比較中" { comparisons += 1 } }
        XCTAssertGreaterThanOrEqual(comparisons, 3)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: output.path), ["same"])
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("same")), data)
        XCTAssertEqual(try [snapshot(a), snapshot(b)], before)
    }
    func testSameSizeSameMtimeDifferentBytesConflict() throws {
        try write(a, "same", Data("abc".utf8)); try write(b, "same", Data("abd".utf8))
        try assertFailure(containing: ["same", a.path, b.path])
        XCTAssertFalse(fm.fileExists(atPath: request.output.path))
    }
    func testFileDirectoryConflict() throws {
        try write(a, "item"); try write(b, "item/child")
        try assertFailure(containing: ["item", a.path, b.path])
    }

    func testDestinationFilesystemCaseAndUnicodeBehavior() throws {
        // Measure the actual target filesystem, not a guessed string-folding rule.
        let probe = parent.appendingPathComponent("Probe")
        XCTAssertEqual(open(probe.path, O_CREAT | O_EXCL | O_WRONLY, 0o600).withClose(), 0)
        var info = stat()
        let caseSensitive = lstat(parent.appendingPathComponent("probe").path, &info) != 0
        try fm.removeItem(at: probe)
        print("FS measurement: case-sensitive=\(caseSensitive), destination=temporary test volume")
        try write(a, "Photo.jpg"); try write(b, "photo.jpg")
        if caseSensitive {
            let output = try MergeEngine().merge(request)
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: output.path).count, 2)
            try fm.removeItem(at: output)
        } else { try assertFailure(containing: ["Photo.jpg", "photo.jpg", a.path, b.path]) }
        try fm.removeItem(at: a.appendingPathComponent("Photo.jpg"))
        try fm.removeItem(at: b.appendingPathComponent("photo.jpg"))
        let nfc = "\u{304c}", nfd = "\u{304b}\u{3099}"
        try write(a, nfc); try write(b, nfd)
        try write(parent, nfc)
        let equivalent = lstat(parent.appendingPathComponent(nfd).path, &info) == 0
        try fm.removeItem(at: parent.appendingPathComponent(nfc))
        print("FS measurement: NFC/NFD-equivalent=\(equivalent)")
        if equivalent { try assertFailure(containing: [nfc, nfd, a.path, b.path]) }
        else {
            let output = try MergeEngine().merge(request)
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: output.path).count, 2)
        }
    }

    func testInvalidNamesAndMissingInputs() throws {
        for name in ["", ".", "..", "bad/name", "bad:name", "bad\0name", " \n\t "] {
            try assertFailure(MergeRequest(inputs: [a], destination: parent, name: name))
        }
        try assertFailure(MergeRequest(inputs: [], destination: parent, name: "out"))
    }
    func testExistingOutputKindsIncludingDanglingSymlink() throws {
        try write(parent, request.name)
        try assertFailure(containing: [request.output.path])
        XCTAssertEqual(try Data(contentsOf: request.output), Data("content".utf8))
        try fm.removeItem(at: request.output)
        try fm.createDirectory(at: request.output, withIntermediateDirectories: false)
        try assertFailure()
        try fm.removeItem(at: request.output)
        try fm.createSymbolicLink(atPath: request.output.path, withDestinationPath: a.path)
        try assertFailure()
        try fm.removeItem(at: request.output)
        try fm.createSymbolicLink(atPath: request.output.path, withDestinationPath: base.appendingPathComponent("missing").path)
        try assertFailure()
    }
    func testDuplicateNestedAndAliasInputsAndDestination() throws {
        try assertFailure(MergeRequest(inputs: [a, a], destination: parent, name: "out"))
        let child = a.appendingPathComponent("child")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        try assertFailure(MergeRequest(inputs: [a, child], destination: parent, name: "out"))
        try assertFailure(MergeRequest(inputs: [child, a], destination: parent, name: "out"))
        try assertFailure(MergeRequest(inputs: [a], destination: child, name: "out"))
        try assertFailure(MergeRequest(inputs: [a], destination: a, name: "out"))
        // Existing output containing an input is rejected before any writes.
        try assertFailure(MergeRequest(inputs: [child], destination: base, name: a.lastPathComponent))
        let alias = base.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: a)
        try assertFailure(MergeRequest(inputs: [a, alias], destination: parent, name: "out"))
        try assertFailure(MergeRequest(inputs: [alias], destination: parent, name: "out"), containing: ["シンボリックリンク", alias.path])
        try assertFailure(MergeRequest(inputs: [a], destination: alias.appendingPathComponent("child"), name: "out"))
        let upper = base.appendingPathComponent("CASEINPUT")
        try fm.createDirectory(at: upper, withIntermediateDirectories: false)
        let lower = base.appendingPathComponent("caseinput")
        if fm.fileExists(atPath: lower.path) {
            try assertFailure(MergeRequest(inputs: [upper, lower], destination: parent, name: "out"))
        }
    }
    func testSymlinksAndFIFORejectedWithoutFollowing() throws {
        let link = a.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: b.path)
        try assertFailure(containing: ["link", a.path])
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: base.appendingPathComponent("missing").path)
        try assertFailure(containing: ["link"])
        try fm.removeItem(at: link)
        XCTAssertEqual(mkfifo(a.appendingPathComponent("pipe").path, 0o600), 0)
        try assertFailure(containing: ["pipe", a.path])
    }
    func testCommitRacePreservesCompetitorAndCleansTemporary() throws {
        try write(a, "one")
        let engine = MergeEngine()
        engine.beforeCommit = { try self.write(self.parent, self.request.name, Data("competitor".utf8)) }
        try assertFailure(containing: [request.output.path], engine: engine)
        XCTAssertEqual(try Data(contentsOf: request.output), Data("competitor".utf8))
    }
    func testCancellationMidCopyCleansAndPreservesInputs() throws {
        try write(a, "large", Data(repeating: 23, count: 12 * 1_048_576))
        let before = try [snapshot(a), snapshot(b)]
        let token = CancellationToken()
        var copied: Int64 = 0
        XCTAssertThrowsError(try MergeEngine().merge(request, cancellation: token) { p in
            copied = p.bytesCopied
            if p.bytesCopied >= 2 * 1_048_576 { token.cancel() }
        }) { XCTAssertTrue($0.localizedDescription.contains("キャンセル")) }
        XCTAssertEqual(copied, 2 * 1_048_576)
        XCTAssertFalse(fm.fileExists(atPath: request.output.path))
        try assertNoTemporary()
        XCTAssertEqual(try [snapshot(a), snapshot(b)], before)
    }
    func testCancellationDuringScanAndCompare() throws {
        try write(a, "same", Data(repeating: 7, count: 3 * 1_048_576))
        try write(b, "same", Data(repeating: 7, count: 3 * 1_048_576))
        for phase in ["入力を走査中", "内容を比較中"] {
            let token = CancellationToken()
            let before = try [snapshot(a), snapshot(b)]
            XCTAssertThrowsError(try MergeEngine().merge(request, cancellation: token) { if $0.phase == phase { token.cancel() } })
            XCTAssertEqual(try [snapshot(a), snapshot(b)], before)
            XCTAssertFalse(fm.fileExists(atPath: request.output.path))
            try assertNoTemporary()
        }
    }

    func testDirectorySpellingCollisionAndHiddenFileConflict() throws {
        try write(a, "Album/one"); try write(b, "album/two")
        let probe = parent.appendingPathComponent("Probe")
        try write(parent, "Probe")
        let caseSensitive = !fm.fileExists(atPath: parent.appendingPathComponent("probe").path)
        try fm.removeItem(at: probe)
        if caseSensitive {
            let output = try MergeEngine().merge(request)
            XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Album/one").path))
            XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("album/two").path))
            try fm.removeItem(at: output)
        } else { try assertFailure(containing: ["Album", "album", a.path, b.path]) }
        try fm.removeItem(at: a.appendingPathComponent("Album"))
        try fm.removeItem(at: b.appendingPathComponent("album"))
        try write(a, ".hidden", Data([1])); try write(b, ".hidden", Data([2]))
        try assertFailure(containing: [".hidden", a.path, b.path])
    }

    func testCleanupFailureReportsTemporaryPath() throws {
        try write(a, "file")
        let before = try [snapshot(a), snapshot(b)]
        let engine = MergeEngine()
        var temporary: URL?
        engine.beforeCommit = {
            temporary = try self.fm.contentsOfDirectory(at: self.parent, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains(".foldermerger-") }
            XCTAssertNotNil(temporary)
            XCTAssertEqual(chmod(temporary!.path, 0o500), 0)
            throw MergeError("人工的な確定前エラー")
        }
        defer { if let temporary { _ = chmod(temporary.path, 0o700); try? fm.removeItem(at: temporary) } }
        XCTAssertThrowsError(try engine.merge(request)) {
            XCTAssertTrue($0.localizedDescription.contains("人工的な確定前エラー"))
            XCTAssertTrue($0.localizedDescription.contains("一時フォルダを削除できません"))
            let reportedPath = self.parent.appendingPathComponent(temporary!.lastPathComponent).path
            XCTAssertTrue($0.localizedDescription.contains(reportedPath), $0.localizedDescription)
        }
        XCTAssertFalse(fm.fileExists(atPath: request.output.path))
        XCTAssertEqual(try [snapshot(a), snapshot(b)], before)
    }
}

private extension Int32 {
    func withClose() -> Int32 { if self < 0 { return -1 }; return close(self) }
}

extension MergeEngineTests {
    private var allAttributes: MergeOptions {
        MergeOptions(fileDates: true, filePermissions: true, directoryDates: true, extendedAttributes: true)
    }
    private func measured(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return info
    }
    private func dates(_ url: URL, birth: Int = 981158400, modified: Int = 1118102400) throws {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: modified, tv_nsec: 123456789)]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)
        var attrs = attrlist(); attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT); attrs.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var time = timespec(tv_sec: birth, tv_nsec: 987654321)
        XCTAssertEqual(setattrlist(url.path, &attrs, &time, MemoryLayout<timespec>.size, 0), 0)
        let actual = try measured(url)
        XCTAssertEqual(actual.st_birthtimespec.tv_sec, birth)
        XCTAssertEqual(actual.st_mtimespec.tv_sec, modified)
    }
    private func xattr(_ url: URL, _ name: String, _ value: Data) throws {
        let result = value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, value.count, 0, 0) }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    private func xattr(_ url: URL, _ name: String) throws -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        if size < 0, errno == ENOATTR { return nil }
        guard size >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var value = Data(count: size)
        let read = value.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        XCTAssertEqual(read, size)
        return value
    }
    private func execute(_ options: MergeOptions, name: String = UUID().uuidString, inputs: [URL]? = nil) -> MergeResult {
        MergeEngine().run(MergeRequest(inputs: inputs ?? [a, b], destination: parent, name: name, options: options))
    }
    private func assertDates(_ target: URL, _ source: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let t = try measured(target), s = try measured(source)
        XCTAssertEqual(t.st_birthtimespec.tv_sec, s.st_birthtimespec.tv_sec, file: file, line: line)
        XCTAssertEqual(t.st_birthtimespec.tv_nsec, s.st_birthtimespec.tv_nsec, file: file, line: line)
        XCTAssertEqual(t.st_mtimespec.tv_sec, s.st_mtimespec.tv_sec, file: file, line: line)
        XCTAssertEqual(t.st_mtimespec.tv_nsec, s.st_mtimespec.tv_nsec, file: file, line: line)
    }

    func testIndependentBirthAndModificationDatesOnAndOff() throws {
        try write(a, "file")
        let source = a.appendingPathComponent("file")
        try dates(source)
        let on = execute(MergeOptions())
        XCTAssertEqual(on.status, .success)
        let output = try XCTUnwrap(on.output).appendingPathComponent("file")
        try assertDates(output, source)
        let info = try measured(output)
        print("stat equivalent: birth=\(info.st_birthtimespec.tv_sec).\(info.st_birthtimespec.tv_nsec), mtime=\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec), mode=\(String(info.st_mode & 0o777, radix: 8)); order=mtime then birthtime")
        let start = Int(Date().timeIntervalSince1970)
        let off = execute(MergeOptions(fileDates: false))
        let newInfo = try measured(XCTUnwrap(off.output).appendingPathComponent("file"))
        XCTAssertGreaterThanOrEqual(newInfo.st_birthtimespec.tv_sec, start)
        XCTAssertGreaterThanOrEqual(newInfo.st_mtimespec.tv_sec, start)
    }

    func testPermissionsEnabledAndDisabledIncludingReadonly() throws {
        let control = parent.appendingPathComponent("control")
        let fd = open(control.path, O_CREAT | O_EXCL | O_WRONLY, 0o666)
        XCTAssertGreaterThanOrEqual(fd, 0); close(fd)
        let defaultMode = try measured(control).st_mode & 0o777
        for mode in [mode_t(0o640), mode_t(0o400)] {
            let name = String(mode)
            try write(a, name)
            XCTAssertEqual(chmod(a.appendingPathComponent(name).path, mode), 0)
        }
        for enabled in [true, false] {
            let result = execute(MergeOptions(filePermissions: enabled))
            XCTAssertEqual(result.status, .success)
            for mode in [mode_t(0o640), mode_t(0o400)] {
                let output = try XCTUnwrap(result.output).appendingPathComponent(String(mode))
                XCTAssertEqual(try measured(output).st_mode & 0o777, enabled ? mode : defaultMode)
            }
        }
    }

    func testExtendedAttributesFilesAndDirectoriesEnabledAndDisabled() throws {
        try write(a, "folder/file")
        let tags = try PropertyListSerialization.data(fromPropertyList: ["Artificial\n6"], format: .binary, options: 0)
        var finder = Data(repeating: 0, count: 32); finder[8] = 0x04
        let attributes: [(String, Data)] = [
            ("user.foldermerger-test", Data("artificial".utf8)),
            ("com.apple.metadata:_kMDItemUserTags", tags),
            ("com.apple.FinderInfo", finder),
            ("com.apple.ResourceFork", Data("artificial resource fork".utf8)),
            ("com.apple.quarantine", Data("0081;00000000;ArtificialTest;".utf8))
        ]
        var supported: [String: [(String, Data)]] = [:]
        for relative in ["folder", "folder/file"] {
            let url = a.appendingPathComponent(relative)
            for (name, value) in attributes {
                do {
                    try xattr(url, name, value)
                    supported[relative, default: []].append((name, value))
                    XCTAssertEqual(try xattr(url, name), value)
                    print("xattr -l equivalent: \(relative) \(name) = \(value.count) bytes")
                } catch {
                    // Resource forks on directories are rejected by some macOS filesystems.
                    if relative == "folder", name == "com.apple.ResourceFork", (error as NSError).code == Int(EPERM) {
                        print("Directory resource fork fixture unavailable: \(error.localizedDescription)")
                    } else { throw error }
                }
            }
        }
        for enabled in [true, false] {
            let result = execute(MergeOptions(extendedAttributes: enabled))
            XCTAssertEqual(result.status, .success)
            for (relative, values) in supported {
                let target = try XCTUnwrap(result.output).appendingPathComponent(relative)
                for (name, value) in values {
                    XCTAssertEqual(try xattr(target, name), enabled ? value : nil, "\(relative): \(name)")
                }
            }
        }
    }

    func testDirectoryDatesPostorderAndFreshOutputRoot() throws {
        try write(a, "outer/inner/file")
        for path in ["outer/inner", "outer", ""] {
            let url = path.isEmpty ? a! : a.appendingPathComponent(path)
            try dates(url)
            try xattr(url, "user.foldermerger-test", Data("folder".utf8))
        }
        let probe = parent.appendingPathComponent("root-mode-probe")
        XCTAssertEqual(mkdir(probe.path, 0o777), 0)
        let defaultMode = try measured(probe).st_mode & 0o777
        XCTAssertEqual(chmod(a.path, defaultMode == 0o700 ? 0o755 : 0o700), 0)
        for enabled in [true, false] {
            let start = Int(Date().timeIntervalSince1970)
            let result = execute(MergeOptions(directoryDates: enabled, extendedAttributes: true))
            let root = try XCTUnwrap(result.output)
            for path in ["outer", "outer/inner"] {
                let target = root.appendingPathComponent(path)
                if enabled { try assertDates(target, a.appendingPathComponent(path)) }
                else {
                    let info = try measured(target)
                    XCTAssertGreaterThanOrEqual(info.st_birthtimespec.tv_sec, start)
                    XCTAssertGreaterThanOrEqual(info.st_mtimespec.tv_sec, start)
                }
            }
            let info = try measured(root)
            XCTAssertEqual(info.st_mode & 0o777, defaultMode)
            XCTAssertGreaterThanOrEqual(info.st_birthtimespec.tv_sec, start)
            XCTAssertGreaterThanOrEqual(info.st_mtimespec.tv_sec, start)
            XCTAssertNil(try xattr(root, "user.foldermerger-test"))
        }
    }

    func testInputOrderChoosesFileAndDirectoryAttributes() throws {
        for (index, root) in [a!, b!].enumerated() {
            try write(root, "folder/file")
            for path in ["folder/file", "folder"] {
                let url = root.appendingPathComponent(path)
                try dates(url, birth: 981158400 + index * 86400, modified: 1118102400 + index * 86400)
                try xattr(url, "user.order", Data([UInt8(index)]))
            }
            XCTAssertEqual(chmod(root.appendingPathComponent("folder/file").path, index == 0 ? 0o640 : 0o400), 0)
        }
        for roots in [[a!, b!], [b!, a!]] {
            let result = execute(allAttributes, inputs: roots)
            let output = try XCTUnwrap(result.output)
            for path in ["folder/file", "folder"] {
                let target = output.appendingPathComponent(path), source = roots[0].appendingPathComponent(path)
                try assertDates(target, source)
                XCTAssertEqual(try xattr(target, "user.order"), try xattr(source, "user.order"))
                if path.hasSuffix("file") { XCTAssertEqual(try measured(target).st_mode & 0o777, try measured(source).st_mode & 0o777) }
            }
            XCTAssertEqual(result.counters.copied, 1); XCTAssertEqual(result.counters.skipped, 1)
        }
    }

    func testUnsupportedAttributeWarnsAndOtherErrorFailsWithCleanup() throws {
        try write(a, "file")
        for code in [ENOTSUP, EACCES] {
            let engine = MergeEngine()
            engine.attributeOperation = { _, attribute, operation in attribute == "変更日" ? code : operation() }
            let result = engine.run(request)
            if code == ENOTSUP {
                XCTAssertEqual(result.status, .warnings)
                XCTAssertEqual(result.counters.warnings, 1)
                XCTAssertEqual(result.warnings.first?.relativePath, "file")
                XCTAssertEqual(result.warnings.first?.attribute, "変更日")
                try fm.removeItem(at: XCTUnwrap(result.output))
            } else {
                XCTAssertEqual(result.status, .failure); XCTAssertEqual(result.counters.errors, 1)
                XCTAssertNil(result.output); XCTAssertTrue(result.error?.message.contains("変更日") == true)
                XCTAssertFalse(fm.fileExists(atPath: request.output.path))
            }
            try assertNoTemporary()
        }
    }

    func testDetailedEventsAndCountersRegardlessOfDetail() throws {
        try write(a, "file"); try write(b, "file")
        for detailed in [true, false] {
            let engine = MergeEngine()
            engine.attributeOperation = { _, name, operation in name == "変更日" ? ENOTSUP : operation() }
            var events: [MergeEvent] = []
            let result = engine.run(request, detailedLog: detailed, event: { events.append($0) })
            XCTAssertEqual(result.counters.copied, 1); XCTAssertEqual(result.counters.skipped, 1)
            XCTAssertEqual(result.counters.warnings, 1); XCTAssertEqual(result.counters.errors, 0)
            XCTAssertEqual(events.filter { $0.kind == .copied }.count, detailed ? 1 : 0)
            XCTAssertEqual(events.filter { $0.kind == .skipped }.count, detailed ? 1 : 0)
            let warning = try XCTUnwrap(events.first { $0.kind == .warning })
            XCTAssertEqual(warning.relativePath, "file")
            XCTAssertEqual(warning.attribute, "変更日"); XCTAssertNotNil(warning.reason)
            if detailed {
                let skip = try XCTUnwrap(events.firstIndex { $0.kind == .skipped })
                let warn = try XCTUnwrap(events.firstIndex { $0.kind == .warning })
                let copy = try XCTUnwrap(events.firstIndex { $0.kind == .copied })
                XCTAssertLessThan(skip, copy); XCTAssertLessThan(copy, warn)
                XCTAssertEqual(events[skip].sourceInput, b)
                XCTAssertEqual(events[copy].sourceInput, a)
                XCTAssertEqual(events[copy].bytes, 7)
                XCTAssertEqual(events[copy].relativePath, "file")
            }
            XCTAssertEqual(events.last?.kind, .completed)
            XCTAssertEqual(events.last?.counters.copied, 1)
            XCTAssertEqual(events.map(\.timestamp), events.map(\.timestamp).sorted())
            try fm.removeItem(at: XCTUnwrap(result.output))
        }
    }

    func testFailureAndCancellationTerminalEventsAndCleanup() throws {
        try write(a, "file", Data(repeating: 1, count: 3 * 1_048_576))
        let token = CancellationToken()
        var events: [MergeEvent] = []
        let cancelled = MergeEngine().run(request, cancellation: token, event: { events.append($0) }, progress: {
            if $0.bytesCopied > 0 { token.cancel() }
        })
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(events.suffix(2).map(\.kind), [.cancelled, .completed])
        try assertNoTemporary()
        XCTAssertFalse(fm.fileExists(atPath: request.output.path))
        try write(b, "file", Data([2]))
        events = []
        let failed = MergeEngine().run(request, event: { events.append($0) })
        XCTAssertEqual(failed.status, .failure)
        XCTAssertEqual(events.suffix(2).map(\.kind), [.error, .completed])
        XCTAssertEqual(failed.counters.errors, 1)
        try assertNoTemporary()
    }

    func testPlanIsValueSnapshotAndHasNoExternalCommand() throws {
        var req = request
        let snapshot = MergePlanDescription(request: req)
        req.options = allAttributes
        req.name = "changed"
        XCTAssertEqual(snapshot.request.options, MergeOptions())
        XCTAssertNotEqual(snapshot.request.output, req.output)
        XCTAssertTrue(snapshot.steps.allSatisfy { $0.arguments == nil && !$0.text.contains("rsync") })
        XCTAssertTrue(snapshot.steps.contains { $0.text.contains("フォルダの作成日・変更日: 保持しない") })
        XCTAssertTrue(MergePlanDescription(request: req).steps.contains { $0.text.contains("フォルダの作成日・変更日: 保持") })
        XCTAssertTrue(snapshot.steps.contains { $0.text.contains("RENAME_EXCL") })
        XCTAssertTrue(snapshot.steps.contains { $0.text.contains(".DS_Store") })
    }
}
