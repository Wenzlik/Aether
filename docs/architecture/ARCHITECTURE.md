# Aether — Architecture

Aether is small on purpose. The architecture is deliberately lightweight so that two years from now, the codebase still fits in one head.

This document describes how the pieces fit together, what lives where, and the rules that keep it sane.

---

## High-level shape

```
┌──────────────────────────────────────────────────────────────┐
│                      Aether (app target)                     │
│                                                              │
│   SwiftUI views ─ Navigation ─ Platform glue (iOS / tvOS)    │
│                                                              │
└─────────────────────────────┬────────────────────────────────┘
                              │ depends on
                              ▼
┌──────────────────────────────────────────────────────────────┐
│                AetherCore  (shared Swift package)            │
│                                                              │
│   Models                                                     │
│      MediaItem, MediaSourceID, Stream, ResumePoint, …        │
│                                                              │
│   MediaSources                                               │
│      Plex/        — auth, libraries, items, stream URLs      │
│      Synology/    — auth, shares, items, stream URLs         │
│      (shared protocol that the rest of the app talks to)     │
│                                                              │
│   Playback                                                   │
│      PlaybackSession (actor), PlayerStateViewModel           │
│                                                              │
│   Downloads                                                  │
│      DownloadManager (actor) + URLSession background config  │
│                                                              │
│   Storage                                                    │
│      KeychainStore, MediaCache, ImageCache, ResumeStore      │
│                                                              │
│   DesignSystem                                               │
│      AetherDesign.* tokens, Aether* primitives (Card,        │
│      SectionHeader, Button, EmptyState, LoadingState,        │
│      ErrorState, SettingsRow, SelectionRow, Status,          │
│      aetherFocusRow), BackdropImage, CachedAsyncImage        │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

The shape on disk mirrors the diagram. If it doesn't, that's a bug.

**App-target navigation.** `RootTabView` is the root: a native SwiftUI `TabView` (Home / Library / Search / Settings) that renders as the tvOS top tab bar, the iOS bottom bar, and the visionOS ornament — one structure, no sidebar, no per-platform navigation code. Each content tab owns a `NavigationStack`; the `mediaNavigationDestinations` modifier registers the `MediaItem → DetailView` and `Library → LibraryView` destinations so every stack pushes the same screens. Settings is a full-screen tab (not a sheet); only sign-in remains modal.

**Multiple sources, one active.** Two connectors implement `MediaSource` today — Plex and Jellyfin — and the app is source-agnostic above the protocol (everything reads a single `source: (any MediaSource)?`). The user can connect both; `AppSession` keeps an `activeSourceKind` (persisted) and points `source` at the active connector. Switching happens in Settings → Sources. There is no merged multi-source feed yet — it can be layered on later without changing the protocol. Jellyfin differs from Plex only in its connector internals (one typed server URL + Quick Connect auth, vs plex.tv discovery + ranked connections); both produce `MediaItem`s and answer `resolvePlayback`, so Detail, the player, resume, and the URL resolver are identical for both.

> See [`../../AGENTS.md`](../../AGENTS.md) → *Design system* for the inventory of `Aether*` primitives and when to extend each.

---

## Module rules

1. **`Aether/` is thin.** SwiftUI views, navigation, platform-specific glue (`#if os(iOS)` / `#if os(tvOS)`). No networking, no parsing, no playback logic.
2. **`AetherCore/` is the brain.** Everything else.
3. **One module per concern.** New folders need a clear, naming-pass justification.
4. **Cross-platform first.** `AetherCore` must compile for iOS, tvOS, **and visionOS**. Platform-specific code goes in the app target behind `#if os(...)`.
5. **No back-edge from `AetherCore` to `Aether/`.** The package never imports the app target.

---

## Data flow

```
       User intent
            │
            ▼
   SwiftUI view (app target)
            │
            ▼
   ViewModel  (@MainActor)
            │  (async/await)
            ▼
   Service / actor  (AetherCore)
            │
   ┌────────┴─────────┐
   ▼                  ▼
 MediaSource       Storage
 (Plex/Synology)   (Cache/Keychain)
   │
   ▼
 URLSession (async/await)
```

- Views never call URLSession directly.
- ViewModels are `@MainActor`. They expose `@Published` (or `@Observable`) state to views and `async` methods that delegate to services.
- Services and managers are `actor`s when they own mutable state, plain types when they don't.
- All asynchronous boundaries use `async/await`. Combine is fine inside a view model for UI plumbing; it should not appear in core services.

---

## Actor usage

