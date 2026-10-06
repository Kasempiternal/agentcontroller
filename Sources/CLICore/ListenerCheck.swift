import Foundation
import PortOwnership

/// Whether the process on a loopback port is one of this user's, asked before every request
/// the bridge relays. Remembers the pid it found per port, so that per-request check looks
/// at one process instead of walking all of them.
final class ListenerCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [UInt16: pid_t] = [:]
    private let owner: (UInt16) -> pid_t?
    private let holds: (pid_t, UInt16) -> Bool

    /// The defaults are the real lookups; tests stand in another user's listener, which they
    /// cannot create.
    init(owner: @escaping (UInt16) -> pid_t? = LoopbackListener.owner(port:),
         holds: @escaping (pid_t, UInt16) -> Bool = LoopbackListener.isListening(pid:port:)) {
        self.owner = owner
        self.holds = holds
    }

    func isOurs(_ port: UInt16) -> Bool {
        lock.lock()
        let known = seen[port]
        lock.unlock()
        if let known, holds(known, port) { return true }
        let found = owner(port)
        lock.lock()
        seen[port] = found
        lock.unlock()
        return found != nil
    }
}
