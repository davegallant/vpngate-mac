import XCTest
import Darwin
@testable import VpngateShared

final class PortReservationTests: XCTestCase {
    func testReservesNonZeroPort() throws {
        let port = try PortReservation.reserveLoopbackPort()
        XCTAssertNotEqual(port, 0)
    }

    func testReservationsAreUsable() throws {
        // The port is closed immediately after reservation (matching the Go
        // implementation's approach), so it should be bindable again right
        // after — not a strict guarantee under contention, but a smoke test
        // that reserveLoopbackPort() doesn't leak the socket.
        let port = try PortReservation.reserveLoopbackPort()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(result, 0)
    }
}
