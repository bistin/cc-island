import XCTest
@testable import DynamicIslandCore

final class AtomicFileWriterTests: XCTestCase {
    func testWriteCreatesFileAtomically() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("settings.json")

        try AtomicFileWriter.write(Data(#"{"ok":true}"#.utf8), to: url)

        XCTAssertEqual(try Data(contentsOf: url), Data(#"{"ok":true}"#.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AtomicFileWriter.backupURL(for: url).path))
        XCTAssertTrue(try temporaryFiles(in: directory).isEmpty)
    }

    func testOverwriteCreatesBackupOnce() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("settings.json")
        try Data("original".utf8).write(to: url)

        let firstFingerprint = try AtomicFileWriter.fingerprint(at: url)
        try AtomicFileWriter.write(Data("updated".utf8), to: url, expectedFingerprint: firstFingerprint)

        let backupURL = AtomicFileWriter.backupURL(for: url)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "original")

        let secondFingerprint = try AtomicFileWriter.fingerprint(at: url)
        try AtomicFileWriter.write(Data("newer".utf8), to: url, expectedFingerprint: secondFingerprint)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "newer")
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "original")
        XCTAssertTrue(try temporaryFiles(in: directory).isEmpty)
    }

    func testExternalChangeFailsAndLeavesCurrentFileUntouched() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("config.toml")
        try Data("abc".utf8).write(to: url)
        let fingerprint = try AtomicFileWriter.fingerprint(at: url)

        try Data("xyz".utf8).write(to: url)

        XCTAssertThrowsError(
            try AtomicFileWriter.write(Data("new".utf8), to: url, expectedFingerprint: fingerprint)
        ) { error in
            guard case AtomicFileWriteError.changedExternally(let path) = error else {
                return XCTFail("expected changedExternally, got \(error)")
            }
            XCTAssertEqual(path, url.path)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "xyz")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AtomicFileWriter.backupURL(for: url).path))
        XCTAssertTrue(try temporaryFiles(in: directory).isEmpty)
    }

    func testOverwritePreservesExistingPermissionsWhenNotSpecified() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("settings.json")
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let fingerprint = try AtomicFileWriter.fingerprint(at: url)
        try AtomicFileWriter.write(Data("new".utf8), to: url, expectedFingerprint: fingerprint)

        XCTAssertEqual(try permissions(at: url), 0o600)
    }

    func testExplicitPermissionsApplyToReplacement() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("dynamic-island-hook")

        try AtomicFileWriter.write(Data("binary".utf8), to: url, backupExisting: false, posixPermissions: 0o755)

        XCTAssertEqual(try permissions(at: url), 0o755)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicFileWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func temporaryFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
    }

    private func permissions(at url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let raw = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        return raw.intValue & 0o777
    }
}
