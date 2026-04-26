import Darwin
import Foundation

public enum AtomicFileWriteError: LocalizedError, Equatable {
    case changedExternally(path: String)
    case renameFailed(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .changedExternally(let path):
            return "\(path) changed while preparing an update; refusing to overwrite. Retry after reviewing the file."
        case .renameFailed(let path, let errno):
            return "Failed to atomically replace \(path): \(String(cString: strerror(errno)))"
        }
    }
}

public struct AtomicFileWriter {
    public struct Fingerprint: Equatable {
        public let exists: Bool
        public let modificationDate: Date?
        public let fileSize: UInt64?
        public let contentDigest: UInt64?
    }

    public static func fingerprint(at url: URL) throws -> Fingerprint {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            return Fingerprint(
                exists: false,
                modificationDate: nil,
                fileSize: nil,
                contentDigest: nil
            )
        }
        let attrs = try manager.attributesOfItem(atPath: url.path)
        let data = try Data(contentsOf: url)
        return Fingerprint(
            exists: true,
            modificationDate: attrs[.modificationDate] as? Date,
            fileSize: (attrs[.size] as? NSNumber)?.uint64Value,
            contentDigest: digest(data)
        )
    }

    public static func write(
        _ data: Data,
        to destination: URL,
        backupExisting: Bool = true,
        expectedFingerprint: Fingerprint? = nil,
        posixPermissions: Int? = nil
    ) throws {
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        var tempCreated = false

        do {
            try data.write(to: tempURL, options: [])
            tempCreated = true
            let permissions: Int?
            if let posixPermissions {
                permissions = posixPermissions
            } else {
                permissions = try existingPermissions(at: destination)
            }
            if let permissions {
                try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
            }
            bestEffortSyncFile(at: tempURL)

            if let expectedFingerprint,
               try fingerprint(at: destination) != expectedFingerprint {
                throw AtomicFileWriteError.changedExternally(path: destination.path)
            }

            if backupExisting {
                try createBackupIfNeeded(for: destination)
            }

            if Darwin.rename(tempURL.path, destination.path) != 0 {
                throw AtomicFileWriteError.renameFailed(path: destination.path, errno: errno)
            }
            tempCreated = false
            bestEffortSyncDirectory(at: directory)
        } catch {
            if tempCreated {
                try? manager.removeItem(at: tempURL)
            }
            throw error
        }
    }

    public static func backupURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".bak")
    }

    private static func bestEffortSyncFile(at url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.synchronize()
    }

    private static func bestEffortSyncDirectory(at url: URL) {
        // APFS/HFS+ directory fsync semantics are weaker than Linux's; this is
        // still useful as a best-effort flush of the rename's directory entry.
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = Darwin.fsync(fd)
        _ = Darwin.close(fd)
    }

    private static func createBackupIfNeeded(for destination: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) else { return }

        let backupURL = backupURL(for: destination)
        let backupFingerprint = try fingerprint(at: backupURL)
        guard !backupFingerprint.exists else { return }

        let data = try Data(contentsOf: destination)
        try write(
            data,
            to: backupURL,
            backupExisting: false,
            expectedFingerprint: backupFingerprint,
            posixPermissions: try existingPermissions(at: destination)
        )
    }

    private static func existingPermissions(at url: URL) throws -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue
    }

    private static func digest(_ data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
