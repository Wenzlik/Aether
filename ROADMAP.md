# Roadmap

Aether ships in small, named milestones. Each one is shippable on its own — no milestone depends on a future one being "completed."

> Roadmap items are promises about *order*, not deadlines. The dates appear in `CHANGELOG.md` when a milestone actually ships.

**Status legend:** ✅ Shipped · 🚧 In progress · ⬜ Not started.

---

## ✅ 0.1 Foundation

The skeleton: a multi-platform SwiftUI shell that compiles on iOS and tvOS, with a mock library and a working AVPlayer prototype. No real network calls yet.

- SwiftUI multi-platform app shell (iOS + tvOS) ✅
- XcodeGen setup (`project.yml`) — project file is generated, not checked in ✅
- Shared package structure (`AetherCore`) wired into both app targets ✅
- Mock media library (in-memory, shipped as a JSON fixture) ✅ *(later retired from the running app once Plex landed; survives as test-only infrastructure)*
- Design system foundation: tokens, type, spacing, color, basic components ✅
- AVPlayer prototype: pick a mock title, play a sample video, show resume state ✅

**Shipped in main.** Notes: [`docs/next-steps/0.1-foundation.md`](docs/next-steps/0.1-foundation.md).

---

## ✅ 0.2 Media Sources

Real media, from real servers. This is the milestone that turns Aether from a shell into a player.

- ✅ **Plex connector** — PIN sign-in UI, server discovery (with off-LAN failover via persisted connection set), libraries + items, direct-play stream URLs, transcode fallback for incompatible containers, show → seasons → episodes drill-down. Persistent server selection survives launches.
- ✅ **Plex playback aligned with Plex Web** — PUT-then-decide pipeline (`PUT /library/parts/{partId}` → `GET /video/:/transcode/universal/decision` → `start.m3u8` or direct file URL), source-of-truth stream selection on the Part, structured `os.Logger` diagnostics. Resolves the audio-switch unreliability + pause/resume HTTP 400 that the original Plex pipeline carried.
- ✅ **Playback quality picker** — Detail-screen choice between Original / Convert Automatically / six bitrate caps (20 / 12 / 8 Mbps 1080p, 4 / 2 Mbps 720p, 720 kbps). Decision-endpoint-driven; projected playback mode (Direct Play / Direct Stream / Transcode) shown inline.
- ✅ **Native video player** — `AVPlayerViewController` (rotation, full-screen, system transport, PiP, AirPlay, subtitle/audio track picker). Chrome auto-hides on iOS / visionOS in sync with the native transport.
- ✅ **Settings + Sign Out** — reachable Settings screen (Account / Sources / Playback / About), Sign Out of Plex / Jellyfin that clears keychain + persisted server + every source-related field. No more app reinstall to disconnect.
- ✅ **Aether Design System v1** — `Aether*` prefix across all reusable primitives (Card, SectionHeader, Button, EmptyState, LoadingState, ErrorState, SettingsRow, SelectionRow, DisclosureRow), with designed empty / loading / error states everywhere they're needed.
- ✅ **Aether brand identity** — violet palette + warm gold accent extracted from the app icon, `AetherWordmark` component (small / medium / large + optional tagline), `Gradients.cinematic`, branded hero on Home / Library / Settings / sign-in surfaces.
- ✅ **Jellyfin connector** — manual server URL + **Quick Connect** sign-in, libraries + items, seasons/episodes, direct-play + HLS transcode (audio/subtitle stream selection, resume offset). A second `MediaSource` alongside Plex; the app keeps one **active source**, switchable in Settings → Sources. App Transport Security relaxed (`NSAllowsArbitraryLoads`) so plain-HTTP Jellyfin servers (the common case) are reachable.

Carried forward to 0.3 / 0.4 — not blockers for this milestone but worth tracking:

