import Foundation

/// Process-global registry of OS-supplied completion handlers for background
/// `URLSession` events.
///
/// **Why this is a singleton.** iOS's
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
/// fires on the `UIApplicationDelegate` — a single process-level object. The
/// matching "all events delivered" signal arrives on a different surface:
/// `URLSessionDelegate.urlSessionDidFinishEvents(forBackgroundURLSession:)`,
/// inside the bridge owned by `DownloadManager`. Both edges of the OS
/// contract live in different ownership chains; a singleton is the cleanest
/// way to ferry the closure between them without giving the manager a view
/// of the AppDelegate or vice versa.
///
/// **Usage.** The app target's `AppDelegate` stores the closure on the
/// shared instance when iOS wakes us. The `URLSessionEventBridge` calls
/// `flushAndClear()` once URLSession reports it's drained its event queue —
/// that releases the OS-side latch so iOS can suspend us again. Without
/// this round-trip the OS keeps the app held in the background to avoid
/// "losing" events, which burns battery and looks like the app is wasting
/// resources in Settings.
@MainActor
public final class BackgroundDownloadCompletions {
    /// Process-wide shared instance. The OS-side callback fires once per
    /// app session at most, into a single AppDelegate; no need to scope.
    public static let shared = BackgroundDownloadCompletions()

    /// Stored handlers keyed by the session identifier the OS handed us.
    /// Plural for safety — in practice we only have one background
    /// identifier (`cz.zmrhal.aether.downloads`) but the OS API is
    /// per-identifier.
    private var handlers: [String: () -> Void] = [:]

    private init() {}

    /// Capture a completion closure handed to us by iOS via
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func storeHandler(_ handler: @escaping () -> Void, identifier: String) {
        handlers[identifier] = handler
    }

    /// Call every stored handler and forget them. Invoked from the
    /// `URLSessionEventBridge` when URLSession signals all background
    /// events have been delivered to the delegate.
    public func flushAndClear() {
        let drained = handlers
        handlers.removeAll()
        for handler in drained.values {
            handler()
        }
    }
}
