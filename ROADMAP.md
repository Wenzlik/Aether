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
- ✅ **Artwork pipeline upgrade** *(0.4.3)* — `AetherImageCache`: memory (`NSCache`) + disk cache, in-flight de-duplication (one download per poster across rails), ImageIO downsampling, stable token-stripped cache keys, prefetching, and `os.Logger` instrumentation. `CachedAsyncImage` now goes through it instead of raw `AsyncImage`. Fixed the Unified-Library poster-load regression.
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

## ✅ 0.4 Premium UX — "Andromeda"

The polish milestone — where Aether earns the "premium" label — plus the
performance work that made it feel fast. Shipped across the 0.4.x line.

- ✅ **Immersive Movie Detail** — cinematic hero-background layout, typography-led
  metadata, responsive wide layout (`0.4.4`).
- ✅ **Player track controls** — subtitle / audio selection through the native
  transport; chrome auto-hides in sync.
- ✅ **Skip segments** — source-agnostic `PlaybackSegment` with Plex / Jellyfin
  providers, Skip Intro / Skip Credits / Auto-Play-Next.
- ✅ **Watched state** — source-synced checkmark + write-back, manual Mark as
  Watched / Unwatched on Detail.
- ✅ **Manual refresh** — pull-to-refresh on iOS + tvOS Reload button, with poster
  prefetch.
- ✅ **tvOS focus polish** — intentional focused/unfocused states across cards,
  rows, and selectors; tab pop-to-root on re-selection (`0.4.2`).
- ✅ **Artwork pipeline** — `AetherImageCache` (memory + disk, in-flight dedup,
  ImageIO downsampling, prefetch), bounded disk cache with LRU eviction + Clear
  Image Cache (`0.4.3`/`0.4.4`).
- ✅ **Versioning + codenames** — constellation codenames (Andromeda → Boötes →
  Cassiopeia) and release-process docs (`0.4.1`).

**Shipped in main.**

---

## ✅ 0.5 Unified Library — "Boötes"

Make the *source* an implementation detail. Users stop thinking Plex / Jellyfin /
offline and think **Movies / TV Shows / Downloads**.

- ✅ **Unified aggregation** — a single `UnifiedMediaItem` aggregates every source
  behind a title (dedup by external IDs — Plex `includeGuids` / Jellyfin
  `ProviderIds`), with source priority and automatic best-source playback;
  downloads are just another source. Parallelized for faster first paint, with a
  short-TTL aggregation cache.
- ✅ **Home / Library / Discover, redefined** — Home is *watch now* (Continue
  Watching, Recently Added, Recently Released, Downloaded); Library is your
  *collection* (Movies / TV Shows / Downloads with counts, sortable & genre
  filtered "See all" grid); Discover is a hub (Featured, Top Rated, per-genre
  rails).
- ✅ **Redesigned Series Detail** — Next Up card, inline season selector, inline
  episodes, run-span + season/episode counts, status (continuing vs ended).
- ✅ **Rich metadata plumbing** — `MediaItem` carries genres, community rating,
  release/added dates, season/episode counts, end-year and continuing status from
  both connectors.

**Shipped in main.** Notes:
[`docs/next-steps/0.5-unified-library.md`](docs/next-steps/0.5-unified-library.md).

---

## 🚧 Vision Pro Cinema

Immersive, native cinema playback on Apple Vision Pro (visionOS only).

- ✅ **V1 — Dark Theater foundation** *(shipped to staging)* — native
  `AVPlayerViewController` docked into an immersive Dark Theater via the system
  docking pattern; single-source-of-truth `CinemaManager`; reliable enter/exit.
  No custom rendering or controls.
- ✅ **Phase 2 — Enhanced Cinema (0.5.5)** — image-based lighting, glossy
  reflective floor, dark skybox, cove + screen-bloom accents, grounding shadows,
  "house-lights-down" dimming, progressive immersion (code-only environment).