- ⬜ **Synology connector** — auth (DSM session or Video Station, spike first), shares + collections + items, stream URLs (direct play + server transcode fallback). *(Lower priority now that Jellyfin covers the "second source" goal; Synology stays optional.)*
- ⬜ **Plex Web parity for the Quality picker** — `X-Plex-Client-Profile-Extra` so Plex can evaluate true direct play on the decision endpoint without the client falling back to direct stream. Currently we always send `directPlay=0` to avoid HTTP 400; sending a real client profile would unlock direct play for MKV/HEVC content that AVPlayer can actually decode.
- ⬜ **Artwork pipeline upgrade** — disk-backed LRU + downsampling inside `CachedAsyncImage` (today is a thin wrapper around `AsyncImage`).
- ⬜ **Persistent ResumeStore** — SwiftData-backed; today is in-memory. Outbox plumbing for offline writes lands properly in 0.3.
- ⬜ **Accurate library counts** — display `Plex MediaContainer.totalSize` on `LibraryBrowseView` per-library headers instead of `items.count` (which is a best-effort lower bound on libraries that exceed one page).

**Shipped in main.** Definition of done: sign in to a real Plex server *and* a real Jellyfin server, switch between them as the active source, play a title from each, see resume state on next launch — all done.

Notes: [`docs/next-steps/0.2-media-sources.md`](docs/next-steps/0.2-media-sources.md).

---

## ✅ 0.3 Offline

Travel mode. Downloaded titles play with the network completely off.

- ✅ **Background downloads** — `URLSession.background` actor
  (`DownloadManager`) with a bridging `URLSessionDownloadDelegate` that
  forwards progress / completion / failure into the actor via
  `AsyncStream`. Tasks survive app suspension and resume on
  re-launch via `taskDescription`-keyed lookup.
- ✅ **Offline playback** — `PlaybackSession.prepare` checks the
  download store before resolving via the source; if a `.completed`
  job exists and `AVURLAsset.isPlayable` says yes, the player gets
  the file URL directly. Unplayable codecs fall back to streaming
  transparently.
- ✅ **Local persistence** — `DownloadStore` actor with a Codable
  JSON file in Application Support (excluded from iCloud backup).
  Snapshots stream via `AsyncStream<DownloadSnapshot>` so
  `@MainActor`-bound `DownloadObserver` can mirror state into SwiftUI
  views without actor hops at render time.
- ✅ **Storage management** — a dedicated **Storage** tab (replaces
  Search in the bottom bar) with total downloaded bytes, device free
  space, per-source breakdown, in-progress + completed sections with
  Pause / Resume / Cancel / Retry / Delete actions, and Clear All.
  Tapping any row pushes Detail; the offline-playback override picks
  up the local file from there.
- ✅ **Plex downloads aligned with Plex Web.** Original quality hits
  the raw Part URL (`/library/parts/{partId}/{ts}/{filename}?
  download=1`) — no transcoder involvement, works through the remote
  endpoint where the universal-transcoder progressive-MP4 path returns
  HTTP 400. Quality caps still flow through the transcoder
  (re-encoding requires it).
- ⬜ **Persistent ResumeStore** — SwiftData-backed; today is in-memory.
  Outbox plumbing for offline writes lands properly here. *(Carried
  forward — the offline-playback flow doesn't need it; resume points
  sync via iCloud KVS, which works without a backing store.)*
- ⬜ **Disk budget** — explicit cap with LRU eviction. Storage tab
  surfaces totals and free space; the budget enforcement is the next
  layer. *(Carried forward.)*

**Shipped in main.** Definition of done: download a title on Wi-Fi
→ toggle airplane mode → playback works end-to-end — done.

Notes: [`docs/next-steps/0.3-offline.md`](docs/next-steps/0.3-offline.md).

---

## 🚧 Vision Pro Cinema

Immersive, native cinema playback on Apple Vision Pro (visionOS only).

- ✅ **V1 — Dark Theater foundation** *(shipped to staging)* — native
  `AVPlayerViewController` docked into an immersive Dark Theater via the system
  docking pattern; single-source-of-truth `CinemaManager`; reliable enter/exit.
  No custom rendering or controls.
- ⬜ **Phase 2 — Enhanced Cinema** — authored Dark Theater + custom
  `DockingRegion` (real Medium/Large/IMAX/Wall presets), floor media
  reflections, smoother transitions, lighting tuning.
- ⬜ **Phase 3 — More environments** — Nebula / Deep Space / Orbit Station.
- ⬜ **Phase 4 — Advanced** — SharePlay synchronized viewing, Spatial Personas.

