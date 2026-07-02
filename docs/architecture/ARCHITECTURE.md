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
│      Plex/, Jellyfin/, Emby/, Local/, SMB/                   │
│      (shared `MediaSource` protocol the rest of the app      │
│      talks to; SMB's actual connector lives in the app       │
│      target — see Module rules)                              │
│                                                              │
│   Library                                                    │
│      UnifiedLibrary (actor) — fans out across every          │
│      connected source, dedupes into one merged catalog       │
│                                                              │
│   Playback                                                   │
│      PlaybackSession (actor), PlayerStateViewModel           │
│                                                              │
│   Downloads                                                  │
│      DownloadManager (actor) + URLSession background config  │
│                                                              │
│   Storage                                                    │
│      KeychainStore, ResumeStore, UnifiedLibrarySnapshotStore │
│      DesignSystem/AetherImageCache (artwork LRU cache)       │
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

**App-target navigation.** `RootTabView` is the root: a native SwiftUI `TabView` (Home / Library / Discover / Search / Settings) — one structure, no per-platform navigation code. Its presentation adapts per platform: a collapsible leading **sidebar** on iPad (`.sidebarAdaptable`, #391), the **top tab bar** on tvOS, the **bottom bar** on iPhone, and the default **ornament** on visionOS. (A tvOS sidebar was tried in #527 but **reverted**: `.sidebarAdaptable` triggers a SwiftUI tvOS bug where a `NavigationStack` inside it doesn't pop on the Menu button — it exits the app — breaking Settings and every drill-down. Revisit via `NavigationSplitView`, on-device.) Each content tab owns a `NavigationStack`; the `mediaNavigationDestinations` modifier registers the `MediaItem → DetailView` and `Library → LibraryView` destinations so every stack pushes the same screens. Settings is a full-screen tab (not a sheet); only sign-in remains modal.

**Multiple sources, merged.** Five connectors implement `MediaSource` today — Plex, Jellyfin, Emby, Local Library, and SMB — and the app is source-agnostic above the protocol. The user can connect several at once (multiple Jellyfin/Emby servers, a second Plex account, etc.); `UnifiedLibrary` (`AetherCore/Library/`) fans out across every connected source and dedupes into one merged catalog, which `UnifiedLibraryGridView` and the Home/Discover rails read. There's no per-source UI any more — source is an implementation detail behind a title. Jellyfin and Emby are MediaBrowser-family APIs and differ from each other only in small ways (Quick Connect + username/password vs Quick Connect only, skip-segments support); both differ from Plex in connector internals (typed server URL vs plex.tv discovery + ranked connections), but all five produce `MediaItem`s and answer `resolvePlayback`, so Detail, the player, resume, and the URL resolver are identical across sources. **SMB's `MediaSource` conformance (`SMBMediaSource`) lives in the app target, not AetherCore** — it browses and plays through VLCKit, which only the app target links (see Module rules, exception below).

**Availability ≠ playback (#360).** Netflix is an *availability* source, not a
playback `MediaSource`: Aether never streams it, it only shows where a title can
also be watched and links out. This lives outside the `MediaSource` protocol —
`WatchProvidersService` (AetherCore, over the existing `TMDbClient` Watch
Providers endpoints, with a 24h TTL cache) answers "is this on Netflix here?"
and "what's on Netflix to discover?". A `@MainActor @Observable`
`WatchAvailabilityStore` (app target) mirrors results so cards read them
synchronously in `body` (the `DownloadObserver` pattern) while lookups run in the
background. Netflix-*only* titles are modelled as synthesized, non-playable
`MediaItem`s under a new `MediaSourceID.external` / `MediaSourceKind.external`
case (`streamURL == nil`, never enters playback priority), so they flow through
the normal card / navigation / Detail pipeline; their Detail action is "Play on
Netflix".

> See [`../../AGENTS.md`](../../AGENTS.md) → *Design system* for the inventory of `Aether*` primitives and when to extend each.

---

## Module rules

1. **`Aether/` is thin.** SwiftUI views, navigation, platform-specific glue (`#if os(iOS)` / `#if os(tvOS)`). No networking, no parsing, no playback logic.
2. **`AetherCore/` is the brain.** Everything else.
3. **One module per concern.** New folders need a clear, naming-pass justification.
4. **Cross-platform first.** `AetherCore` must compile for iOS, tvOS, **and visionOS**. Platform-specific code goes in the app target behind `#if os(...)`.
5. **No back-edge from `AetherCore` to `Aether/`.** The package never imports the app target.

**Documented exceptions: SMB, per platform.** Both app targets keep their SMB connector together with the engine it feeds, rather than splitting persistence into `AetherCore`:

- **iOS (`Aether/Sources/SMB/`)** — `SMBMediaSource`, `SMBConnection`/`SMBConnectionStore`, and `SMBRangeProxy` stay in the app target because SMB browsing and playback go through VLCKit (media options, MRL construction, the local range-proxy that feeds VLCKit over localhost HTTP — #213), and only the app target links VLCKit.
- **macOS (`AetherMac/Sources/SMBShare.swift`)** — `SMBShare`/`SMBShareStore` stay in the app target because macOS mounts shares through the kernel SMB client (NetFS → smbfs) and plays the mounted file path directly with libmpv — fundamentally different plumbing from iOS's in-process SMB client, not just a different persistence layer.

`AetherCore/MediaSources/SMB/` still holds the source-agnostic pieces shared by both (`SMBMetadataStore`, `SMBWatchedStore` — TMDb matches and watched state, keyed by content not by connection). Anything that doesn't touch a platform-specific mount/playback mechanism belongs in `AetherCore` as usual — e.g. plain session-state persistence (Plex Home profile, extra account tokens) lives in `AetherCore`'s `KeychainStore`, not duplicated per platform.

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
 MediaSource              Storage
 (Plex/Jellyfin/Emby/SMB) (Cache/Keychain)
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
- **`AetherImageCache`** (actor in `DesignSystem/`) owns the on-disk artwork LRU + in-memory cache.
- **`UnifiedLibrary`** (actor in `Library/`) owns the cross-source merged catalog and its TTL caches.
- **Each media source's auth holder** is an actor — Plex, Jellyfin, and Emby tokens are mutated by network calls.

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
- Each `MediaSource` (Plex, Jellyfin, Emby) owns its own `APIClient` instance with its own configuration (headers, auth interceptor).
- **Bounded timeouts by default.** `URLSessionAPIClient()` uses a shared session with a **15 s** request (idle) / **60 s** resource cap and `waitsForConnectivity = false` — *not* `URLSession.shared`, whose 60 s / **7-day** defaults let a quiet self-hosted / LAN server (Wi-Fi↔cellular handoff, a sleeping NAS, a wedged reverse proxy) hang a small API call — a Plex transcode decision, a Jellyfin `PlaybackInfo`, the Search discovery fetch — as a frozen spinner. These are lightweight JSON calls; large media rides the `DownloadManager`'s own background session, so short caps are safe. A per-request `timeoutInterval` still overrides where a call wants a tighter bound (the Plex reachability probe; the transcode warm-up polls with a 6 s per-attempt cap).
- JSON decoding uses `JSONDecoder` with `.convertFromSnakeCase` where the API gives us snake_case (Plex), explicit `CodingKeys` for the MediaBrowser-family PascalCase APIs (Jellyfin/Emby) otherwise.
- No third-party HTTP layer.
- **App Transport Security is relaxed** (`NSAppTransportSecurity / NSAllowsArbitraryLoads = true` in `project.yml`'s Info.plist properties) so Aether can reach self-hosted servers — Jellyfin / Emby / NAS-hosted SMB setups rarely ship a valid TLS cert, and per-domain ATS exceptions can't enumerate user-entered hostnames. Matches Infuse, VLC, and the official Jellyfin client; Apple accepts the justification for personal-media clients at review time. Plex stays on `*.plex.direct` TLS; the bypass is for the long tail of personal servers.

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
  Sources without a `partID` (mock, legacy tests, Jellyfin/Emby/Local/SMB direct play) fall back to the protocol's default implementation. Diagnostics ride on a structured `os.Logger` (`subsystem cz.zmrhal.aether`, category `plex.playback`) that logs quality / decision mode / verdict / codec / warm-up status — token-free.
- **Transcode warm-up + session lifecycle.** A fresh URL isn't enough — the server may not have produced the playlist when AVPlayer opens it. `PlexTranscodeSessionManager` warms up the HLS master playlist (poll until HTTP 200 + `#EXTM3U`, short exponential backoff) *inside* `resolvePlayback` after the decision step, so the player never gets a cold URL; a failed warm-up throws `PlaybackResolveError.notReady(diagnostics:)` (token-free) which `PlaybackSession` surfaces as a controlled "Unable to prepare playback" state. `ResolvedPlayback` also carries `clientSeekSeconds` (small offsets ≤ 12 s aren't sent to the transcoder — its first segment may not exist — so the player seeks instead), `transcodeSessionID`, and `decision: PlaybackDecisionMode?` for the Media block on Detail. The session manager tracks active sessions; `PlaybackSession` stops them via `MediaSource.stopTranscode(sessionID:)` on teardown — **detached** (fire-and-forget), so a slow stop never gates the next episode's resolve. Jellyfin and Emby also implement `stopTranscode` (`DELETE /Videos/ActiveEncodings`, keyed by `deviceId` + the `PlaySessionId` baked into the HLS URL); without it a self-hosted server keeps the ffmpeg job alive until its own idle timeout, and a binge starves the newest transcode.
- **Overlapping `prepare` is serialised by a generation token.** `prepare` suspends at several `await`s (teardown, resolve, the MainActor player build); a second `prepare` (an audio-track switch fired during an auto-advance, a recovery) can interleave there. Each `prepare` claims a monotonic generation on entry and, after every suspension, bails if a newer one has started — releasing the transcode session it resolved so it can't be orphaned (which would otherwise hit the server's simultaneous-transcode limit and stall the *next* episode). Player/session state is published only once a `prepare` has won.
- **Stall recovery (the native scrubber's safety net).** The native transport scrubs `AVPlayer` directly, and a server transcode produces HLS segments linearly from its start offset — so a seek far past what the transcoder has made asks for a segment that doesn't exist yet and the item stalls **without** flipping to `.failed` (it stays `.readyToPlay` with `timeControlStatus == .waitingToPlayAtSpecifiedRate`). `PlayerStateViewModel` watches for a sustained (~10 s) stall and routes it into `recoverOrFail`, which re-resolves a fresh stream at the **live** playhead (`currentPositionSeconds()`, not the coarse `state.position`). The recovery budget refreshes on healthy forward progress so repeated scrubs each recover, and our own programmatic seeks (Skip Intro/Credits) use a tolerant window for transcodes — an exact `.zero` seek stalls waiting for the precise HLS sample. Guard rails: the watchdog **arms only after the current player has actually played** (initial buffering also sits in `.waitingToPlayAtSpecifiedRate`, and a not-yet-ready player reports position 0 — recovering there would restart from the beginning and clobber the saved resume point, so position reads / resume writes also fall back to the last known position until the item is ready); recovery **preserves the paused state** (a failure while paused recovers paused, it never auto-plays); and `stop()` bumps the prepare generation so an in-flight recovery can't resurrect playback after the user closed the player. Ownership (`source`, player, transcode session id) is published only at a `prepare`'s win point, so a superseded prepare always releases its session against the server that minted it.

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

- **Artwork cache** (`DesignSystem/AetherImageCache`): on-disk LRU (256 MB budget, evicts down to 80% on overflow) + in-memory tier for posters, backdrops, thumbnails. Pre-fetched on focus in tvOS.
- **Unified catalog snapshot** (`Library/UnifiedLibrarySnapshotStore`): a Codable JSON file (not SwiftData), keyed by the connected source set + kind. Cross-launch persistence so the library shows instantly on relaunch; `UnifiedLibrary`'s own in-memory actor cache (45s TTL) sits in front of it for same-session re-reads. Stale-while-revalidate semantics: serve cached, refresh in the background, diff.

Cache invalidation happens on:

- Explicit pull-to-refresh.
- Server signaling a library version bump (where supported).
- App returning from background after >1 hour.

The cache is **not** the source of truth — the server is. Aether will always run against an empty cache.

---

## Image pipeline

```
URL ──► AetherImageCache.memory ──► AetherImageCache.disk ──► URLSession download
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

- All image loading flows through `AetherImageCache.image(for: url, maxPixel:)`.
- Decoding uses `CGImageSourceCreateThumbnailAtIndex` with a target size — never decode a 4K poster to display at 240pt.
- SwiftUI views use a small `CachedAsyncImage` view that talks to `AetherImageCache`. No raw `AsyncImage` in shipping code.

---

## Future sync possibilities

These are not in MVP, but the architecture leaves room for them:

- **Cross-source unified watchlist.** Already supported by `MediaItem` being source-agnostic at the view layer; needs a small `WatchlistStore` to land.
- **iCloud sync of resume state** when no server is reachable. Plug `Storage/ResumeStore` into CloudKit; the outbox model is already correct.
- **Watch / continue across devices via the local network.** Handoff has all the pieces; needs a small `NowPlayingActivity` definition.
- **Server-pushed updates.** Plex has a notifications API; Jellyfin/Emby have WebSocket events. A `MediaSource.eventStream` async sequence would slot in cleanly.

The point is: every one of these is additive. None requires re-shaping the module graph.

---

## What we are deliberately not doing

- **No central event bus** (`NotificationCenter`-as-state, `Combine`-everywhere). The dependency graph is explicit.
- **No GraphQL layer** — each connector talks its native API; there's no value in unifying at the wire format level when we already unify at `MediaItem`.
- **No DI container.** SwiftUI environment + initializer injection is enough.
- **No reactive framework on top of SwiftUI.** SwiftUI is reactive enough. RxSwift / ReactiveSwift do not belong here.
- **No code generation beyond XcodeGen.** Sourcery, Mockingbird, etc. — keep it simple.

When in doubt: prefer Apple primitives, prefer fewer concepts.