- ✅ **Phase 2b — Authored Dark Theater + in-cinema controls (0.5.8)** — the
  Reality Composer Pro `AetherDarkTheater.usda` (real `DockingRegion`) replaces
  the procedural room (procedural stays as fallback); a single immersive space;
  in-cinema controls for **screen size** (Medium/Large/IMAX/Wall) and **seat**
  (Front/Middle/Back, stadium rake). Because visionOS reads the dock only at
  attach, a live size/seat change triggers a brief re-dock to re-fit.
  *On-device verification (re-dock feel, scale tuning) pending TestFlight.*
- ✅ **Phase 2c — Controls in the native player (0.6.0)** — Screen-size + Seat
  moved off the floating RealityKit panel into the native player's **Info panel**
  as a "Theater" tab (`customInfoViewControllers`, the Destination Video pattern).
  A RealityKit attachment can't composite over the system-docked video (it hid
  behind the larger screens), and `contextualActions` only show while the
  transport bar is hidden (so they vanished on tap); the Info-panel tab renders in
  front, is reached by tapping the docked video, and persists while docked.
- ⬜ **Phase 3 — More environments** — Nebula / Deep Space / Orbit Station.
- ⬜ **Phase 4 — Advanced** — SharePlay synchronized viewing, Spatial Personas.

Notes: [`docs/next-steps/visionos-cinema.md`](docs/next-steps/visionos-cinema.md).

---

## 🚧 0.6.0 UX/UI Refresh — "Cassiopeia"

A coordinated, product-level design pass across iOS / iPadOS / tvOS / visionOS —
make Aether feel like a premium media product, not a technical client. Built as
one release (foundation-first, then ripple). Full spec + milestone breakdown:
[`docs/next-steps/ux-refresh-060.md`](docs/next-steps/ux-refresh-060.md).

- ✅ **Brand colour** — primary accent violet → premium blue `#6A8BFF`
  (`accentBright #5B7CFF`); purple demoted to a subtle secondary; warning →
  orange (distinct from brand gold). The `Palette.accent` repoint re-skins every
  interactive surface at once.
- ✅ **Layered backgrounds** — flat black → a three-stop gradient
  (`#0B0D12 / #111827 / #0A0A0F`) + faint brand blooms, applied on every screen
  through one shared `aetherScreenBackground()` modifier (player stays black).
- ✅ **Premium tvOS focus** — lift + soft blue glow (`premiumFocus`) instead of
  hard white outlines / accent boxes, across cards, buttons, and rows.
- ✅ **Continue-Watching progress** integrated into the artwork (frosted strip +
  blue fill), not a detached line.
- ✅ **Detail** — Resume leads, Restart secondary, the oversized "More" button
  demoted to a compact menu.
- ✅ **Search** — discovery rails before typing instead of a blank page.
- ✅ **Discover** — reordered as a discovery hub (Featured → Recently Added →
  Top Rated → genres → Picked for You).
- ✅ **Compact nav header** — brand mark inline beside search, reclaiming the
  vertical banner.
- ◻️ **Deferred to 0.6.x** — the full logo-into-nav-bar / visionOS ornament
  migration, and extracting a single shared rail component (consistency). The
  riskiest, device-only bits; everything else is in 0.6.0.

Notes: [`docs/next-steps/ux-refresh-060.md`](docs/next-steps/ux-refresh-060.md).

---

## ✅ 0.6.x — Polish & first non-server sources

Incremental releases on the 0.6 line, all shipped to main through the staging
pipeline.

- ✅ **Settings as a product hub (0.6.1)** — Support (Report a Bug / Feature
  Request / Send Diagnostics / Contact the Creator), visionOS Cinema prefs,
  About + release history.
- ✅ **Detail redesign (0.6.2)** — Infuse-density layout: action hierarchy,
  genres, collapsible overview, Cast & Crew, Technical Details (incl. Jellyfin
  MediaInfo), server-side Favorite.
- ✅ **tvOS polish + clearLogo + Library facets (0.6.6 / 0.6.7)** — focus pass
  across Detail / Library, season preview; stylized title-logo hero art;
  browse by Collections / Actors / Directors.