Notes: [`docs/next-steps/visionos-cinema.md`](docs/next-steps/visionos-cinema.md).

---

## ⬜ Unified Library (next major milestone — proposed 0.5.0)

Make the *source* an implementation detail. Users stop thinking Plex /
Jellyfin / offline and think **Movies / TV Shows / Downloads**. A single
`UnifiedMediaItem` aggregates every source behind a title (dedup by external
IDs), with source priority and automatic best-source playback; downloads
become just another source. Includes a navigation refactor, Settings cleanup,
and an Emby connector, and is designed so future catalog-only connectors slot
in.

Notes: [`docs/next-steps/0.5-unified-library.md`](docs/next-steps/0.5-unified-library.md).

> Numbering: the user designates this **0.5.0**. The "0.4 Premium UX" /
> "0.5 Distribution" entries below predate the shipped 0.4.0 and need
> reconciling — left as-is for now.

---

## ⬜ Search & Filtering (proposed 0.6)

Builds on Unified Library: richer, **source-agnostic** filtering that works the
same whether content comes from Offline / Plex / Jellyfin / Emby. Filter by
**audio language**, **subtitle language** (+ forced / SDH), **video** (4K · 1080p
· HDR · Dolby Vision · HEVC · H.264), **audio format** (stereo · 5.1 · 7.1 ·
Atmos · DTS · DTS-HD MA · TrueHD), and **source** — behind a compact Apple-TV /
Infuse-style filter UI (a Filters button → expandable chip sheet), not a
settings-form. Matching runs over `UnifiedMediaItem`: a title matches when any
one source satisfies all active dimensions.

- ✅ **Search keyboard dismissal** — `@FocusState`; tap-outside / scroll /
  select / Search-Done all dismiss the keyboard. *(Shipped ahead, PR #107.)*
- ⬜ **`MediaFilter` model + matching** (AetherCore, unit-tested).
- ⬜ **Compact filter UI** (button + badge → chip sheet), wired into **Search**,
  then **Library**.
- ⬜ **Jellyfin `mediaInfo` backfill** — map Jellyfin `MediaStreams` → `MediaInfo`
  so **video filters** (4K/HDR/DV/codec) work for Jellyfin too. Until then video
  filters are **Plex-only** (audio/subtitle/source work everywhere).

Notes: [`docs/next-steps/0.6-search-filtering.md`](docs/next-steps/0.6-search-filtering.md).

---

## ⬜ 0.4 Premium UX

The polish milestone. This is where Aether earns the "premium" label.

- Immersive detail screens — cinematic backdrops, typography-led metadata, soft depth
- Cinematic transitions between library, detail, and player
- Player overlays — chrome that fades, gestures that feel right, scrubbing that feels expensive
- Subtitle and audio track controls (selection, sizing, positioning)
- tvOS focus polish — every focusable element has intentional focused/unfocused states; section focus works; remote feels great

**Definition of done:** a stranger can use the app on Apple TV without instructions and the experience feels at home next to the system TV app.

---

## ⬜ 0.5 Distribution

Get it into people's hands without embarrassment.

- Xcode Cloud-backed internal TestFlight pipeline
- Localization scaffolding (`Localizable.xcstrings`) and at least English + Czech
- Accessibility: VoiceOver labels, Dynamic Type on iOS, sufficient contrast, focus reachability on tvOS
- App Store preparation: privacy manifest, screenshots, store copy, support URL

**Definition of done:** a TestFlight invite link works on iPhone, iPad, and Apple TV; accessibility audit passes; the App Store listing is reviewable.

Notes: [`docs/next-steps/0.5-distribution.md`](docs/next-steps/0.5-distribution.md).

---

## Beyond 0.5

Captured as ideas, not promises. Lives in [`docs/product/PRODUCT_SPEC.md`](docs/product/PRODUCT_SPEC.md) under "Future ideas."

Examples currently on the table:

- iCloud sync of resume state across devices when no media server is reachable
- Shared watchlists between Plex and Synology libraries
- Apple Watch now-playing surface
- Picture-in-picture on iPad with multi-touch gestures
- Personal "watch with friends" via SharePlay