Where actors are required:

- **`PlaybackSession`** (actor in `Playback/`) owns the current `AVPlayer`, the current item, and the resume-write loop. Exactly one exists at a time.
- **`DownloadManager`** (actor in `Downloads/`) owns the active downloads and the background `URLSession` delegate plumbing.
- **`MediaCache` / `ImageCache`** (actors in `Storage/`) own on-disk state and an in-memory LRU.
- **Each media source's auth holder** is an actor — Plex tokens and Synology session cookies are mutated by network calls.

Where actors are *not* used:

- Pure model types — `struct`, `Sendable`.
- View models — `@MainActor` on the type, not via actor isolation.
- One-shot request builders — value types, no isolation.

Rule of thumb: **state that outlives a single call and is touched by more than one task lives in an actor**. Everything else doesn't need one.

---

## Async networking

All networking goes through a small `APIClient` in `AetherCore/MediaSources/`:

```swift
public protocol APIClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
```

- One implementation wraps `URLSession`.
- Test implementations conform to the same protocol.
- Each `MediaSource` (Plex, Synology) owns its own `APIClient` instance with its own configuration (timeouts, headers, auth interceptor).
- JSON decoding uses `JSONDecoder` with `.convertFromSnakeCase` where the API gives us snake_case (most of Plex/Synology), explicit `CodingKeys` otherwise.
- No third-party HTTP layer.
- **App Transport Security is relaxed** (`NSAppTransportSecurity / NSAllowsArbitraryLoads = true` in `project.yml`'s Info.plist properties) so Aether can reach self-hosted servers — Jellyfin / Emby / Synology / NAS-hosted setups rarely ship a valid TLS cert, and per-domain ATS exceptions can't enumerate user-entered hostnames. Matches Infuse, VLC, and the official Jellyfin client; Apple accepts the justification for personal-media clients at review time. Plex stays on `*.plex.direct` TLS; the bypass is for the long tail of personal servers.

---

## Playback architecture

> **Engine split by platform.** This section describes the **iOS/tvOS/visionOS**
> path (VLCKit 4 + AVPlayer, driven by `PlaybackSession`). The **macOS** app
> (`AetherMac`) instead plays through **libmpv** (the engine behind IINA) with its
> own `MpvClient` / `MacPlayerModel`. `AetherCore` is engine-agnostic
> (`resolvePlayback` returns a URL); each app target owns its player. Full
> details, integration gotchas, and the bundling/distribution story:
> [`PLAYER_ENGINES.md`](PLAYER_ENGINES.md).

```
SwiftUI Player view
        │
        ▼
PlayerStateViewModel (@MainActor)
        │   subscribes to / sends commands to
        ▼
PlaybackSession (actor)
        │
        ├── owns: AVPlayer, AVPlayerItem, AVPlayerLooper if needed
        ├── owns: ResumeWriter (debounced async loop)
        ├── observes: AVPlayer time + status via async streams
        └── publishes: PlaybackState (Sendable snapshot)
```

- One `PlaybackSession` per app process. Re-used across titles; rebuilt only when source type changes.
- `AVPlayer` itself is `@MainActor` in modern AVKit. The actor owns the *reference* but performs `@MainActor` calls explicitly when needed.
- Resume points are written every ~5s while playing, and on pause/stop. They are written **before** the network call to update the server (offline-first).
- AirPlay/PiP are configured by the view; the session is agnostic.
- **Track selection is a pre-playback Detail concern (state-only).** `MediaItem` carries `audioTracks` + `subtitleTracks` (parsed from the Plex `Stream` list — `streamType == 2` / `3`), a `selectedQuality: PlaybackQuality` (Original / Convert Automatically / six bitrate caps), and a `partID` (Plex `Media.Part.id`, decoded as a String). The `selectingAudioTrack` / `selectingSubtitleTrack` / `selectingQuality` transforms update those fields *and only those fields* — they never mutate `streamURL`. The URL is built fresh inside the source's `resolvePlayback`, so Detail can switch tracks or quality freely without poisoning the playback URL with stale ids. The in-player audio / subtitle pickers are removed: the player has no track-switching API any more, the user goes back to Detail to change selections.
- **Plex playback follows Plex Web's PUT-then-decide flow, not a single start.m3u8 ask.** `PlaybackSession` builds a `PlaybackRequest` (item id, **partID**, selected streams, **quality**, start offset) and calls `MediaSource.resolvePlayback(_:) -> ResolvedPlayback`. For Plex with a `partID` the resolver runs three steps:
  1. **`PUT /library/parts/{partId}?audioStreamID=…&subtitleStreamID=…`** so the chosen streams become the Part's canonical selection on the server (Plex's running metadata then reports `selected="1"` on those streams). Skipped when neither id is set.
  2. **`GET /video/:/transcode/universal/decision`** with the same query items it would send to `start.m3u8` (plus the user's quality caps → `maxVideoBitrate` / `videoResolution`). The response carries `Part.decision` ("directplay" / "copy" / "transcode") and the post-decision codec / bitrate / resolution. **`directPlay` is always `0` here** — without sending an `X-Plex-Client-Profile-Extra` codec/container profile, Plex returns HTTP 400 instead of "no directplay possible"; `directStream=1` carries the "preserve original" intent via container remux.
  3. **Build the playback URL from the verdict.** `directplay` → the file URL extracted from `Part.key` (no transcode session at all, client opens the original and seeks itself). `copy` / `transcode` → a `start.m3u8` URL — also pinned to `directPlay=0` because that endpoint is the transcode entrypoint, not a direct-play surface.
  Sources without a `partID` (mock, legacy tests, Synology direct play) fall back to the protocol's default implementation. Diagnostics ride on a structured `os.Logger` (`subsystem cz.zmrhal.aether`, category `plex.playback`) that logs quality / decision mode / verdict / codec / warm-up status — token-free.
- **Transcode warm-up + session lifecycle.** A fresh URL isn't enough — the server may not have produced the playlist when AVPlayer opens it. `PlexTranscodeSessionManager` warms up the HLS master playlist (poll until HTTP 200 + `#EXTM3U`, short exponential backoff) *inside* `resolvePlayback` after the decision step, so the player never gets a cold URL; a failed warm-up throws `PlaybackResolveError.notReady(diagnostics:)` (token-free) which `PlaybackSession` surfaces as a controlled "Unable to prepare playback" state. `ResolvedPlayback` also carries `clientSeekSeconds` (small offsets ≤ 12 s aren't sent to the transcoder — its first segment may not exist — so the player seeks instead), `transcodeSessionID`, and `decision: PlaybackDecisionMode?` for the Media block on Detail. The session manager tracks active sessions; `PlaybackSession` stops them via `MediaSource.stopTranscode(sessionID:)` on teardown.