- ✅ **0.6.8 train** — first **SMB source** (connect-by-host) *(VLC bridge — see
  the SMB note below; it fails on-device and is being replaced)*, tunable
  watched posters (#280), tvOS technical metadata moved to a sheet (#281),
  episode → Season / Show navigation (#282), audio-track selection fix (#68),
  localized season titles + Hide-Watched toggle.
- ✅ **UI refresh** — Settings rebuilt as a **category index + focused
  subsections** (#289, #287); Detail uses the title artwork as a **full-screen
  cinematic background** (#290); Home / Library search collapsed to a top-right
  search button on iOS / visionOS; **swipe-down to dismiss** the player (#288);
  watch-progress correctness — partial vs fully-watched, recency-based Next Up,
  in-progress episode bars (#260).

---

## ⬜ Search & Filtering (proposed 0.7)

Builds on the Unified Library: richer, **source-agnostic** filtering that works
the same whether content comes from Offline / Plex / Jellyfin / Emby. Filter by
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

## ⬜ More Sources

New connectors that slot into the Unified Library — each is just another
`MediaSource` behind the same titles.

- ⬜ **Emby connector** — auth + libraries + items + playback, alongside Plex /
  Jellyfin. ([#171](https://github.com/Wenzlik/Aether/issues/171))
- 🚧 **SMB / DLNA** — browse and play from network shares without a media-server
  backend ([#172](https://github.com/Wenzlik/Aether/issues/172)). A first SMB
  bridge over VLCKit's `libsmb2` shipped in 0.6.8 but **fails on-device** (an
  opaque black box — no surfaced auth error, never triggers the iOS Local
  Network prompt), so SMB is moving to a **native AMSMB2** client for
  browse/auth + a local HTTP range proxy for playback; VLCKit stays for MKV
  decoding only ([#214](https://github.com/Wenzlik/Aether/issues/214),
  [#213](https://github.com/Wenzlik/Aether/issues/213)). DLNA/UPnP still to come
  ([#212](https://github.com/Wenzlik/Aether/issues/212)).
- ⬜ **Local Library & file uploads** — import / play local files on-device.
  ([#173](https://github.com/Wenzlik/Aether/issues/173))
- ⬜ **Synology connector** *(optional, deprioritized)* — DSM session or Video
  Station auth, shares + collections + items, direct play + transcode fallback.
  Lower priority now that Jellyfin covers the "second source" goal.
  ([#15](https://github.com/Wenzlik/Aether/issues/15))

---

## ⬜ Distribution (proposed 0.8 / 1.0 readiness)

Get it into people's hands without embarrassment. The Xcode Cloud → TestFlight
pipeline already feeds `main`; the rest of this milestone is the App-Store-ready
layer.

- ✅ **Xcode Cloud-backed internal TestFlight pipeline.**
- ⬜ **Localization scaffolding** (`Localizable.xcstrings`) and at least English +
  Czech.
- ⬜ **Accessibility** — VoiceOver labels, Dynamic Type on iOS, sufficient
  contrast, focus reachability on tvOS.
- ⬜ **App Store preparation** — privacy manifest, screenshots, store copy,
  support URL.

**Definition of done:** a TestFlight invite link works on iPhone, iPad, and Apple
TV; accessibility audit passes; the App Store listing is reviewable.

Notes: [`docs/next-steps/0.5-distribution.md`](docs/next-steps/0.5-distribution.md).

---

## Beyond

Captured as ideas, not promises. Lives in [`docs/product/PRODUCT_SPEC.md`](docs/product/PRODUCT_SPEC.md) under "Future ideas."

Examples currently on the table:

- Disk budget with explicit cap + LRU eviction for downloads *(carried from 0.3)*
- SwiftData-backed persistent ResumeStore + offline write outbox *(carried from 0.3)*
- iCloud sync of resume state across devices when no media server is reachable
- Apple Watch now-playing surface
- Picture-in-picture on iPad with multi-touch gestures
- Personal "watch with friends" via SharePlay (Vision Pro Cinema Phase 4)
