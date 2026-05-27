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
│      Tokens (color/type/space), components, motion           │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

The shape on disk mirrors the diagram. If it doesn't, that's a bug.

---

## Module rules

1. **`Aether/` is thin.** SwiftUI views, navigation, platform-specific glue (`#if os(iOS)` / `#if os(tvOS)`). No networking, no parsing, no playback logic.
2. **`AetherCore/` is the brain.** Everything else.
3. **One module per concern.** New folders need a clear, naming-pass justification.
4. **Cross-platform first.** `AetherCore` must compile for iOS and tvOS.
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

---

## Playback architecture

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

---

## Offline architecture

```
Library view ─────► DownloadAction (start / pause / delete)
                          │
                          ▼
                  DownloadManager (actor)
                          │
            ┌─────────────┼─────────────┐
            ▼             ▼             ▼
   URLSession        DownloadStore    DiskBudget
   (background       (metadata)       (LRU eviction)
   config)
            │
            ▼
   Local file in app's caches directory
```

- Downloads use a `URLSession` with a `background` configuration so they survive app suspension.
- `DownloadStore` persists download metadata (item id, source, local URL, sizes, dates) in a small SwiftData store.
- `DiskBudget` is a small actor that evicts least-recently-watched downloaded items when the user's configured cap is exceeded, unless the user has pinned an item.
- Offline playback resolves the local URL first; if missing, falls back to the source's stream URL.
- Resume points written offline land in an outbox; they sync to the server next time the source is reachable.

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
