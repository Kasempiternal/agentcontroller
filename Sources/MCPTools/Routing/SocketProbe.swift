import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum SocketProbe {
    struct Response: Sendable {
        let data: Data
        let connected: Bool
    }

    static func connect(host: String = "127.0.0.1", port: UInt16, timeoutMs: Int = 200) -> Bool {
        (try? roundTrip(host: host, port: port, payload: nil, timeoutMs: timeoutMs)) != nil
    }

    static func roundTrip(
        host: String = "127.0.0.1",
        port: UInt16,
        payload: Data?,
        timeoutMs: Int = 300,
        readUntilNull: Bool = false
    ) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw ProbeError.connectFailed }
        defer { close(fd) }

        var flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let ok = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard ok == 1 else { throw ProbeError.connectFailed }

        let rc: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 && errno != EINPROGRESS {
            throw ProbeError.connectFailed
        }

        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollRC = poll(&pollFD, 1, Int32(timeoutMs))
        guard pollRC > 0, (Int32(pollFD.revents) & POLLOUT) != 0 else {
            throw ProbeError.timeout
        }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        guard soError == 0 else { throw ProbeError.connectFailed }

        flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        var tv = timeval(tv_sec: 0, tv_usec: Int32(timeoutMs) * 1000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        if let payload {
            let sent = payload.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress, raw.count, 0)
            }
            guard sent == payload.count else { throw ProbeError.connectFailed }
        }

        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 {
                collected.append(contentsOf: buffer[0..<n])
                if readUntilNull, collected.contains(0) { break }
                if !readUntilNull { break }
            } else if n == 0 {
                break
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break
            }
        }
        if payload != nil && collected.isEmpty { throw ProbeError.timeout }
        return collected
    }

    enum ProbeError: Error {
        case connectFailed
        case timeout
    }
}
