import Foundation
import Darwin

/// Stable on-disk identity for a file: which volume it lives on and its inode
/// number. Used to detect whether a path still refers to the same file across
/// planning and execution.
public struct FileIdentity: Equatable, Sendable {
    public let volumeId: Int64
    public let fileId: Int64

    public init(volumeId: Int64, fileId: Int64) {
        self.volumeId = volumeId
        self.fileId = fileId
    }
}

public enum FileFingerprint {
    /// Cheap content fingerprint based on size and modification time —
    /// enough to detect "this file changed since we looked at it" without
    /// hashing file contents.
    public static func current(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return "\(st.st_size)-\(st.st_mtimespec.tv_sec)-\(st.st_mtimespec.tv_nsec)"
    }

    public static func identity(_ path: String) -> FileIdentity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return FileIdentity(volumeId: Int64(st.st_dev), fileId: Int64(st.st_ino))
    }
}