---

## Offline architecture

```
Detail · Storage tab ─► enqueue / pause / cancel / remove
                                   │
                                   ▼
                       DownloadManager (actor)
                       ├─ URLSession.background (one per app process)
                       ├─ URLSessionEventBridge (NSObject delegate → AsyncStream)
                       └─ expectedCancellations: Set<UUID>
                                   │
                                   ▼
                       DownloadStore (actor)
                       ├─ in-memory dict (jobs + statuses)
                       └─ Codable JSON file in Application Support
                                   │
                                   ▼   snapshotStream
                       DownloadObserver (@MainActor @Observable)
                                   │
                                   ▼
                            SwiftUI views
                            (Storage tab, Library "Downloaded" rail,
                             Detail Download row)
```

- **`DownloadManager` (actor)** — single instance per app process,
  owns one `URLSession.background` (identifier
  `cz.zmrhal.aether.downloads`). Public API: `enqueue` / `pause` /
  `resume` / `cancel` / `remove`. On launch `recoverExistingTasks()`
  walks `session.allTasks` and re-binds each task to its `DownloadJob`
  via `taskDescription = jobID.uuidString`.
- **`URLSessionEventBridge` (class)** — `URLSessionDownloadDelegate`
  conformance is on a class (Apple requires NSObject), so a small
  bridge yields delegate callbacks into an `AsyncStream<DownloadEvent>`
  the actor drains. The file **move** from the system daemon's temp
  container to Application Support runs synchronously inside the
  delegate, not after the actor hop — URLSession deletes the temp
  file the moment the delegate returns, so any async hop loses the
  file.
- **`DownloadStore` (actor)** — in-memory dict of jobs + statuses
  with a Codable JSON file at
  `~/Library/Application Support/Aether/downloads.json` (excluded
  from iCloud backup). Writes are atomic (single-file replace) and
  fire a fresh `DownloadSnapshot` into every `snapshotStream()`
  iterator after each mutation.
- **`DownloadObserver` (`@MainActor @Observable`)** — mirrors the
  store's snapshot into a SwiftUI-readable property so views can
  query `observer.snapshot.status(for: mediaID)` synchronously in
  `body` without crossing the actor.
