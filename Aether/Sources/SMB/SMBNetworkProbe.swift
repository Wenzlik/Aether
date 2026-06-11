import Foundation
import Network

/// Triggers the iOS **Local Network** permission prompt (and checks the host is
/// reachable) by opening a short Network-framework TCP connection to the SMB
/// port.
///
/// Why this exists (#214): libVLC's `libsmb2` connects over raw BSD sockets,
/// which on iOS do **not** reliably make the system show the local-network
/// privacy prompt — so the app never gets permission, never appears in
/// Settings ▸ Privacy & Security ▸ Local Network, and every LAN connection is
/// silently blocked (a deleted-and-reinstalled app still saw no prompt). An
/// `NWConnection` to a local host *does* trigger the prompt; once the user
/// allows it the grant is **app-wide**, so the subsequent libsmb2 / VLC traffic
/// is permitted too. Run this right before an SMB browse so the prompt appears
/// at a sensible moment and we can give a clear error if access is blocked.
enum SMBNetworkProbe {
    enum Outcome: Sendable {
        case reachable   // connected → permission granted + host up
        case blocked     // denied, wrong host, or unreachable in time
    }

    static func probe(host: String, port: UInt16 = 445, timeoutSeconds: Double = 8) async -> Outcome {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .blocked }

        // A tiny @unchecked-Sendable box so the Network-framework callbacks
        // (which hop in on their own queue) can resume the continuation exactly
        // once and tear down the connection, under Swift 6 strict concurrency.
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var finished = false
            var connection: NWConnection?
            var continuation: CheckedContinuation<Outcome, Never>?

            func finish(_ outcome: Outcome) {
                lock.lock()
                if finished { lock.unlock(); return }
                finished = true
                let cont = continuation; continuation = nil
                let conn = connection; connection = nil
                lock.unlock()
                conn?.cancel()
                cont?.resume(returning: outcome)
            }
        }

        let box = Box()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            box.continuation = continuation
            box.connection = connection
            let queue = DispatchQueue(label: "cz.zmrhal.aether.smb-probe")
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.finish(.reachable)
                case .failed:
                    box.finish(.blocked)
                // `.waiting` can be transient (incl. while the permission prompt
                // is on screen), so don't fail on it — let the timeout decide.
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) { box.finish(.blocked) }
        }
    }
}
