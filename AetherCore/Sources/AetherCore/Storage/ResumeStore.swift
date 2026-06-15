import Foundation

/// Persistent resume-point store with three layers:
///
/// 1. **In-memory** dictionary for hot reads (every UI render asks the store).
/// 2. **On-disk JSON** for survival across launches. Written synchronously on
///    every `record(_:)` — the file is small (a few hundred entries max) and
///    the actor's serialisation makes concurrent writes safe.
/// 3. **iCloud Key-Value Store** for cross-device sync. Pushed on *committing*
///    writes only (pause / stop), not every 5-second tick — Apple throttles
///    KVS writes and we don't want to fight the throttle. An external-change
///    notification handler merges incoming state from other devices on the
///    user's iCloud account.
///
/// Merge policy is **latest `updatedAt` wins per `MediaID`** — consistent
/// across all three layers. The struct is small, atomic, and a stale write
/// from a slow device can't clobber fresh local state.
///
/// Domain models (`ResumePoint`, `MediaID`, `MediaSourceID`) stay Codable-free.
/// Persistence goes through `WirePoint`, a private struct that flattens the
/// `MediaSourceID` enum into a `(kind, parameter)` pair we can encode without
/// any Codable conformance on the public types.
///
/// Tests construct the in-memory-only variant (`ResumeStore()`); production
/// passes a `diskURL` plus `NSUbiquitousKeyValueStore.default`.
public actor ResumeStore {
    /// File name under the documents directory used by `defaultDiskURL()`.
    public static let defaultStoreFileName = "resume-store.json"
    /// Key under `NSUbiquitousKeyValueStore` for the encoded payload.
    public static let icloudKey = "aether.resumePoints"

    private var points: [MediaID: ResumePoint] = [:]
    private let storeURL: URL?
    private let icloudStore: NSUbiquitousKeyValueStore?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var observerTask: Task<Void, Never>?

    /// Default-init = in-memory only. Suitable for tests, previews, and the
    /// rare bootstrap case where neither disk nor iCloud is reachable.
    /// Production injects both via `AppSession.init`.
    public init(diskURL: URL? = nil, icloud: NSUbiquitousKeyValueStore? = nil) {
        self.storeURL = diskURL
        self.icloudStore = icloud
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// Standard documents-directory path. Returns `nil` if Foundation can't
    /// hand us a documents URL (effectively never — but the API can throw).
    public static func defaultDiskURL() -> URL? {
        do {
            let docs = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return docs.appendingPathComponent(defaultStoreFileName)
        } catch {
            return nil
        }
    }

    // MARK: - Reads

    public func point(for id: MediaID) async -> ResumePoint? {
        points[id]
    }

    /// Snapshot of every stored point. Used by `HomeFeedBuilder` and
    /// `LibraryView`'s continue-watching rail.
    public func allPoints() async -> [ResumePoint] {
        Array(points.values)
    }

    // MARK: - Writes

    /// Record a resume point.
    ///
    /// - `committing == false` (default for the 5-second tick): updates
    ///   in-memory + disk only. Cheap, runs every tick without rate concerns.
    /// - `committing == true` (pause, stop, app backgrounded): also pushes to
    ///   iCloud KVS so other devices see the latest position. Keep this rate
    ///   well below KVS's documented (but unspecified) throttle by only
    ///   committing on user-driven transitions, not on the timer.
    public func record(_ point: ResumePoint, committing: Bool = true) async {
        merge(point)
        writeDiskIfPossible()
        if committing {
            writeICloudIfPossible()
        }
    }

    /// Drop the resume point for an item — used when it finishes (played to the
    /// end / marked watched), so it stops appearing in Continue Watching and the
    /// "Resume a second before the end" never happens. Persists to disk + iCloud.
    public func clear(for id: MediaID) async {
        guard points.removeValue(forKey: id) != nil else { return }
        writeDiskIfPossible()
        writeICloudIfPossible()
    }

    // MARK: - Lifecycle

    /// Hydrate the in-memory store from disk + a one-shot iCloud read.
    /// Call once from `AppSession.start()` before any UI reads.
    public func loadFromDisk() async {
        loadDiskIntoMemory()
        await mergeFromICloud()
    }

    /// Begin listening for external iCloud changes (writes from other devices
    /// on the same iCloud account). Each notification triggers a merge using
    /// the same latest-`updatedAt`-wins rule as direct writes.
    public func observeICloudChanges() async {
        guard let icloudStore else { return }
        icloudStore.synchronize()
        observerTask?.cancel()
        observerTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: nil
            ) {
                await self?.mergeFromICloud()
            }
        }
    }

    // MARK: - Internals

    private func merge(_ incoming: ResumePoint) {
        if let existing = points[incoming.mediaID],
           existing.updatedAt >= incoming.updatedAt {
            return
        }
        points[incoming.mediaID] = incoming
    }

    private func loadDiskIntoMemory() {
        guard let storeURL else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let wires = try decoder.decode([WirePoint].self, from: data)
            for wire in wires {
                if let point = wire.toResumePoint() {
                    merge(point)
                }
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First run, nothing to read.
        } catch {
            // Corrupted file or unreadable — keep memory empty rather than
            // crashing playback. A subsequent write will overwrite.
        }
    }

    private func writeDiskIfPossible() {
        guard let storeURL else { return }
        do {
            let data = try encoder.encode(points.values.map(WirePoint.init(point:)))
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Disk write failures don't propagate — resume points are
            // best-effort, not load-bearing.
        }
    }

    private func writeICloudIfPossible() {
        guard let icloudStore else { return }
        do {
            let data = try encoder.encode(points.values.map(WirePoint.init(point:)))
            icloudStore.set(data, forKey: Self.icloudKey)
            icloudStore.synchronize()
        } catch {
            // Same logic as disk — silent fallback.
        }
    }

    private func mergeFromICloud() async {
        guard
            let icloudStore,
            let data = icloudStore.data(forKey: Self.icloudKey)
        else { return }
        do {
            let wires = try decoder.decode([WirePoint].self, from: data)
            var changed = false
            for wire in wires {
                guard let point = wire.toResumePoint() else { continue }
                let before = points[point.mediaID]
                merge(point)
                if points[point.mediaID] != before {
                    changed = true
                }
            }
            if changed {
                writeDiskIfPossible()
            }
        } catch {
            // Bad payload from iCloud — likely a future schema. Skip.
        }
    }
}

