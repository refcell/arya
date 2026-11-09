import Foundation

/// Thin POSIX helpers with typed errors. Every call that can fail throws `LedgerIOError`.
enum FileIO {
    static func makeDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw LedgerIOError(op: "mkdir", path: url.lastPathComponent, code: 0)
        }
    }

    /// Opens `url` with `flags`, creating it with mode 0644 when `O_CREAT` is set.
    static func open(_ url: URL, _ flags: Int32) throws -> Int32 {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            Darwin.open(path!, flags | O_CLOEXEC, 0o644)
        }
        if fd < 0 { throw LedgerIOError(op: "open", path: url.lastPathComponent, code: errno) }
        return fd
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8], name: String) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress! + offset, bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw LedgerIOError(op: "write", path: name, code: errno)
            }
            offset += written
        }
    }

    static func sync(_ fd: Int32, name: String) throws {
        if fsync(fd) != 0 { throw LedgerIOError(op: "fsync", path: name, code: errno) }
    }

    static func size(_ fd: Int32, name: String) throws -> Int64 {
        var info = stat()
        if fstat(fd, &info) != 0 { throw LedgerIOError(op: "stat", path: name, code: errno) }
        return Int64(info.st_size)
    }

    /// Reads `count` bytes at `offset`; fewer only at end of file.
    static func read(_ fd: Int32, at offset: Int64, count: Int, name: String) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let got = out.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress! + done, count - done, off_t(offset) + off_t(done))
            }
            if got < 0 {
                if errno == EINTR { continue }
                throw LedgerIOError(op: "read", path: name, code: errno)
            }
            if got == 0 { break }
            done += got
        }
        out.removeLast(count - done)
        return out
    }

    static func truncate(_ fd: Int32, to length: Int64, name: String) throws {
        if ftruncate(fd, off_t(length)) != 0 {
            throw LedgerIOError(op: "truncate", path: name, code: errno)
        }
    }

    /// `fsync`s a directory so a new or renamed entry survives a crash.
    static func syncDirectory(_ url: URL) throws {
        let fd = try open(url, O_RDONLY)
        defer { close(fd) }
        try sync(fd, name: url.lastPathComponent)
    }

    /// Writes `data` to a unique temp file next to `url`, syncs it, and renames it into place.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        var template = Array(dir.appendingPathComponent(".tmp-XXXXXX").path.utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        if fd < 0 { throw LedgerIOError(op: "mkstemp", path: dir.lastPathComponent, code: errno) }
        let tempPath = String(cString: template)
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(tempPath) }
        }
        try writeAll(fd, [UInt8](data), name: url.lastPathComponent)
        try sync(fd, name: url.lastPathComponent)
        let result = url.withUnsafeFileSystemRepresentation { rename(tempPath, $0!) }
        if result != 0 {
            throw LedgerIOError(op: "rename", path: url.lastPathComponent, code: errno)
        }
        renamed = true
        try syncDirectory(dir)
    }
}

/// A failed file operation. `path` is a file name only, never a full path.
public struct LedgerIOError: Error, Hashable, Sendable, CustomStringConvertible {
    public var op: String
    public var path: String
    public var code: Int32

    public var description: String {
        "\(op) \(path) failed: \(String(cString: strerror(code))) (\(code))"
    }
}
