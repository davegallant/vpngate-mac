import Darwin

public enum PortReservationError: Error, Equatable {
    case socketCreationFailed
    case bindFailed
    case getsocknameFailed
}

/// Reserves a free loopback TCP port by binding then immediately closing a
/// socket, so the caller can hand the port to a separate process (openvpn)
/// rather than a listener it can't pass on. Mirrors
/// `pkg/daemon/daemon_supervisor.go`'s `reserveLoopbackAddr` in the Go CLI.
public enum PortReservation {
    public static func reserveLoopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PortReservationError.socketCreationFailed }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw PortReservationError.bindFailed }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &actual) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(fd, sockaddrPtr, &len)
            }
        }
        guard getResult == 0 else { throw PortReservationError.getsocknameFailed }

        return UInt16(bigEndian: actual.sin_port)
    }
}
