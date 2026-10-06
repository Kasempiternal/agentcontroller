import Darwin

/// Which of this user's processes is on the other end of 127.0.0.1:<port>.
///
/// A loopback port belongs to whoever binds it first, and any account on the Mac can bind
/// one. Before a client hands a port it did not open the bearer token, the agent's input or
/// a session's traffic, it checks that the process there runs as the same user. libproc
/// only shows this user's processes' sockets, so "none" means someone else's — or nobody's.
/// It does not tell this user's own processes apart (a sandboxed app of theirs could still
/// pose as the server).
public enum LoopbackListener {
    /// A process of this user listening where a connection to 127.0.0.1:`port` lands.
    public static func owner(port: UInt16) -> pid_t? {
        currentUserPIDs().first { isListening(pid: $0, port: port) }
    }

    /// Whether `pid` holds such a socket. Re-checking the one process seen last costs a
    /// fraction of `owner`'s walk over every process, which a per-request check can't afford.
    /// Another user's pid is never visible here, so it never passes.
    public static func isListening(pid: pid_t, port: UInt16) -> Bool {
        tcpSockets(of: pid).contains { socket in
            // Only a socket that receives a connection to 127.0.0.1 counts: one of ours on
            // ::1 does not stop someone else holding 127.0.0.1 on the same port.
            socket.state == TSI_S_LISTEN && socket.localPort == port
                && (socket.localAddress == loopback || socket.localAddress == INADDR_ANY)
        }
    }

    /// Whether every connection this process has open to 127.0.0.1:`port` is accepted by a
    /// process of this user. `owner` describes the listener at the moment it was asked; this
    /// describes the sockets already connected, so a listener that changed hands between
    /// that check and the connect is caught. False when there is no such connection.
    public static func connectedPeersBelongToCurrentUser(port: UInt16) -> Bool {
        let ours = Set(tcpSockets(of: getpid()).filter {
            $0.state == TSI_S_ESTABLISHED && $0.foreignPort == port && $0.foreignAddress == loopback
        }.map(\.localPort))
        guard !ours.isEmpty else { return false }
        var unmatched = ours
        for pid in currentUserPIDs() {
            for socket in tcpSockets(of: pid)
            where socket.state == TSI_S_ESTABLISHED && socket.localPort == port
                && socket.localAddress == loopback && socket.foreignAddress == loopback {
                unmatched.remove(socket.foreignPort)
            }
            if unmatched.isEmpty { return true }
        }
        return false
    }

    // MARK: - libproc

    private static let loopback = in_addr_t(0x7F00_0001).bigEndian

    private struct TCPSocket {
        var state: Int32
        var localAddress: in_addr_t
        var localPort: UInt16
        var foreignAddress: in_addr_t
        var foreignPort: UInt16
    }

    private static func currentUserPIDs() -> [pid_t] {
        let uid = UInt32(getuid())
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return [] }
        // Headroom for processes started between the sizing call and the listing.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
        let filled = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count))
        }
        return pids.prefix(max(Int(filled), 0) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    /// TCP sockets `pid` holds that carry IPv4: AF_INET ones, dual-stack listeners, and
    /// connections an IPv6 listener accepted from an IPv4 client (v4-mapped addresses).
    private static func tcpSockets(of pid: pid_t) -> [TCPSocket] {
        let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard fdBytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride + 16)
        let listed = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        var sockets: [TCPSocket] = []
        for fd in fds.prefix(max(Int(listed), 0) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let ends = tcp.tcpsi_ini
            guard ends.insi_vflag & UInt8(INI_IPV4) != 0 || isV4Mapped(ends.insi_laddr.ina_46) else { continue }
            sockets.append(TCPSocket(
                state: tcp.tcpsi_state,
                localAddress: ends.insi_laddr.ina_46.i46a_addr4.s_addr,
                localPort: UInt16(bigEndian: UInt16(truncatingIfNeeded: ends.insi_lport)),
                foreignAddress: ends.insi_faddr.ina_46.i46a_addr4.s_addr,
                foreignPort: UInt16(bigEndian: UInt16(truncatingIfNeeded: ends.insi_fport))
            ))
        }
        return sockets
    }

    /// ::ffff:a.b.c.d, whose last four bytes are what `i46a_addr4` reads.
    private static func isV4Mapped(_ address: in4in6_addr) -> Bool {
        let pad = address.i46a_pad32
        return pad.0 == 0 && pad.1 == 0 && pad.2 == UInt32(0xFFFF).bigEndian
    }
}
