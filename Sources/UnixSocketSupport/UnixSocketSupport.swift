import Darwin
import Foundation

/// Shared Unix-domain socket helpers for the server (`LocalNotifyServer`) and the CLI client
/// (`mac-notify`). Centralizes the `sockaddr_un` address setup and path-length validation so the
/// dangerous pointer arithmetic exists in exactly one place.
///
/// All functions are synchronous and side-effect-free except for the `socket(2)` / `connect(2)`
/// syscalls they wrap.

/// Errors from Unix-domain socket setup.
public enum UnixSocketError: Error, CustomStringConvertible {
    case pathTooLong(path: String)
    case socketCreationFailed(errno: Int32)
    case connectFailed(path: String, errno: Int32)

    public var description: String {
        switch self {
        case .pathTooLong(let path):
            return "Unix socket path too long (exceeds sockaddr_un.sun_path): \(path)"
        case .socketCreationFailed(let errno):
            return "Socket creation failed: \(String(cString: strerror(errno)))"
        case .connectFailed(let path, let errno):
            return "Failed to connect to \(path): \(String(cString: strerror(errno)))"
        }
    }
}

/// Maximum path length that fits in `sockaddr_un.sun_path` (NUL-terminated).
public var maxUnixSocketPathLength: Int {
    MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
}

/// Build a `sockaddr_un` for the given path, validating length first.
/// - Throws: `UnixSocketError.pathTooLong` if the path (as UTF-8) would overflow `sun_path`.
public func makeUnixSocketAddress(path: String) throws -> sockaddr_un {
    guard path.utf8.count <= maxUnixSocketPathLength else {
        throw UnixSocketError.pathTooLong(path: path)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathSize = maxUnixSocketPathLength
    path.withCString { cString in
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            strncpy(
                baseAddress.assumingMemoryBound(to: CChar.self),
                cString,
                pathSize
            )
        }
    }
    return addr
}

/// Create a `SOCK_STREAM` Unix-domain socket fd.
/// - Throws: `UnixSocketError.socketCreationFailed` if `socket(2)` returns < 0.
public func createUnixStreamSocket() throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw UnixSocketError.socketCreationFailed(errno: errno)
    }
    return fd
}

/// Connect a Unix-domain `SOCK_STREAM` socket to `path` and return the fd.
/// Convenience for clients (the CLI and tests). Caller owns the fd and must `close(2)` it.
/// - Throws: `UnixSocketError.connectFailed` if `connect(2)` fails.
public func connectUnixSocket(path: String) throws -> Int32 {
    let fd = try createUnixStreamSocket()
    var addr = try makeUnixSocketAddress(path: path)
    let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let err = errno
        Darwin.close(fd)
        throw UnixSocketError.connectFailed(path: path, errno: err)
    }
    return fd
}