- **Source `downloadURL(for:quality:)` capability** — optional
  protocol method, default `nil`. Plex returns the raw Part URL
  with `?download=1` for `.original` (no transcoder, single GET);
  bitrate caps fall through to the universal-transcoder MP4 endpoint
  (`protocol=http`). Each request first invalidates the cached
  connection so the user moving off LAN gets re-routed to the live
  remote / relay candidate.
- **Offline-first playback override** — `PlaybackSession.prepare`
  checks `downloadStore.status(for: item.id)`; if a `.completed` job
  exists AND `AVURLAsset.isPlayable` returns `true`, the player gets
  the file URL directly — no source call, no warm-up. Unplayable
  codecs (rare but real on MKV / DTS / TrueHD) silently fall through
  to the source layer; the user gets streaming playback instead of
  an error screen.
- **Background-launch lifecycle** — iOS wakes the app via
  `UIApplicationDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`
  when a download finishes while we're suspended. A minimal
  `AppDelegate` adapter on `AetherApp` stores the completion handler
  on a `@MainActor` singleton (`BackgroundDownloadCompletions`); the
  bridge calls `flushAndClear()` from
  `urlSessionDidFinishEvents(forBackgroundURLSession:)` once all events
  have been delivered.
- **Cancellation race protection** — `pause` / `cancel` / `remove`
  add the jobID to `expectedCancellations: Set<UUID>` *before*
  calling `task.cancel(...)`, because that call triggers
  `didCompleteWithError(NSURLErrorCancelled)` on the delegate. The
  `.failed` event handler drops events for ids in the set so a
  deliberate pause doesn't get overwritten with `.failed("Cancelled")`.
- **Resume points** still flow through the existing
  `ResumeStore` + iCloud KVS; nothing offline-specific is needed
  there. A disk budget + LRU eviction is the next layer (carried
  forward — Storage tab surfaces totals and free space today,
  enforcement comes later).

---

## Caching strategy

Two caches, two scopes:

- **Image cache** (`Storage/ImageCache`): on-disk LRU for posters, backdrops, thumbnails. Memory-mapped where possible. Pre-fetched on focus in tvOS.
- **Media metadata cache** (`Storage/MediaCache`): a thin layer over SwiftData. Library snapshots and item details. Stale-while-revalidate semantics: serve cached, refresh in the background, diff.

Cache invalidation happens on:

- Explicit pull-to-refresh.
- Server signaling a library version bump (where supported).
- App returning from background after >1 hour.

The cache is **not** the source of truth — the server is. Aether will always run against an empty cache.

---

## Image pipeline

```
URL ──► ImageCache.memory ──► ImageCache.disk ──► URLSession download
                                                       │
                                                       ▼
                                            decode (Image I/O)
                                                       │
                                                       ▼
                                         downsample to target px
                                                       │
                                                       ▼
                                       write to disk + memory cache
```

- All image loading flows through `ImageCache.image(for: url, target:)`.
- Decoding uses `CGImageSourceCreateThumbnailAtIndex` with a target size — never decode a 4K poster to display at 240pt.
- SwiftUI views use a small `CachedAsyncImage` view that talks to `ImageCache`. No raw `AsyncImage` in shipping code.

---

## Future sync possibilities

These are not in MVP, but the architecture leaves room for them:

- **Cross-source unified watchlist.** Already supported by `MediaItem` being source-agnostic at the view layer; needs a small `WatchlistStore` to land.
- **iCloud sync of resume state** when no server is reachable. Plug `Storage/ResumeStore` into CloudKit; the outbox model is already correct.
- **Watch / continue across devices via the local network.** Handoff has all the pieces; needs a small `NowPlayingActivity` definition.
- **Server-pushed updates.** Plex has it; Synology partially does. A `MediaSource.eventStream` async sequence would slot in cleanly.

The point is: every one of these is additive. None requires re-shaping the module graph.

---

## What we are deliberately not doing

- **No central event bus** (`NotificationCenter`-as-state, `Combine`-everywhere). The dependency graph is explicit.
- **No GraphQL layer** — each connector talks its native API; there's no value in unifying at the wire format level when we already unify at `MediaItem`.
- **No DI container.** SwiftUI environment + initializer injection is enough.
- **No reactive framework on top of SwiftUI.** SwiftUI is reactive enough. RxSwift / ReactiveSwift do not belong here.
- **No code generation beyond XcodeGen.** Sourcery, Mockingbird, etc. — keep it simple.

When in doubt: prefer Apple primitives, prefer fewer concepts.
