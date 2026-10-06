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

    /// Blocking socket I/O belongs on a GCD thread, never on an actor: a Blender that
    /// accepts and then hangs would otherwise hold the actor for the whole timeout and
    /// queue every other handshake behind it (21 ports × 250ms serialised).
    static func connectAsync(host: String = "127.0.0.1", port: UInt16, timeoutMs: Int = 200) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: connect(host: host, port: port, timeoutMs: timeoutMs))
            }
        }
    }

    static func roundTripAsync(
        host: String = "127.0.0.1",
        port: UInt16,
        payload: Data?,
        timeoutMs: Int = 300,
        readUntilNull: Bool = false
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try roundTrip(host: host, port: port, payload: payload, timeoutMs: timeoutMs, readUntilNull: readUntilNull)
                })
            }
        }
    }

    /// SO_RCVTIMEO/SO_SNDTIMEO value for `ms`. `tv_usec` must stay below 1_000_000: the
    /// kernel rejects anything else with EDOM (measured errno 33 for a 1000ms+ timeout
    /// packed entirely into tv_usec), setsockopt's result went unchecked, and recv was
    /// left with no timeout at all.
    static func socketTimeout(ms: Int) -> timeval {
        let clamped = max(ms, 1)
        return timeval(
            tv_sec: __darwin_time_t(clamped / 1000),
            tv_usec: __darwin_suseconds_t((clamped % 1000) * 1000)
        )
    }

    static func roundTrip(
        host: String = "127.0.0.1",
        port: UInt16,
        payload: Data?,
        timeoutMs: Int = 300,
        readUntilNull: Bool = false
    ) throws -> Data {
        let started = Date()
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
        // A bare connect probe is done once the handshake completes; reading would only
        // make every open port cost its full timeout.
        guard payload != nil else { return Data() }

        flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        // One budget for the whole exchange: connect, send and read share `timeoutMs`
        // instead of each getting a full one.
        let remainingMs = max(timeoutMs - Int(Date().timeIntervalSince(started) * 1000), 1)
        var tv = socketTimeout(ms: remainingMs)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) == 0
        else { throw ProbeError.connectFailed }

        if let payload {
            let sent = payload.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress, raw.count, 0)
            }
            guard sent == payload.count else { throw ProbeError.connectFailed }
        }

        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = started.addingTimeInterval(Double(timeoutMs) / 1000.0)
        var complete = false
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 {
                collected.append(contentsOf: buffer[0..<n])
                if !readUntilNull || collected.contains(0) {
                    complete = true
                    break
                }
            } else if n == 0 {
                complete = true
                break
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                break
            }
        }
        // A half-read reply is a timeout, not a short answer — handing it on made the
        // caller fail later with a JSON decode error that hid the real cause.
        if payload != nil && (!complete || collected.isEmpty) { throw ProbeError.timeout }
        return collected
    }

    enum ProbeError: Error {
        case connectFailed
        case timeout
    }
}
