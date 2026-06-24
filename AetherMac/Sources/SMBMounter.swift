import Foundation
import NetFS

/// Mounts / unmounts SMB shares through macOS's kernel SMB client (NetFS →
/// smbfs).
///
/// A mounted share appears under `/Volumes` as an ordinary directory, which is
/// exactly why the Mac reuses `LocalFolderSource` for SMB instead of porting
/// iOS's userspace SMB stack: the kernel handles auth, seeking, caching and
/// reconnection, and mpv plays the mounted file path directly (libmpv/FFmpeg
/// on the Homebrew build has no `smb://` protocol, so a real filesystem path is
/// the only thing that plays).
enum SMBMounter {
    enum MountError: LocalizedError {
        /// The share couldn't be turned into a valid `smb://` URL.
        case invalidShare
        /// NetFS returned a non-zero status. The value is its POSIX-style code
        /// (e.g. `EAUTH`/`ENOENT`); we surface a friendly message per case.
        case mountFailed(Int32)
        /// The mount didn't finish within the timeout — `NetFSMountURLSync` can
        /// block for a very long time when the server is slow to negotiate
        /// (asleep, a different subnet / VPN, a flaky link). We fail fast so the
        /// library doesn't sit silently empty waiting on it.
        case timedOut

        var errorDescription: String? {
            switch self {
            case .invalidShare:
                return String(localized: "That doesn't look like a valid server or share name.")
            case .timedOut:
                return String(localized: "Couldn't reach the share in time — is the server on and on this network?")
            case .mountFailed(let status):
                switch status {
                case Int32(EAUTH), Int32(EACCES), Int32(EPERM):
                    return String(localized: "Couldn't sign in — check the username and password.")
                case Int32(ENOENT), Int32(ENODEV):
                    return String(localized: "The server or share wasn't found on the network.")
                case Int32(ETIMEDOUT), Int32(EHOSTUNREACH), Int32(ENETUNREACH):
                    return String(localized: "Couldn't reach the server — is it on and on this network?")
                default:
                    // Cast to Int so the extracted key uses %lld, matching the
                    // rest of the catalog's integer interpolations.
                    return String(localized: "Couldn't connect to the share (error \(Int(status))).")
                }
            }
        }
    }

    /// Mount `share`, returning the local mountpoint URL (e.g. `/Volumes/Media`).
    ///
    /// `NetFSMountURLSync` is a blocking call, so it's hopped onto a background
    /// queue. If the share is already mounted (e.g. the user mounted it in
    /// Finder, or a previous launch left it mounted), NetFS returns the existing
    /// mountpoint rather than failing.
    static func mount(_ share: SMBShare, timeout: TimeInterval = 20) async throws -> URL {
        guard let url = share.mountURL else { throw MountError.invalidShare }
        let username = share.username?.isEmpty == false ? share.username : nil
        let password = share.password?.isEmpty == false ? share.password : nil

        // `NetFSMountURLSync` is blocking and NOT cancellation-aware, so a task
        // group would deadlock waiting for the hung child even after a timeout.
        // Instead: one continuation, resumed by whichever finishes first — the
        // mount or the timeout. The loser's resume is dropped via `Once`. A
        // timed-out NetFS call keeps running detached until it returns; harmless.
        let once = Once()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { cont.resume(throwing: MountError.timedOut) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                // No UI: an auto-mount on launch must never pop a system dialog,
                // and a bad/again-needed credential should come back as an error
                // the Add sheet can show — not a modal behind the app.
                let openOptions: NSMutableDictionary = [kNAUIOptionKey: kNAUIOptionNoUI]
                var mountpoints: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(
                    url as CFURL,
                    nil,                                   // default mountpoint (/Volumes)
                    username as CFString?,
                    password as CFString?,
                    openOptions as CFMutableDictionary,
                    nil,                                   // default mount options
                    &mountpoints
                )
                guard once.claim() else { return }        // timeout already won
                guard status == 0 else {
                    cont.resume(throwing: MountError.mountFailed(status))
                    return
                }
                let paths = (mountpoints?.takeRetainedValue() as NSArray?) as? [String]
                guard let first = paths?.first else {
                    // Success with no path is unexpected; treat as a failure so
                    // the caller doesn't register a bogus folder.
                    cont.resume(throwing: MountError.mountFailed(status))
                    return
                }
                cont.resume(returning: URL(fileURLWithPath: first))
            }
        }
    }

    /// One-shot gate: the first caller to `claim()` wins, the rest get `false`.
    /// Lets the mount and the timeout race for a single continuation resume.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    /// Best-effort unmount (the user can also eject in Finder). Never throws —
    /// removing a share from the app shouldn't fail just because the volume is
    /// busy; we simply stop scanning it and stop auto-mounting it on launch.
    static func unmount(_ mountpoint: URL) {
        DispatchQueue.global(qos: .utility).async {
            _ = Darwin.unmount(mountpoint.path, 0)
        }
    }
}