// MARK: - Wire type

/// On-disk + on-iCloud representation. Flat, primitive-typed so the public
/// domain types (`MediaID`, `MediaSourceID`, `ResumePoint`) don't need to
/// adopt `Codable`. Adding fields here is backwards-compatible: missing
/// optionals decode to `nil`.
private struct WirePoint: Codable {
    /// One of `"mock"`, `"plex"`, `"synology"`. Other strings decode as `nil`
    /// from `toResumePoint()` and are silently dropped — forwards-compatible
    /// with a future source type written by a newer client.
    let sourceKind: String
    /// `serverID` for Plex, `host` for Synology, ignored for `mock`.
    let sourceParam: String?
    /// Plex's `ratingKey` (or whatever the source uses to identify the item).
    let rawValue: String
    /// Resume position in seconds. `Double` round-trips cleanly through JSON.
    let positionSeconds: Double
    /// `updatedAt` as Unix epoch seconds.
    let updatedAtEpoch: Double

    init(point: ResumePoint) {
        let kind: String
        var param: String? = nil
        switch point.mediaID.source {
        case .mock:
            kind = "mock"
        case .plex(let serverID):
            kind = "plex"
            param = serverID
        case .jellyfin(let serverID):
            kind = "jellyfin"
            param = serverID
        case .smb(let id):
            kind = "smb"
            param = id
        case .dlna(let udn):
            kind = "dlna"
            param = udn
        case .local:
            kind = "local"
        }
        self.sourceKind = kind
        self.sourceParam = param
        self.rawValue = point.mediaID.rawValue
        // `Duration` carries seconds + attoseconds; for resume positions we
        // only care about whole seconds + some fractional precision, so this
        // lossy conversion is fine.
        let comps = point.position.components
        self.positionSeconds = Double(comps.seconds) + Double(comps.attoseconds) / 1e18
        self.updatedAtEpoch = point.updatedAt.timeIntervalSince1970
    }

    func toResumePoint() -> ResumePoint? {
        let source: MediaSourceID
        switch sourceKind {
        case "mock":
            source = .mock
        case "plex":
            guard let param = sourceParam else { return nil }
            source = .plex(serverID: param)
        case "jellyfin":
            guard let param = sourceParam else { return nil }
            source = .jellyfin(serverID: param)
        case "smb":
            guard let param = sourceParam else { return nil }
            source = .smb(id: param)
        case "dlna":
            guard let param = sourceParam else { return nil }
            source = .dlna(udn: param)
        case "local":
            source = .local
        default:
            return nil
        }
        return ResumePoint(
            mediaID: MediaID(source: source, rawValue: rawValue),
            position: .seconds(positionSeconds),
            updatedAt: Date(timeIntervalSince1970: updatedAtEpoch)
        )
    }
}
