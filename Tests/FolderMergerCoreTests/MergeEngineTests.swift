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
