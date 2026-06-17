# Changelog

All notable changes to Aether are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Library is one combined grid** (iOS/iPadOS/tvOS/visionOS) — the landing no
  longer splits into a Movies rail + a TV Shows rail behind "See all". It opens
  straight into a single deduplicated grid of everything, with a **persistent
  Movies / Series toggle** in the top bar (two independent toggles — both on
  shows all; turning the last one off snaps both back on). The toggle stays put
  and just depresses, distinct from the genre / year / rating / audio filters,
  which still appear as removable chips and vanish when cleared. Browse facets
  (Genres / Years / Collections / Actors / Directors) sit just above the grid;
  pull-to-refresh re-fetches the catalog.
- **Library filter: "Downloaded" (works offline)** — a new Availability filter
  narrows the grid to downloaded titles, sourced from the local download store
  so it works with no server connection (replaces the old Downloaded rail).

## [0.7.9] — 2026-06-17

### Fixed

- **Library watched badge stuck on stale state** (iOS/iPadOS) — marking a title
  watched/unwatched synced to the server correctly, but the Library kept showing
  the old badge. `markWatchedEverywhere` updated the server without invalidating
  the shared unified caches (the 45 s in-memory `UnifiedLibraryCache` and the
  cross-launch `UnifiedLibrarySnapshotStore`), and the grids only reloaded on a
  source-set change — so the badge didn't refresh until a relaunch / pull-to-
  refresh. The watched write now drops the affected cache + snapshot entries, and
  an `AppSession.libraryRevision` signal (folded into the Library landing's and
  the "See all" grid's reload key) re-reads the fresh server state immediately.

- **macOS: collapsed sidebar stranded navigation** (#432) — once the macOS
  sidebar was collapsed there was no other way to switch Home / Discover /
  Library / Search / Settings: no menu-bar command, no shortcut. A new **View**
  menu now lists every section with **⌘1…⌘5**, driven by the same selection the
  sidebar binds to (hoisted onto `MacSession`), so section switching is always
  reachable regardless of sidebar state. The active section shows a menu
  checkmark. A *macOS navigation* section was added to `DESIGN_PRINCIPLES.md` so
  this is a rule, not an accident. (Titlebar-chrome polish during Search is
  tracked separately — pending on-device repro.)

- **Player dismiss collided with system controls** (#431, iOS/iPadOS) — the
  custom close ✕ sat on the same top-leading edge AVKit uses for PiP / AirPlay,
  crowding them, and its own auto-hide timer desynced from AVKit's (staggered
  flicker). The ✕ over live playback is gone: **swipe-down** (#288) is now the
  one canonical dismiss, made discoverable by a one-time, auto-fading "Swipe
  down to close" hint centred away from every AVKit-owned edge. A close ✕ still
  appears *only while the stream is preparing* (no AVKit chrome on screen yet),
  so a hung "preparing" can't strand the user on a spinner. tvOS (Menu),
  visionOS (native Back), and the macOS libmpv player (its own chrome, no system
  PiP/zoom) were unaffected.

- **Background battery — idle network monitor & carousel ticker** (iOS/iPadOS) —
  two periodic workers kept running while the app was alive behind a playing
  audio session. The SMB reachability `NWPathMonitor` is now paused on
  `didEnterBackground` (a network handover no longer fires a 3 s probe +
  cache-invalidation behind the lock screen) and restarted with an immediate
  re-probe on foreground; the Discover hero carousel's 1 Hz auto-advance tick is
  gated to the foreground so it stops waking the CPU for an off-screen carousel.
  Playback-bound loops (AVPlayer poll, resume-write, VLC ticker) were already
  suspended on background; this closes the two that weren't.

- **Offline playback of downloads** (#428, all platforms) — downloaded titles
  could fail to play offline with a confusing remote-server error
  (`NSURLErrorDomain -1009`). The player picked its engine from the *server*
  stream URL, so a downloaded mkv was routed to AVPlayer and then fell through
  to a network resolve while offline; separately, a stale absolute `file://`
  path (after a restore/migration that changed the data-container UUID) made a
  present download look missing. The windowed player now prefers the local
  download and picks the engine from the downloaded file's container, and a new
  `DownloadStatus.existingLocalURL()` re-bases moved downloads onto the current
  downloads directory. On visionOS, "Original" is hidden in the download quality
  picker for containers Cinema's docked AVPlayer can't demux, so the download
  transcodes to a playable mp4.

### Internal

- `SettingsView.swift` split into per-concern files (#415): 1 925 → 712 lines,
  with Sections and PreferenceSheets each in their own file. Pure mechanical
  extraction, no behavior change (same playbook as #241).

## [0.7.8] — 2026-06-17

### Added

- **Emby** (#425, all platforms) — connect an Emby server via Quick Connect (same
  handshake as Jellyfin): open the code on any signed-in Emby client or the
  Dashboard, and Aether authenticates in seconds. Browse, search, and play your
  Emby library alongside Plex and Jellyfin. macOS wired in `MacSession` +
  Settings.
- **New app icon** (#426, all platforms) — refreshed icon across iOS, tvOS,
  visionOS, and macOS.

### Changed

- **Background performance** (#416–419, iOS/tvOS/visionOS) — four targeted fixes
  to reduce CPU/battery when Aether is not in the foreground: VLC ticker suspended
  while backgrounded, AVPlayer poll slowed from 1 s → 5 s during paused playback,
  image prefetch rate-limited to 4 concurrent tasks with stale-batch cancellation,
  and the PlaybackSession resume loop self-gated on app background.

### Internal

- `DetailView.swift` split into per-concern files (#241 inc 4–6): 3 317 → 631
  lines, with Layouts, Hero, Actions, PlaybackConfig, and SeasonsEpisodes each in
  their own file.

## [0.7.7] — 2026-06-16

### Added

- **iPad: sidebar navigation** (#391) — the root tab bar now uses `.sidebarAdaptable`
  on iPad. The user can toggle between the compact top tab bar and a left sidebar
  (their choice persists). iPhone and tvOS/visionOS are unchanged.

### Changed

- **Detail: unified action cluster** (#382) — the primary pill row and separate
  tertiary icon row are collapsed into a single Infuse-style cluster. `AetherIconButton`
  and `AetherIconCircleLabel` are now borderless; the active state reads through an
  accent-filled circle + white glyph. tvOS focus still uses `premiumFocus` lift + glow.
- **Discover: rotating featured carousel** (#381) — the static random hero is replaced
  by a 3–7 slide carousel (in-progress titles first, then top-rated, then random picks).
  Slides auto-advance and are tap/click/focus navigable; excluded from source-only-if-available
  filtering so the carousel always has content.
- **Library: compact browse + filter controls** (#383) — the full-width Browse disclosure
  rows (Genres / Years / Collections / Actors / Directors) are replaced by a compact
  horizontal pill row at the top of the content area. iOS/iPadOS only; tvOS keeps its
  category list untouched.
- **Source switcher: compact pill** (#380) — the full-width Available Sources scroll section
  in Detail is replaced by a labelled capsule pill Menu (e.g. `Plex ▾`). Single-source
  details hide it entirely. Active source is checked; preferred source is tagged. tvOS uses
  a focusable button that pushes a picker screen.

### Fixed

- **tvOS Netflix detail — Back closes app** (#377) — a Netflix-only detail with no launch
  button (tvOS can't open the Netflix app) had nothing focusable, so the system interpreted
  Back/Menu as "exit app". The block now self-focuses when no button is present, matching
  the `AetherEmptyState` / `AetherErrorState` convention.
- **tvOS Settings — section titles scroll with content** (#378) — `.navigationTitle`
  on tvOS drifted into the rows instead of staying fixed. An explicit title is now laid out
  above the `ScrollView` on tvOS; the system title is suppressed there.
- **iPadOS episode/season detail — landscape wastes trailing half** (#379) — on iPad regular
  width, Detail now renders a two-column layout: primary content in a roomy leading column,
  Technical Details and Cast & Crew in a fixed trailing column. Narrow split-view and iPhone
  stay single-column.
- **Settings — Feature Request email body was empty** (#384) — the form required only the
  Title field, so a title-only request produced an email body containing nothing but the
  diagnostics footer. The Title is now included at the top of the body.

## [0.7.6] — 2026-06-15

### Added

- **Library: active-filter summary** (#367, all platforms) — once you narrow a
  category grid, a row of **removable chips** above the grid shows exactly which
  facets are on (genre, audio language, rating, each year) with a **Clear all**.
  Tap a chip's ✕ to drop just that facet; the row vanishes when nothing's
  filtered. Surfaces filter state without reopening the sheet, and on tvOS the
  chips are focusable so a fully-filtered (empty) grid is never a focus trap.
- **Library: search inside category grids** (#369, iOS/iPadOS/macOS) — the Movies
  / TV Shows grid is now `.searchable`, filtering by title **client-side** (no
  reload, like the facet filters). The Filter control is also **labeled**
  ("Filter" beside the glyph on iPad, icon-only on iPhone; macOS already had a
  labeled Filter menu) so it's discoverable next to Search and Sort.
- **Home: Continue Watching in-place actions** (#368, all platforms) — long-press
  (iOS/iPadOS), the focused-card menu (tvOS), or right-click a Continue Watching
  card for **Mark as Watched** and **Remove from Continue Watching**. Remove
  drops the title from the rail **without** marking it watched — it zeroes the
  server playhead (Plex On Deck / Jellyfin Resume) so it stays gone across
  devices and survives the next server re-seed, rather than reappearing.

### Changed

- **iPad top chrome** (#370) — Home / Library / Discover now show the **app-icon
  brand mark** in the top tab-bar leading slot (tap it to pop the tab to its
  root), with search (and Library's Filter) on the same row — no second header
  band, more content above the fold. iPhone / visionOS / tvOS keep the inline
  wordmark header.
- **Library: one unified Filter** — the landing's Filter opens the full,
  fully-filterable Library grid in one place: **Type** (All / Movies / TV Shows)
  alongside Genre / Audio / Rating / Year + search. The filter sheet opens
  full-height with **wrapping** chips, so every option is visible at once.
- **Library: audio filter** now lists only the app's own UI languages (cs / en /
  uk) rather than every track language in the library; Filter sits left of Sort
  to match the landing.

### Fixed

- **Mark as Watched on an in-progress title** now clears its resume point (so it
  leaves Continue Watching) and asks for confirmation first, since marking
  watched discards the saved position. Continue Watching's subtitle hints the
  long-press remove menu.

## [0.7.5] — 2026-06-15 · "Draco"

### Added

- **Primary Plex server** (#325 follow-up, all platforms incl. Apple TV) — with
  more than one Plex server connected, choose which one **streams first** when a
  title lives on several. Apple TV now also surfaces the full multi-server
  manager (it previously showed only one server), and macOS gains a server
  picker it didn't have. Settings ▸ Account ▸ Plex Servers.
- **Netflix availability** (#360, opt-in, all platforms) — see where titles you
  own are **also on Netflix** (a small "on Netflix" badge on posters + Detail),
  and discover **Netflix-only** titles as posters in **Discover** ("New on
  Netflix" / "Top on Netflix") and **Search**, with **Play on Netflix** linking
  out to the app/web. Off by default; enabled in **Settings ▸ Streaming
  Services** with a **Region** and a "show Netflix-only titles" switch (turn it
  off to keep Discover/Search to what you own — owned titles still get the
  badge). Powered by **TMDb Watch Providers** (data by JustWatch) — no new key.
  Aether never streams Netflix; it only links out. On **tvOS** it's badge +
  discovery only (no launch).
- **Discover revamp** (#350, all platforms) — dropped the genre rails in favour of
  curated rails: **New Releases** and **Top Rated** (plus Picked for You). Discover
  now also hides **in-progress** titles, not just fully-watched ones — they live in
  Continue Watching.
- **Library** (#351, all platforms) — **multi-select Year** filter and a compact
  **community-rating number** on poster cells.
- **Cross-device resume via the media server** (#352, all platforms) — playback
  progress now syncs through Plex/Jellyfin themselves, not just iCloud. The app
  reports the playhead while playing (Plex timeline / Jellyfin Sessions, #353) and
  seeds **Continue Watching** from the server's own resume list on load (Plex On
  Deck / Jellyfin Resume, #354). This gives macOS cross-device resume despite
  having no iCloud (Developer ID build), and works across non-Apple clients too.

### Changed — macOS parity & polish

- Detail now offers **Resume / Play from Beginning**, **Mark as Watched**, and
  **Favorite**; after playback you return to the **title's Detail**, not Home.
- Series: episodes open their **own Detail**; show Detail gains **Continue Watching
  / Next Up** (On Deck); episode/season **watched state** shows and refreshes.
- Detail **backdrop** fills the screen (crisp) like the other platforms.
- Settings: **TMDb key** is editable again, **Dark/Light** appearance switch wired,
  Library **Sort** opens in one click.
- Sidebar toggle returned to the leading edge beside a crisper brand logo.
- Build: **macOS 26** minimum (fixes the libmpv dylib version warning); the
  Xcode Cloud post-clone only fetches libmpv for the macOS workflow, so the
  iOS/tvOS/visionOS archives no longer fail on a missing `project.pbxproj`.

### Fixed

- Watched marking now also wires up on iOS/iPadOS/tvOS/visionOS via
  `markWatchedEverywhere` (macOS already did) — finishing or toggling a title syncs
  it across every connected source.

## [0.7.3] — 2026-06-14

### Added

- **Aether for macOS** (#232) — a native Mac app (Apple Silicon), sharing the
  whole `AetherCore` stack with iOS/tvOS/visionOS. A single Infuse-style window:
  sidebar (Home · Discover · Library · Search · Settings) and an inline player.
  - **Plays through libmpv** — the engine behind IINA — for best-in-class
    VideoToolbox HW decode, HDR/Dolby Vision, and libass subtitles. iOS/tvOS/
    visionOS keep VLCKit 4; the engines never mix. See
    `docs/architecture/PLAYER_ENGINES.md`.
  - **Plex & Jellyfin** sign-in, browse, Detail, playback; audio/subtitle/quality
    chosen on Detail (Plex bakes the selected track into the transcode).
  - **Local Library** — point at folders on the Mac or a mounted network share;
    Aether scans them for movies and shows (filename parsing → S01E02), matches
    posters/overviews via TMDb, and folds them into the unified library. Live
    scan status + Rescan in Settings.
  - **Continue Watching + resume** (disk-backed), library **search**, **Discover**
    with a Featured hero + genre rails, **Library** split into Movies / TV Shows
    with See All + sort & genre filters, and show → season → episode drill-down.
  - **Watched marking syncs across every connected source** — finishing a title
    scrobbles it on each source that has it (Plex `/:/scrobble`, Jellyfin
    `PlayedItems`), matched by shared external id. Shared in `AetherCore`, so all
    platforms can adopt it.
  - Finder "Open With ▸ Aether" / drag-and-drop for local files, full Settings
    (Playback defaults, Appearance/watched display, Accounts, TMDb key, Language),
    Czech localization, and a dark cinematic / glass look matching iOS.
  - **Self-contained distribution** — a Release build bundles libmpv + its ffmpeg
    dependency tree into the `.app`, so it runs without Homebrew.

### Changed

- **Watched marking now syncs across every source on all platforms** (#232) —
  iOS, iPadOS, tvOS, and visionOS adopt `markWatchedEverywhere`: finishing
  playback (incl. auto-play-next hand-off) or toggling watched on Detail now
  scrobbles the title on **every** connected source that has it — matched by
  shared external id — not just the one it streamed from. macOS already did this.

## [0.7.2] — 2026-06-13 · "Draco"

### Added

- **Connect multiple Plex servers from one account** (#325) — enable several
  servers at once; their libraries merge into one deduplicated Library (no
  switching). Existing single-server installs migrate with no re-sign-in.
- **Choose which Plex server to use** (#323) — when an account reaches several
  servers, a Settings picker overrides the automatic best-connection pick.
- **Ukrainian (uk) localization** — a full Ukrainian translation (290 strings);
  it appeared in Settings ▸ Language with no code change, the first language
  added purely by translating the catalog.

### Changed

- **More of the UI is Czech** (#320) — settings, Detail, Home, Discover, Search,
  empty/error states, the support flow, and the new multi-server picker now
  localize (~80 strings added to the catalog).
- **Adding a language is now just translating it** (#320) — the in-app Language
  list is derived from the bundle's localizations, so a new language appears in
  Settings automatically once it's translated, with no code change.
- **Faster Library filtering & facet browsing** (#334) — the audio-language
  filter loads the picked language lazily and caches it (no all-languages
  warm-up on open); Collections / Actors / Directors are cached too, so
  re-visiting them no longer re-fetches from every server.

### Fixed

- **Instant, lag-free Library audio-language filter** (#319) — the audio chip
  row filters the loaded catalog client-side from a prebuilt language→items
  map, so tapping a language is immediate and no longer shows the previous
  selection (the filter used to re-query the server per tap and could land a
  stale result).
- **Settings fully localizes** (#332) — the Settings category cards, screen
  titles, and toggle rows rendered raw strings (and row *descriptions* were
  never in the catalog), so a Czech/Ukrainian device still saw English there;
  those surfaces now localize, with the missing strings translated into both.

## [0.7.1] — 2026-06-12

Codename **Draco**. Czech localization plus a round of SMB / tvOS fixes from
0.7.0 on-device testing.

### Added

- **Czech localization** (#312) — the app follows the device language, with an
  in-app **Language** switcher (Settings ▸ Appearance) that also covers System /
  English; untranslated strings fall back to English. Built on a String Catalog,
  ready for more languages.
- **Edit SMB folders after sign-in** (#214) — the multi-folder picker is now
  reachable from Settings ▸ SMB ▸ Folders, not only at sign-in.

### Changed

- **SMB goes dormant off-network** (#214) — it's LAN-only, so off your home
  network it drops out of the Library (no failed walks, no errors) and
  auto-reappears when you're back.
- **Collections hidden when empty** (#298/#311) — the Collections row only shows
  when a connected source actually has collections (a Plex-only library with
  none no longer surfaces a dead row).
- **tvOS Settings** — boolean rows render as clean On/Off rows instead of heavy
  full-width toggle pills (#310).
- **SMB poster matching** is more robust — concurrent walks are coalesced (no
  TMDb rate-limit stampede) and a wholesale match failure no longer poisons the
  cache.

### Fixed

- **Crash dragging the WATCHED label-opacity slider** — a self-assigning `didSet`
  on an `@Observable` store recursed infinitely; clamping moved to the edges.
- **tvOS dead-end screens** (#311) — an empty/loading/error screen pushed onto a
  NavigationStack had nothing focusable, so the Back/Menu button exited the app
  instead of popping. Those states are now focusable on tvOS.
- **Auto-skipped credits now mark the episode watched** (#314) — with Skip
  Credits = Automatically, finishing an episode no longer left it unwatched (a
  seek to the end never posts the play-to-end notification we were relying on).
- **Dismissing after Auto-Play-Next lands on the right episode** (#315) — when
  playback had auto-advanced, closing the player now returns to the episode that
  was actually playing, not the one Play was first pressed on.
- **Audio / subtitle selection carries to the next episode** (#316) — Auto-Play-
  Next now keeps the chosen audio + subtitle language even when tracks carry no
  language code (matched by label) or differ only by region subtag.

## [0.7.0] — 2026-06-12

Codename **Draco**. SMB grows up — a native browse/auth rewrite with downloads,
poster matching, and a real player — plus Library/Search enhancements and a
Settings consistency pass.

### Added

- **Native SMB** (#214) — browse + auth rewritten on the pure-Swift
  `SMBClient` (Network-framework based), replacing VLC's opaque `libsmb2`
  bridge that never surfaced auth errors or reliably triggered the iOS Local
  Network prompt. Real errors, real reachability checks.
- **SMB multi-folder picker** (#214) — at sign-in, browse the server's shares,
  drill into subfolders, and add several folders to the library (an empty
  selection still scans every share).
- **SMB TMDb matching** (#214) — files carry no metadata, so inferred titles are
  matched to TMDb posters/overviews and persisted in a bounded, battery-safe
  store (each title matched once, misses remembered, no background daemon).
- **SMB editable title & year** (#214) — fix a mis-named release so it matches a
  poster; the correction re-matches TMDb on the next browse.
- **SMB downloads** (#214) — SMB streams aren't HTTP, so a `CustomDownloadSource`
  transfer path runs the byte copy as an async task with progress and
  pause/cancel, alongside the existing URLSession pipeline.
- **Rich VLC player** (#214) — the SMB/mkv player gains a scrubber, skip ±10s,
  audio + subtitle track selection, time readouts, and an auto-hiding overlay
  (iOS/visionOS; tvOS keeps its simpler controls).
- **Filter Library by audio language** (#295) — a shared `MediaFilter` model;
  Plex filters server-side, Jellyfin client-side from the audio tracks it
  returns in list responses.
- **Search by actor / director name** (#296) and **rating sort** as a
  first-class Library option (#294).
- **Personal TMDb token** in Settings ▸ Metadata — used instead of the built-in
  key, validated against TMDb before saving.

### Changed

- **Plex collections** (#298) now load via `…/all?type=18` (the old `/collections`
  path returned empty).
- **Library actor/director rows** show headshots (#297).
- **Tab navigation** (#300) — each tab keeps its stack across tab switches;
  re-tapping the active tab pops it to root.
- **SMB startup latency** — VLC `network-caching` trimmed 1500→800ms; a buffering
  spinner shows during connect so a slow start doesn't look frozen.
- **Settings consistency pass** — one picker style (disclosure → sheet) and one
  toggle style across the screen; App Icon and the visionOS Cinema pickers no
  longer use bespoke inline menus; watched-poster settings moved from Playback
  into Appearance; the WATCHED label opacity is a Transparent↔Solid slider.

### Fixed

- **VLC player controls were unreachable on iOS** — the full-screen overlay
  swallowed taps (so Done couldn't be reached); it now passes empty-area taps
  through to the show/hide gesture and keeps the chrome above the video.

## [0.6.8] — 2026-06-11

A new source type (SMB) plus Detail/watched polish.

### Added

- **SMB network shares as a source** (#214) — connect to a NAS by host (+ optional
  folder and credentials) in Settings ▸ Account ▸ SMB. Files are browsed over
  VLCKit's SMB modules and flattened into Movies + TV Shows via title inference;
  playback runs through the built-in VLC engine (mkv and all), with credentials
  passed as media options so the `smb://` URL stays credential-free. iOS prompts
  for Local Network access on first connect.
- **Episode → Season / Show navigation** (#282) — episode detail now shows
  "Season N" / "<Series>" pills (resolved from the parent), so an episode opened
  straight from Home is no longer a dead end.
- **Watched poster controls** (#280) — Settings ▸ Playback gains a **Watched
  Dimming** level (Subtle / Medium / Strong) and a **Show "Watched" Label** toggle.

### Changed

- **Bolder watched posters** (#280) — a bigger, bolder centered "WATCHED" tag and
  stronger default dimming so finished titles read at a glance across the room.
- **tvOS technical details decluttered** (#281) — the inline Technical Details
  section (which clipped + competed with primary content) is gone from the tvOS
  detail hierarchy; the full, scrollable details are one tap away via the action
  row's info button.
- **Created By** now also credits Yana Shamruk.

## [0.6.7] — 2026-06-11

A richer Season Detail on tvOS (#267) — the page had a dead bottom half, no
actors, and episodes that carried only a number and a date.

### Added

- **Episode preview while browsing** (tvOS) — focusing an episode still reads it
  out below the rail: ordinal title, runtime • air date • Resume/Watched, and a
  three-line synopsis. *Focus = preview, Select = open* — and it carries the
  weight when a source has no per-episode stills (identical thumbnails).
- **Cast & Crew on season pages** — the season's own cast when the source
  provides one, else the **parent show's** cast (new fallback fetch). All
  platforms.
- **Next Up on the Season Detail** — the same On Deck card as the show page,
  computed from the season's episodes; one click to continue, and the episode
  rail's Up focus target.
- **Title logo art on Detail** (#273) — when a server carries a clearLogo, the
  Detail hero renders the stylized wordmark (e.g. the MAD MEN logo) instead of
  a plain text title, with text as the fallback. Plex logos are served raw to
  preserve transparency; Jellyfin logos resize aspect-fit as Webp.
- **Library browsing by Collections, Actors and Directors** (#273) — three new
  facets beside Genres / Years: server collections (Plex collections / Jellyfin
  BoxSets), and every actor / director across the catalog, each opening a grid
  of their titles. In the tvOS category list and a new "Browse" section on
  iPhone / iPad / Vision Pro; rows appear only when a connected source supports
  the facet.

### Changed

- **Cleaner season header** — the metadata line no longer repeats "Season N"
  under the title (kept only for named seasons like "Asylum") and gains watch
  progress: `2017 • 11 Episodes • 7/11 watched`.

### Fixed

- **Settings can no longer be dragged sideways on iPhone** (#248, for good) —
  the scroll content's width is now hard-clamped to the viewport
  (`containerRelativeFrame`), so no row — present or future — can widen the
  page; the version row's texts also gained line limits.

## [0.6.6] — 2026-06-11

A tvOS-led pass toward the Infuse-style Detail + a richer Library, plus an iPhone
Settings fix. (All builds green on iOS / tvOS / visionOS.)

### Added

- **Library browsing by Genre and Year** (#266, tvOS) — alongside Movies and TV
  Shows, the Library now offers **Genres** and **Years** entries that list every
  genre / release year across the whole catalog and open a combined grid of all
  matching movies + shows. Keeps Library distinct from Home (browse, not rails);
  Collections / Actors / Directors are a future addition.
- **Focus-driven season preview** (#266, tvOS) — focusing a season card on a show
  page now previews that season inline (name, year · episode count · watch
  progress, and a short overview); selecting it still opens the dedicated Season
  Detail. *Focus = preview, Select = open.*
- **Episode still rail** (#266, tvOS) — a season's episodes browse as a horizontal
  rail of 16:9 stills with ordinal "N. Title" labels, instead of a vertical list.

### Changed

- **Redesigned Detail hero + metadata** (#266) — an episode now leads with the
  **series name** and an "S1 • E2 — Title" line; one **dense metadata row**
  (runtime · air date · rating · resolution · audio) replaces the separate chip
  strip; and **compact Resume / Restart pills** carry the resume time inline.
- **Bolder Continue Watching progress** (#266) — a rounded, couch-visible progress
  bar across the artwork instead of a faint 2-pt hairline.
- **tvOS Library browses by category** (#266) — Movies / TV Shows / Genres / Years
  rows under Search, so D-pad Down lands predictably instead of skipping into a
  rail; the episode rail on a Season detail now uses the full screen width.
- **tvOS Discover Featured right-sized** (#266) — the hero is trimmed so the rails
  below it show without scrolling.
- **Clearer tvOS season focus** (#266) — a bolder accent glow + lift on the focused
  season card, and Up from any season card reliably reaches Next Up.

### Fixed

- **Settings no longer drags sideways on iPhone** (#248) — long values in rows
  (server name, OS/build, capacity) truncate instead of forcing rows wider than
  the screen; the Settings scroll view is explicitly vertical.
- **What's New modal scrolls on tvOS** (#266) — each card / release entry is its
  own focus stop, so the Siri Remote can move through (and scroll) all the notes.
- **More Like This focus** (#266) — Up-escapes from the rail via the real section
  above it; the earlier no-op header button is gone.
- **Episodes use the same bold gold watched marker as posters** (#266).

## [0.6.5] — 2026-06-11

### Added

- **Local Library: manual metadata & artwork editing** (#211) — correct or
  override what auto-matching got wrong. Tap the **pencil** on a local movie or
  episode (iOS / iPadOS / visionOS) to edit its title, year, kind, season /
  episode, and overview, re-match from TMDb and pick among candidate posters, or
  set a custom poster from Files. Overrides **win over** the TMDb match and the
  filename guess, persist across launches, and propagate everywhere — the Detail
  screen repaints in place, and re-grouping follows (e.g. reclassifying a movie
  as an episode moves it into TV Shows).
- **Richer TV seasons** (#245) — a multi-season show now presents a **rail of
  season poster cards** (artwork + title, with a watched marker) that open a
  **dedicated Season Detail** (season number, year, episode count, overview and
  the episode list) instead of a bare "Season N" selector with an inline list.
  Single-season shows skip the drill and show their episodes inline. *(Local
  Library shows stay flat for now — a synthetic season layer is a fast-follow.)*

### Fixed

- **A show's "Next Up" now points at the right episode** (#260) — it used to
  surface the first season with any unwatched episode (e.g. Season 3 while you
  were mid-Season 7). It's now proper **On Deck**, computed across all seasons:
  the most-recently-watched in-progress episode, else the one after the last you
  finished.
- **Partially-watched shows are no longer badged "watched"** (#260) — the
  watched marker on a show/season now requires **every** episode watched
  (`unwatchedEpisodeCount == 0`), not the raw source flag.
- **Episodes show their in-progress state** (#260) — a partially-watched episode
  now has a resume bar across its still and a "Resume hh:mm" caption in the list,
  so you can see at a glance how far in you are.
- **Library & Discover no longer go blank when the Local Library is present**
  (#263) — the unified catalog cached (and persisted) an **empty** result when a
  cross-source fetch came back empty (a server not ready at launch, or a hiccup).
  Because the cache key includes the connected-source set, importing local
  content changed the key and the first fetch under it could pin an empty
  catalog, stranding **Library "See all"** and **Discover** on "Nothing here
  yet" while Home (which keeps its last-good state) looked fine — and tvOS was
  unaffected (no Local Library, so the key never changed). Empty results are no
  longer cached or served; the next read self-heals. (You diagnosed this — thank
  you.)
- **Season cards show real season names** (#263) — anthology/named seasons now
  read **"S2 · Asylum"** instead of a bare, truncated "Seaso…"; generic
  "Season N" stays as-is, and the card title can wrap to two lines (wider on
  tvOS) so it no longer clips.
- **Continue Watching / Next Up now surfaces in-progress TV episodes** (#244,
  #263) — it previously only matched resume points against top-level movies and
  show *containers*, so a half-watched episode (whose resume point is keyed by
  the episode) never brought its show back. Now a show appears whenever it has a
  resumable episode, surfacing the one you're most likely to continue (most
  recently watched), mixed with movies by recency. This now holds on the
  **unified multi-source Home** too — the aggregated Continue Watching walks the
  live resume points and resolves episodes (grouped **per show**, via the series
  title, so a multi-season binge is one entry, not one per season), where before
  it only intersected resume points with the top-level catalog and so never
  showed a single in-progress episode. TV is a first-class citizen of Continue
  Watching.
- **tvOS: the library "See all" grid no longer displaces the top navigation**
  (#243) — `LibraryView` pinned a `navigationTitle`, which on tvOS never scrolls
  away and can overlap the tab-bar region, stranding focus on return from a
  pushed Detail. It now uses an in-scroll heading on tvOS (the same treatment
  the unified grid already had, #216); iOS/iPadOS/visionOS keep the native title.
- **Settings could be dragged horizontally on iPhone** (#248) — the content was
  capped at a fixed 820 pt width, which proposed that width to the full-width
  settings cards and made the page wider than the phone, so the vertical scroll
  view drifted sideways. Compact widths now use the viewport width; the page is
  horizontally anchored.
- **tvOS: "See all" and "More Like This" are reachable from any poster** (#266) —
  pressing **Up** out of a horizontal rail only worked from the tile geometrically
  beneath the target, so from any other poster focus was stuck (the same trap we
  removed from Cast & Crew in #249). Each rail now has a **full-width, single-
  focusable focus section directly above it** — the Library header's "See all"
  button, and a focusable "More Like This" title on Detail — so Up from *any*
  poster (even one scrolled far right) lands on it. iOS/iPadOS/visionOS unchanged.

### Changed

- **Cast & Crew moved lower on Detail, and the rail uses full width on tvOS**
  (#247) — Cast now sits below the primary actions, overview, sources and
  related content (it shouldn't compete with Resume / Episodes), and on tvOS the
  cast rail breaks out of the content column to span the full screen for easier
  browsing.
- **Cast & Crew is now passive on tvOS** (#249) — the cast cards were focusable
  but led nowhere, trapping focus and making it hard to leave the section. Until
  actor pages exist, the cards are non-focusable informational metadata (photo +
  name + character); the focus engine skips the rail and moves cleanly between
  the sections around it. iOS / iPadOS unaffected.
- **Watched titles are now obvious at a glance** (#246) — finished movies and
  episodes show **dimmed, desaturated artwork** plus a **bold checkmark in a
  folded gold top-corner marker** (larger on tvOS / visionOS), instead of a small,
  easy-to-miss icon. Unwatched (full artwork) and in-progress (progress bar)
  stay clearly distinct. Applied via `AetherCard`, so every grid and rail gets
  it.

## [0.6.4] — 2026-06-10

### Fixed

- **Storage Summary free space was far too low** (#231) — Settings and the
  Storage screen reported the space visible to the app's process (~10 GB on a
  device with >100 GB free) instead of the real device free space. Both now read
  `volumeAvailableCapacityForImportantUsage`, matching the figure iOS shows.

### Changed

- **Diagnostics no longer appears twice** (#224) — it lived under both Support →
  Send Diagnostics and About → Diagnostics. About → Diagnostics is now shown only
  on tvOS (which has no Support section / Mail composer); on iOS and visionOS,
  Support → Send Diagnostics is the single home.
- **Calmer Settings status labels** (#224) — healthy states (Connected, Active,
  Signed in) now read in quiet secondary text instead of bright green, so the
  red "Not connected" stands out where it matters. Colour is reserved for states
  you can act on.
- **"Contact Developer" → "Contact the Creator"** (#224) — a warmer label that
  fits a community-built app.
- **About Aether gained a short "what & why"** (#224) — a one-paragraph
  description of what Aether is, rounding out the product page.
- **Sources section merged into Account** (#224) — the separate Sources list
  duplicated Account (same Plex/Jellyfin servers). Account is now the single
  list: the server you're browsing shows an "Active" tag, and each source's
  sheet gains a **Set as Active Source** action next to Sign Out (an inline row
  on tvOS). The Synology "Planned" placeholder was dropped from the UI.
- **One "What's New" entry point** (#224) — it was a row in Support *and* the
  About → Version row. Removed the Support duplicate; the About "Version x.y.z
  (build) → What's New" row is now the single place it lives.

### Added

- **Local Library** (#173, v1) — play media that lives on the device, with no
  Plex / Jellyfin server needed. Import video files from Files (Settings → Local
  Library → Import Media…); Aether copies them into a managed store (excluded
  from iCloud backup), infers a title / year from the filename, and surfaces them
  in your unified library to play directly. **TV episodes group into shows** —
  files like `Severance.S01E02.mkv` nest under a show in TV Shows (drill show →
  episodes), while movies stay flat in Movies. Foundations (filename parsing
  #206, the `.local` source id #207) shipped first. *Fast-follows: share-sheet
  import, browser upload (#209), manual metadata editing (#211).*
- **Local Library metadata from TMDb** (#210) — imported files get **posters,
  a backdrop, overview and the canonical title/year** from The Movie Database
  (movies + TV), matched automatically on import. The TMDb key is injected at
  build time from the Xcode Cloud workflow environment (never committed to this
  public repo); with no key, titles simply fall back to the filename. A
  **Re-match Metadata** action (Settings → Local Library) backfills posters and
  details for titles imported before a key was available.
- **mkv (and other non-native formats) play locally** — files AVFoundation can't
  open (Matroska / AVI / …) now play through a bundled **VLCKit** engine, chosen
  automatically per file (`PlaybackEngine`); everything AVPlayer supports keeps
  the native player (controls / PiP / AirPlay). v1 has play/pause + progress;
  scrubbing, audio/subtitle selection and resume on this engine are fast-follows.
  Uses the official VideoLAN VLCKit (LGPL-2.1; vendored, not committed — fetched
  by `scripts/fetch_vlckit.sh`).

## [0.6.3] — Unreleased

Detail-screen redesign, **layout & UX pass** — a smaller, platform-aware hero
and a more efficient reading order, especially on iPhone. Pure presentation; no
new data.

### Changed

- **Settings refresh** (0.6.3 build 4) — a calmer, less "admin panel" Settings:
  - **Account** is now one compact row per service (`Plex — DS418`); tapping opens
    a detail sheet with the server, status, and Sign Out. The rarely-used
    destructive action no longer sits permanently on screen, and a healthy
    "Connected" badge is dropped — a source is only flagged when it needs you.
  - **Playback** rows lost their per-row icons — the section title is context
    enough, so the list reads as preferences, not a dashboard.
  - **What's New** moved into the **Support** section (alongside Report a Bug /
    Feature Request / Diagnostics).
- **iPhone-portrait movie layout** is now a **banner**, not a full-screen poster:
  a short backdrop band with the title, metadata, genres, badges and the action
  row stacked beneath it, so **Title · Metadata · Genres · Resume · Restart land
  above the fold** and content starts higher. Landscape, iPad, tvOS and visionOS
  keep the cinematic full-bleed hero (each with its own height) — the layout is
  no longer one set of proportions scaled to fit.
- **Shorter hero** across the board (the embedded description moved out), so
  sections like More Like This start higher.
- **Description now follows the actions** instead of preceding them — the first
  decision is "play this?", then "what's it about?".
- **Technical Details is collapsible** and starts tucked — rich info without
  padding out the page.
- **Available Sources** reads as a first-class section (Unified Library framing),
  showing which connected source is playing and letting you switch.

### Added

- **Favorite** — a heart in the Detail action row toggles the title's favorite
  state on the server, synced across clients. Available on Jellyfin
  (`UserData.IsFavorite`); hidden on Plex, which has no per-item favorite in its
  API.
- **Cast & Crew** — the Detail screen now shows a horizontal rail of cast (with
  the characters they play) and key crew, with circular headshots, on movies and
  episodes. Pulled from Plex (`Role`) and Jellyfin (`People`); closes the biggest
  information-density gap vs. Infuse.
- **First-use hint** for the compact icon row — a one-time caption names the
  icons (Download · Watch status · Source · Details), then the row stays clean
  forever (dismissed by "Got it" or by tapping an icon).

### Fixed

- **tvOS: Account Sign Out unreachable** (0.6.3 build 5) — the compact Account
  row opened a detail sheet for Sign Out, but the sheet couldn't be reached with
  the Siri Remote. tvOS now keeps Sign Out as a directly-focusable row inline
  (no sheet); iOS / iPadOS / visionOS keep the compact row → sheet.
- **Library "Show all" title pinned on tvOS** (0.6.3 build 4) — the grid's
  "Movies" / "TV Shows" heading used `.navigationTitle`, which tvOS pins
  permanently (it overlapped the grid while scrolling). It's now an in-scroll
  heading on tvOS that scrolls away with the content, as it does on iOS.
- **tvOS Detail focus & layout** (0.6.3 build 3) —
  - The "Got it" first-use hint was a touch affordance with no reachable focus on
    tvOS (a dead focus zone); it's now iOS / iPadOS / visionOS only.
  - **Cast & Crew focus** is now unmistakable from across the room — larger cards
    with a strong scale jump, an accent ring on the headshot, a blue glow, and a
    lift (the cards previously focused too weakly to track).
  - **Technical Details** is now an always-visible section on tvOS instead of a
    collapsible disclosure. The collapse animated a height change inside the
    focusable scroll that could corrupt focus — scrolling to More Like This and
    back sometimes lost the top menu. Static section fixes that and shows the
    richer info TV has room for.
  - The synopsis is trimmed to **3 lines on tvOS** so cast and the rest of the
    page sit higher (you browse visually from the couch, not read paragraphs).
- **Discover Featured on tvOS** (0.6.3 build 3) — replaced the oversized
  full-width focus panel (huge highlight, empty letterbox) with a constrained
  16:9 artwork that lifts gently on focus, paired with the title / year / genres /
  synopsis beside it. The artwork is the hero; the focus effect just enhances it.
- **Cast & Crew / content rating / favorite not showing on Detail** (0.6.3 build 2
  hotfix) — `MediaItem.copy()` didn't carry the new `cast`, `contentRating`, and
  `isFavorite` fields, so every Detail hydration (which always re-applies the
  quality preference through `copy()`) silently stripped them. The Cast & Crew
  rail, the content-rating badge, and the favorite heart now persist after the
  screen loads.
- **Series source switching** (#194) — alternate sources for a TV show no longer
  show as "Unavailable" in the Detail source picker. A show/season is a container
  you switch to and browse (it carries no stream URL of its own), so availability
  now treats containers as switchable on any source that has them, while a
  movie/episode without a resolvable stream stays correctly gated.

### Performance

- **Instant library on launch** (#197) — Home, Library and Discover now paint the
  **last known catalog immediately** from a persisted on-device snapshot instead
  of flashing a loading state while every server is re-queried. If the snapshot is
  more than an hour old it still shows instantly, then refreshes silently in the
  background; a first-ever launch (no snapshot) loads as before. Pull-to-refresh
  still forces a full refetch, and the snapshot is cleared on sign-out. Stored
  only on-device, in the app's cache.

## [0.6.2] — Unreleased

Detail-screen redesign toward Infuse-level information density while keeping
Aether's cinematic identity. Built in phases; this build ships **Phase 1**
(action hierarchy + information architecture) and **Phase 3** (technical details
+ new data plumbing).

### Added

- **Content rating** — the source's age classification (PG-13, TV-MA, 15, …)
  now appears as a thin-bordered badge in the Detail metadata line, on both Plex
  (`contentRating`) and Jellyfin (`OfficialRating`).
- **Technical Details** section (renamed from "Media Information") now also lists
  **Subtitles** (languages) and **File Size** alongside Video / Audio / HDR /
  Bitrate / Playback / Source.
- **Jellyfin codec/quality info** — Jellyfin items now surface the same
  resolution / HDR / Dolby Vision / codec badges and technical details Plex
  already had. Jellyfin's `MediaStreams` (and file `Size`) are mapped into the
  shared `MediaInfo` (previously Plex-only).

### Changed

- **Action hierarchy on Detail** — instead of a stack of equal-weight buttons,
  there's now **one dominant primary** (Resume or Play), a lighter **Restart**
  beneath it, and a **compact icon row** for everything else (Download · Mark
  Watched · Source · Technical Details) — Infuse-style circular icon buttons that
  no longer compete with Play. The "More" menu is gone; its actions live in the
  icon row. Download is a compact icon whose glyph reflects its state, with the
  management actions (pause / resume / cancel / delete / retry) in its menu.
- **Genres** now appear under the metadata line on movies and episodes (not just
  shows), so the kind of title reads at a glance.
- **Description collapses** to a few lines with a **More / Less** toggle, so a
  long synopsis no longer pushes the rest of the page down.
- **tvOS focus** — the compact icon buttons are focusable and reachable by the
  Siri Remote (lift + glow on focus).

### Notes

- Phase 2 (Cast & Crew rail) and Phase 4 (server-synced Favorite + Trailer)
  follow — they need new model/connector plumbing.
- File size and per-track subtitle metadata are only carried on the transcode
  path / when the source reports them, so those rows appear when available
  rather than always.

## [0.6.1] — Unreleased

Settings & product-experience polish — Settings grows from a configuration
screen toward a complete product hub. Refinement, not a redesign.

### Added

- **Recent searches** (#190) — the Search tab now remembers your recent queries
  and shows them as tappable chips before you type; tap one to re-run it, or
  Clear to forget them. Persisted, de-duplicated, and capped.
- **Support section** (iOS / iPadOS / visionOS) — Report a Bug, Feature Request,
  Send Diagnostics, and Contact Developer, each opening the system Mail composer
  to `aether@zmrhal.cz` (with a `mailto:` fallback when no mail account is set up).
  Bug reports collect a Subject, Description, and Category (Playback / Library /
  UI / Downloads / Cinema / Other) and auto-attach a **token-free** footer:
  version, build, platform, device model, OS, theme, timestamp. Excluded on tvOS.
- **Send Diagnostics** — generates a readable, **token-free** report (app, sources,
  library counts, downloads, cache, playback prefs), shows a preview, then emails
  it with the report attached. No tokens, passwords, or account details.
- **Diagnostics screen** — a user-facing read-only snapshot: sources, library
  counts, downloads, cache, and build/commit. Available on every platform.
- **About Aether** — a dedicated screen with the wordmark, "Personal media,
  beautifully played.", the author, and links. (Tapping the logo seven times
  unlocks a hidden Developer section with build / device / cache internals.)
- **What's New release history** — previous releases are listed beneath the
  current release's highlights.
- **Clearer settings** — per-row descriptions explain what settings do
  (e.g. App Icon: "Choose how Aether appears on your Home Screen"), and the
  Appearance picker offers **System / Dark / Light** (default System).
- **visionOS Cinema preferences** — the Cinema settings section becomes the home
  for immersive-playback defaults: **Default Screen Size**, **Default Seating**,
  **Environment**, plus **Auto-Enter Cinema** (start playback straight in the
  theater) and **Remember Last Setup** (reopen with the last-used size/seat
  instead of the defaults).
- **visionOS Cinema controls in the native player** — the in-cinema Screen-size
  and Seat controls live in the native player's **Info panel** as a "Theater" tab
  (the `customInfoViewControllers` surface Apple's Destination Video sample uses).
  Reached by tapping the docked video, they render in front of the screen at every
  size and persist while the video is docked.
- **Warmer Cinema environment** — the Dark Theater is retuned from a cool violet
  room to an **intimate warm screening room**: dark-wood walls + floor, warm
  tungsten lighting, a warm aisle glow at the screen base, and soft warm cove
  bands along the side walls. Authored `.usda` scene and procedural fallback both.

### Fixed

- **Home / Library / Discover loading & refresh** — the empty / "connected but no
  libraries" states no longer render as a half-screen band, and they're now
  scrollable so pull-to-refresh works on them (previously they could get stuck).
  Loading shows a calm animated-dots indicator, the app auto-refreshes when it
  returns to the foreground, and a connected source that returns empty (a
  transient first-load) auto-retries once so it self-heals. Crucially, a refresh
  that briefly comes back empty no longer blanks the screen — the existing content
  stays put instead of flashing "Library is empty". Discover now shares the same
  loading/empty/refresh behaviour.
- **Resume position no longer runs away** — pausing repeatedly could record a
  position that compounded past the runtime (e.g. 1h → 2.5h → 5h on a 2h film),
  which then broke "Resume". `PlaybackSession` recorded `currentTime()` plus a
  transcode "base offset", but the player timeline is already absolute on every
  path, so the offset was double-counted; it's been removed. Saved positions are
  now clamped to the runtime, and a corrupt/out-of-range saved point (left over
  from the old bug) resets to the start instead of failing to play.
- **Cinema Mode resume prompt** (visionOS) — "Watch in Cinema" now offers
  **Continue** or **Start Over** when a resume point exists.
- **Settings layout** — removed the redundant "Connected Sources" status card
  (the Sources section already shows each source's connection state). On the
  wide layout (iPad / tvOS / visionOS) the sections are split across two columns
  (configuration left; personalization, info and storage right), and the whole
  surface is centered instead of left-hugging — so tvOS uses the full width.
- **tvOS info sheets** — About / Diagnostics / What's New now scroll with the
  Siri Remote and use the full width (previously a narrow column that couldn't
  be scrolled).
- **Search no longer collapses while typing** (#189) — the results area kept its
  intrinsic height during the loading phase, shrinking the screen to ~half and
  breaking tap-/swipe-to-dismiss-keyboard. The loading + empty states now fill
  the screen, so the layout stays put and the keyboard dismisses like elsewhere.

## [0.6.0] — Unreleased · "Cassiopeia"

Coordinated UX/UI refresh across iOS, iPadOS, tvOS and visionOS — a premium,
cinematic identity. See `docs/next-steps/ux-refresh-060.md`.

### Changed

- **New brand colour** — the accent moves from violet to a premium blue
  (`#6A8BFF`); purple is now a subtle secondary. Everything interactive —
  buttons, focus, progress, badges, links — picks it up automatically.
- **Layered cinematic backgrounds** replace flat black on every screen
  (`#0B0D12 → #111827 → #0A0A0F` plus faint brand blooms), applied through one
  shared modifier so navigating never shows a background shift.
- **Premium focus on Apple TV** — focused cards / buttons / rows lift and glow
  softly instead of drawing hard white outlines.
- **Continue Watching progress** is integrated into the artwork (a frosted
  strip with a blue fill), not a detached line.
- **Detail pages** — Resume leads, Restart is secondary, and the oversized
  "More" button is demoted to a compact menu so it never competes with Resume.
- **Search** comes alive before you type — discovery rails (Recently Added /
  Released) instead of a blank page.
- **Discover** reordered as a discovery hub (Featured → Recently Added → Top
  Rated → genres → Picked for You).
- **Compact navigation header** — the brand mark sits inline beside search
  instead of a large centered banner, reclaiming vertical space.

### Notes

- tvOS / visionOS visuals (focus feel, gradient depth, nav placement) are best
  verified on-device via TestFlight.
- Deferred to a 0.6.x follow-up: the full nav-bar / ornament logo migration and
  extracting a single shared rail component (consistency).

## [0.5.9] — Unreleased · "Boötes"

### Fixed

- Home / Library / Discover no longer flash an empty / "connect a source" state
  during pull-to-refresh or at launch — content persists through a refresh, and
  a loading state shows until data (or source discovery) lands.

## [0.5.8] — Unreleased · "Boötes"

Artwork bandwidth — phase 2 of the artwork review: per-call-site size tiers and
offline poster persistence.

### Added

- **Per-call-site artwork tiers.** A new `ArtworkSource` value type mints a
  server-resized URL at any `ArtworkTier` on demand (rather than baking one
  fixed size at fetch time), so each surface requests what it actually shows:
  the Detail hero pulls a 1920-px backdrop on tvOS / visionOS, episode rows a
  small 16:9 still, rails/grids a 400-px poster. `CachedAsyncImage` /
  `BackdropImage` take a `maxPixel` ceiling so a large hero isn't downsampled
  back down locally.
- **Offline poster persistence.** Downloads now save the poster to disk at
  enqueue time (`{jobID}.poster`); an offline card loads the local copy first,
  so artwork still renders when the server is unreachable or the token has
  expired. Cleaned up alongside the media file when a download is removed.

### Changed

- **Unified artwork is pinned to one source.** A unified title's poster/backdrop
  now resolves from the first source (in priority order) that carries artwork,
  so its image identity stays stable across source flips instead of changing
  (and re-downloading) when the active source changes. `MediaItem` and
  `UnifiedMediaItem` gained `posterURL(_:)` / `backdropURL(_:)` tier accessors
  that fall back to the baked default-tier URL.

## [0.5.7] — Unreleased · "Boötes"

Artwork bandwidth — server-side resized posters (phase 1 of the artwork review).

### Changed

- **Posters & backdrops are now resized by the server**, not downloaded at full
  resolution and shrunk locally. Plex uses its photo transcoder
  (`/photo/:/transcode?width=&height=&minSize=1&upscale=0`); Jellyfin uses
  `fillWidth`/`fillHeight`/`quality` + `format=Webp`. Rails/grids/cards request a
  ~400-px poster (was a multi-MB original); heroes request ~1200-px backdrops.
  Estimated ~20–60× less artwork bandwidth — a Home/Library load drops from
  tens/hundreds of MB to low single-digit MB. The local downsample stays as a
  safety net.
- The image cache key already retains the size/format params (and the Plex
  version token) while stripping only auth, so each tier caches independently and
  a rotated token no longer busts the cache (covered by new tests).

### Notes

- Phase 2 of the review (per-call-site size tiers, a `UnifiedArtwork` variants
  model to end source-flip re-downloads, offline poster persistence) is tracked
  for a follow-up — see the artwork optimization review.

## [0.5.6] — Unreleased · "Boötes"

Cinema screen-size presets — scaffolding (visionOS). The code path for
Medium / Large / IMAX / Wall is in place; each size's actual look + the literal
floor video reflection arrive when the per-size environments are authored in
Reality Composer Pro (the size + reflection live inside each `.usda`).

### Added

- **Screen-size preset machinery (visionOS).** A default-size picker in
  Settings → Cinema (persisted via `CinemaPreferencesStore`); the cinema opens
  the chosen preset's own immersive space and loads that preset's authored
  environment from the bundled Reality Composer Pro content, falling back to the
  procedural Dark Theater until the scene is authored. `CinemaScreenPreset` now
  carries a per-preset `sceneName` + `spaceID`.
- **Reality Composer Pro content** (`Packages/RealityKitContent`) — open it in
  Reality Composer Pro to author one environment per preset (`CinemaMedium`,
  `CinemaLarge`, `CinemaIMAX`, `CinemaWall`), each with a `DockingRegion` at that
  screen width and a `Reflection_Specular` floor. The `.rkassets` is bundled as
  an app resource (compiled at the app's deployment target, so it builds on
  tvOS too — it's never linked as a Swift package).

## [0.5.5] — Unreleased · "Boötes"

Enhanced Cinema (visionOS).

### Added

- **Enhanced Cinema environment (visionOS).** The Dark Theater is now a premium
  screening room instead of a placeholder: image-based lighting from a
  code-drawn dark-violet gradient (replacing the two bare point lights), a
  **glossy clearcoat floor** that pools the room + screen glow, an enclosing
  dark **skybox** for depth, restrained emissive **cove lighting** + a
  **screen-bloom** panel, and grounding shadows. Entering "dims the house
  lights" — the passthrough fades to dark — and immersion now defaults to
  **progressive** (the Digital Crown dials the real room back in, like Apple
  TV+ / Disney+). Still 100% procedural (no asset pipeline); the system continues
  to own video rendering, sizing, and native controls.
  - *Deferred (need authored Reality Composer Pro assets):* real
    Medium/Large/IMAX docking-size presets and a literal moving-video floor
    reflection — see `docs/next-steps/visionos-cinema.md`.

### Changed

- **CI now also compiles visionOS + tvOS** (build-only), so platform-gated code
  can't pass the iOS-only test job and then break the Xcode Cloud archive.

## [0.5.1] — Unreleased · "Boötes"

### Added

- **Build identifier in About.** Settings → About now shows the short git commit
  the build was cut from (e.g. "Version 0.5.1 (a1b2c3d)"), stamped into the
  Info.plist at build time — so local builds are distinguishable instead of all
  reading build "1" (only Xcode Cloud injects a real `CFBundleVersion`). A `+`
  suffix flags uncommitted changes.
- **"More Like This" on Detail.** Movie and show screens now show a rail of
  similar titles from the source's own recommendations (Plex related hubs,
  Jellyfin `/Similar`) — content discovery sits above the playback settings.
- **Redesigned Movie Detail.** Movies now open into a cinematic full-bleed
  backdrop hero on every platform, with the title, year • runtime • Movie, a
  **source badge** (PLEX / JELLYFIN / OFFLINE), capability badges (4K / HDR /
  Dolby Vision / codec / Atmos), a short overview and the play actions embedded
  over the artwork — content first. A **More** menu folds away the secondary
  actions (Mark Watched/Unwatched · Choose Source · Technical Details), and the
  Audio / Subtitles / Quality controls move *below* the hero. (TV shows keep
  their dedicated season-first layout.)
- **Series "Next Up" now follows where you are.** The Next Up card and the
  default-selected season land on the season you're actually mid-watch (the
  first with unwatched episodes), instead of always Season 1 — true On Deck.
  It stays put while you browse other seasons. Uses per-season unwatched counts
  from the server (Plex `viewedLeafCount`, Jellyfin `UnplayedItemCount`), so no
  episode-by-episode fetching.

### Fixed

- **Every season read "Season 1" (Plex).** The season selector took its number
  from the parent show's index instead of the season's own, so all seasons
  showed "Season 1". They now number correctly; Jellyfin seasons/episodes also
  carry their season & episode numbers (and series title) now.
- **iPhone — "Clear Image Cache" was missing.** The Cache card lived only in the
  Settings wide dashboard (iPad / tvOS / visionOS), so on iPhone — which renders
  a single column — it never appeared. It's now shown on iPhone too.
- **Detail screen trapped you across tab changes.** Opening a movie/show on one
  tab, switching tabs, and switching back left the Detail screen still showing —
  sometimes with no clear way back to the tab's root. Selecting any tab (Home /
  Library / Discover / Search) now returns it to its **root**, and re-tapping the
  active tab pops to root — the Apple TV / Netflix behaviour. Consistent across
  iOS, iPadOS, tvOS and visionOS.
- **tvOS — Settings right column was unreachable.** The "Clear Image Cache" row
  (and the rest of the right-hand dashboard) couldn't be focused, because the
  focus engine had no horizontally-aligned target to cross to. Each dashboard
  column is now a focus section, so a Right/Left press moves between them.
- **tvOS — Reload was stranded below search.** On Home and Library, Reload now
  sits to the **right** of a right-sized search field, so it's reachable with a
  single Right press from the field instead of being almost impossible to focus.

## [0.5.0] — Unreleased · "Boötes"

A dedicated TV-show experience and a clearer Home / Library / Discover split,
built on richer metadata plumbed end-to-end.

### Added

- **Home, Library & Discover, redefined** — each tab now has a distinct job:
  - **Home** is *watch now*: Continue Watching, **Recently Added**, **Recently
    Released**, and Downloaded. The full catalog no longer clutters it.
  - **Library** is your *collection*: Movies, TV Shows and Downloads with title
    **counts**, and a "See all" grid that now sorts by **Recently Added** and
    **Top Rated** (not just title/year) and filters by **genre**. Continue
    Watching / Recently Added moved to Home.
  - **Discover** gains a **Top Rated** rail and **per-genre** rails (your
    catalog's most common genres), alongside the existing hero + random picks.
- **Redesigned Series Detail** — TV shows now get a purpose-built layout instead
  of the movie screen:
  - **Next Up** card — the first unwatched episode of the selected season, with a
    "Resume from m:ss" caption when there's a saved position.
  - **Inline season selector** — capsule chips switch seasons in place; the
    episode list updates without navigating into a season.
  - **Inline episodes** — the selected season's episodes (thumbnail, title,
    runtime, synopsis, watched check) right on the show screen.
  - **Series metadata line** — "2011–Present • 8 Seasons • 73 Episodes • Series"
    (run span + counts) instead of a single runtime. The "–Present" only shows
    when the source confirms the series is still airing (Jellyfin `Status`); Plex,
    which doesn't report status, shows just the start year.
  - **Details** section — genres, rating, first-aired, and status.
  - Movies keep the cinematic hero-background layout and their runtime metadata.
- **Rich metadata plumbing** — `MediaItem` now carries `genres`,
  `communityRating`, `releaseDate`, `dateAdded`, `seasonCount`, `episodeCount`,
  `endYear` and `isContinuing`, populated from both connectors:
  - **Plex** — requests/maps `Genre`, `audienceRating`/`rating`,
    `originallyAvailableAt`, `addedAt`, `childCount` (seasons) and `leafCount`
    (episodes).
  - **Jellyfin** — requests/maps `Genres`, `CommunityRating`, `PremiereDate`,
    `DateCreated`, `ChildCount` (seasons), `RecursiveItemCount` (episodes) and
    `Status`/`EndDate` (so an ended series shows its final year, a continuing
    one reads as "Present").

## [0.4.4] — Unreleased · "Andromeda"

### Added

- **Responsive Movie Detail** — wide layouts (tvOS, iPad/iPhone landscape, wide
  visionOS windows) now use an Apple-TV / Infuse-style **hero-background**: the
  backdrop fills the background behind a dark scrim, with title, year • runtime •
  type, technical badges, primary actions, overview and playback rows in a
  readable left column — all visible without scrolling. iPhone portrait keeps the
  vertical layout. Runtime ("1h 59m") shows in the metadata everywhere.
- **Bounded artwork disk cache** — the on-disk image cache now has a 256 MB cap
  with **LRU eviction** (least-recently-used posters dropped first; modification
  date touched on read), trimmed on launch + periodically. It can no longer grow
  without bound (it previously relied only on the OS purging `Caches/`).
- **Clear Image Cache** — a Settings → Cache row showing the current on-disk
  size, clearing memory + disk on tap.

## [0.4.3] — Unreleased · "Andromeda"

Performance + control: artwork loads fast again and you can pull to refresh.

### Added

- **Artwork caching pipeline** — `AetherImageCache`: a real two-tier
  (memory + disk) cache with on-disk persistence, in-flight de-duplication
  (one download per poster even across rails), and ImageIO downsampling.
  Posters now appear instantly from cache, relaunch doesn't re-download, and
  scrolling is smooth. Replaces the placeholder `CachedAsyncImage` that was just
  raw `AsyncImage` (no cache).
- **Pull-to-refresh** on Home, Library, and Discover — re-fetches and re-runs
  the unified aggregation without clearing the (still valid) artwork cache.

### Changed

- **Faster Home/Library first paint** — the unified aggregation now fans out
  across sources/libraries in parallel instead of sequentially.

## [0.4.2] — "Andromeda"

### Added

- **Tab pop-to-root** — re-selecting the active tab resets its navigation stack
  to the root, so tapping Home / Library / Discover / Search while drilled in
  returns to the top.
- **Manual Mark as Watched / Unwatched** on Detail — writes the play state back
  to Plex (scrobble) / Jellyfin (PlayedItems).
- **Skip Intro / Skip Credits** — server-marker-driven (Plex markers, Jellyfin
  MediaSegments); Show Button / Automatically / Off.
- **Auto-Play Next Episode** — next-episode resolution + an "Up Next" countdown
  in the credits, with a configurable length.
- **Watched checkmarks** sourced from the server's own play state.

## [0.4.1] — Unreleased · "Andromeda"

The Unified Library era: the *source* becomes an implementation detail across
every browse surface, the spatial Cinema lands on Vision Pro, navigation is
reworked into Home · Library · Discover · Search · Settings with a dashboard-
style Settings, and a round of tvOS focus/navigation fixes.

### Added

- **Vision Pro Cinema (V1)** — a "Dark Theater" immersive space; the native
  `AVPlayerViewController` docks into it via a single-source-of-truth
  `CinemaManager`. visionOS-only.
- **Unified Library** — Home, Search, **Discover**, and **Library** all
  aggregate every connected source into deduplicated `UnifiedMediaItem`s
  (dedup by shared TMDB / IMDB / TVDB ids; offline downloads surface as a
  source). Source priority offline → plex → jellyfin → emby.
- **Available Sources on Detail** — a title that exists on more than one source
  shows them all; tap to switch which source plays / hydrates in place.
- **Discover + Search as first-class tabs** on every platform (Discover was
  tvOS-only; Search was an inline field).
- **Settings dashboard** — split two-column layout on iPad / tvOS / visionOS
  (controls + Connected Sources / Storage Summary cards with source health);
  single column on iPhone. **What's New** modal on the version row.
- **`UnifiedLibraryGridView`** — full "See all" grid per kind with client-side
  sort (Title A–Z / Z–A, Year newest / oldest) and a prominent focusable
  "See all" rail tile.
- **Jellyfin offline downloads** — `supportsDownloads` + download URLs (parity
  with Plex).

### Changed

- **Storage tab removed** — the download manager now lives at
  **Settings → Downloads** (downloads are an offline *source*, not a separate
  area). Final tab set: Home · Library · Discover · Search · Settings.
- **Search keyboard dismissal** — tap-outside / scroll / select-result /
  Search-Done all dismiss the keyboard (`@FocusState`).
- **Show detail** uses a shorter backdrop so the seasons rail is on-screen and
  reachable; overview clamped on shows.

### Fixed

- visionOS archive failure — `scrollDismissesKeyboard` is iOS-only and must not
  be gated for visionOS.
- tvOS focus traps on the show detail — seasons rail is a focus section (Up
  escapes to the tab bar); the keyboard tap-gesture no longer runs on tvOS
  (it intercepted Select and corrupted the focus engine).

## [0.4.0] — 2026-06-04

Premium polish pass on the 0.3.x foundation. Settings is now a true
preferences panel (not a capability brochure), playback defaults
follow the user across every title, the brand mark anchors a
centred header on Home and Library, and **Apple TV gets a dedicated
Discover tab** in place of the Storage tab that didn't belong there.

### Added

- **`PlaybackPreferencesStore`** — app-wide defaults for Quality,
  Audio Language, and Subtitle Language. `@Observable`, UserDefaults
  persisted, plumbed through `AppSession` and consumed by
  `DetailView.hydrateForPlayback` to pre-select matching tracks at
  every open. "Source default" / "Off" sentinels for the language
  preferences; the user's per-title picker tap still wins for that
  session — defaults are the seed, not a lock.
- **`AppearancePreferenceStore`** — System / Dark / Light picker
  surfaced in Settings under a new Appearance section. Applied at
  the app root via `.preferredColorScheme(_:)`. The previous
  hard-coded `.dark` is gone. Full Light visuals follow when the
  Palette migration completes; the picker is wired today.
- **Adaptive Palette tokens** — Light-mode foundation: `background`,
  `surface`, `surfaceElevated`, `separator`, `textPrimary`,
  `textSecondary`, `textTertiary` all carry per-mode variants via
  the new `Color(light:dark:)` helper. Accent colours (violet,
  indigo, aurora, gold) and semantic statuses (success, warning,
  error) stay single-value — brand identity / semantic meaning is
  the same in either appearance.
- **`AetherSearchField`** — shared inline search capsule with
  magnifying-glass icon, placeholder, and clear button. Lives in
  `AetherCore/DesignSystem`. Replaces the system `.searchable`
  modifier on Home and Library so the brand mark gets the top of
  the screen back.
- **Discover tab (tvOS)** — replaces the Storage tab on Apple TV.
  Three rails: a single random **hero pick** (16:9 backdrop),
  **Random Picks** (12 shuffled titles cross-library), and
  **Recently Added** (round-robin interleave of each library's
  newest). New `DiscoverFeed` model + `DiscoverFeedBuilder` reuse
  the existing `MediaSource` APIs — no new endpoints. Picks
  re-shuffle per build, cache per session.
- **`PlaybackLanguage`** — curated shortlist of 15 BCP-47 codes
  exposed in the language pickers, plus a `displayName(for:)`
  fallback that uppercases an unknown code instead of rendering
  blank.
- **About → What's New** — the About section now compacts the
  Version + Build pair into one tappable row; tapping expands a
  cumulative bullet list of shipped highlights. On tvOS the
  expand pattern flips to a **side-by-side** layout (version
  left, bullets always-on right) because vertical scroll-off
  hides expanded disclosure content on the leanback surface.

### Changed

- **Settings header** — centred `AetherWordmark(.large)` replaces
  the leading-padded wordmark + "Settings" page title + "Manage
  your media sources and playback." subtitle. The tab bar already
  says where the user is; Settings opens straight into content.
- **Settings Playback section is now actual preferences**. The
  old capability badges (Direct Play available / Transcoding
  coming soon / Offline Downloads coming soon) are gone — those
  were product facts, not configurable choices, and "Offline
  Downloads coming soon" was lying since 0.3.0. The section now
  holds three `AetherDisclosureRow` pickers driven by
  `PlaybackPreferencesStore`.
- **Home rail order — Continue Watching first**. Active content
  takes priority over discovery — same pattern Apple TV, Netflix,
  Disney+ use. Sequence is now `CW → Featured → libraries`.
- **`Gradients.background`** — single linear 12 % violet wash from
  the top is replaced with a near-black base + two faint cosmic
  blooms (cool aurora upper-left, warm violet upper-right) at
  3–5 % opacity. Adaptive: bloom opacity halves on Light so the
  accent tints don't read as marketing material on white.
  Inspired by Apple TV+, Disney+, and visionOS backdrops.
- **`AetherBrandMark.imageset`** ships at all three scales (1×, 2×,
  3×) instead of `@3x`-only. tvOS doesn't have `@3x` displays, so
  the previous configuration left the brand mark unresolved on
  Apple TV.

### Removed

- **"Your media, beautifully organized." tagline** — duplicated
  identity the new brand artwork already carries; was burning
  vertical space on every Home / Library load. Removed from
  HomeView heroHeader, LibraryBrowseView heroHeader, and the
  no-source Welcome state (trimmed to the actionable "Connect a
  Plex or Synology source to begin.").
- **Library "Library" subtitle** — disambiguation that the tab
  bar already provides.
- **`.searchable` modifier** on Home and Library — replaced with
  the inline `AetherSearchField` so the brand mark can sit above
  the search field instead of below it.

## [0.3.2] — 2026-06-04

Brand identity refresh and the in-app polish that came with it.

### Added

- **New brand artwork.** Three designer-supplied PNGs replace the
  previous icon set: a square symbol-only mark for iOS / iPadOS /
  visionOS (`AppIcon.appiconset`), a wide symbol + AETHER wordmark
  for tvOS (Home Screen imagestack, App Store imagestack, Top Shelf
  + Top Shelf Wide at all required sizes), and a transparent
  icon + AETHER lockup for in-app use (`AetherBrandMark`). Alpha is
  preserved on the in-app mark so it sits on whatever surface hosts
  it; stripped from every App Icon asset per Apple's validator
  rules. visionOS `Front` / `Middle` layers, previously 4 kB
  placeholders, now carry the full artwork.
- **`AetherSearchField`** — new `AetherCore/DesignSystem` component.
  A regular SwiftUI capsule (magnifying-glass icon, placeholder,
  clear button) that can sit anywhere in a layout, unlike
  `.searchable` which forces the system search bar to the top of
  the screen. Used on Home and Library beneath the centred brand
  mark; the bound `@State searchQuery` still drives the existing
  `isSearching` swap to `MediaSearchResults`, so the search code
  path is unchanged.

### Changed

- **Brand mark is now image-backed, not code-composed.**
  `AetherWordmark` previously composed the icon and the wordmark in
  SwiftUI (`Image` + `Text` with a per-letter gradient on the
  leading "A"). The new artwork bakes that lockup into a single PNG,
  so the view just renders the asset at the variant height (22 /
  36 / 60 pt; width follows the artwork's ~3:1 aspect after the
  vertical padding crop). Tagline now stacks beneath the lockup
  instead of next to it.
- **Centred lockup above search on Home + Library.** `.searchable`
  is gone from both screens — it forced the search bar to the very
  top, which fought the brief that the Aether wordmark is the first
  thing the user sees in the app. The branded header (centred
  wordmark + `AetherSearchField` beneath) is shown only on the rails
  and during search; loading / error / welcome / empty states keep
  their own full-screen layouts to avoid duplicating the brand mark
  (the Welcome surface already renders one).
- **Tagline lines removed.** "Your media, beautifully organized."
  was burning vertical space on every Home + Library load and
  duplicating identity the artwork now carries. Removed from
  `HomeView.heroHeader`, `LibraryBrowseView.heroHeader`, and the
  no-source Welcome state (left with the actionable
  "Connect a Plex or Synology source to begin."). Settings keeps
  its own page-specific subtitle ("Manage your media sources and
  playback.") — that one is functional, not promotional.
- **Library "Library" subtitle dropped.** The centred wordmark
  replaces it; the tab bar already says where the user is.
- **Settings wordmark bumped `.medium` → `.large`.** Matches Home
  and Library so the brand reads at the same weight across every
  top-level tab.
- **Resume + Restart side-by-side on `DetailView`.** The two
  playback CTAs (Resume / Play From Beginning) used to stack
  vertically. Now they sit on one row, each `.frame(maxWidth: .infinity)`
  so they split the width evenly. "Play From Beginning" renamed to
  **Restart** — same name Apple's TV app uses for the same action,
  short enough to fit alongside Resume on iPhone. The icon
  (`backward.end.fill`) carries the rest of the meaning. The
  "Resume from 1:23" caption stays beneath the row, leading-aligned,
  pairing visually with Resume on the left.

## [0.3.1] — 2026-06-04

Download management hardening on top of 0.3.0, plus a tvOS build
fix that unblocked Xcode Cloud.

### Added

- **Swipe-left to delete** any download row — in-progress or
  completed — on iOS / visionOS. tvOS gets an explicit trash
  button instead (`swipeActions` is unavailable there).
  `DownloadManager.remove()` cleans up partial + resume-data files,
  not just the finished file.
- **Rich progress detail** on Storage rows: "1.2 of 3.4 GB · 12 MB/s
  · 4 min left" plus a progress bar. Live byte / speed values are a
  new transient `DownloadLiveProgress` on `DownloadSnapshot` —
  never persisted, so existing `downloads.json` decodes unchanged
  across the upgrade (no history wipe).
- **Resume after relaunch.** Resume data persists to disk
  (`{jobID}.resumedata`), so URLSession's resume blob survives the
  process exit; `DownloadJob.sourceURL` carries a restart-from-URL
  fallback for when resume data isn't available. Auto-resume fires
  once per launch.

### Fixed

- **Pause now actually pauses.** URLSession's buffered
  `didWriteData` events arriving while `pause()` was suspended
  waiting for `cancel(byProducingResumeData:)` overwrote the
  just-set `.paused` state back to `.downloading`. The actor's
  event handler now drops progress events for jobs it no longer
  owns (`guard tasksByJobID[jobID] != nil`) — pause / cancel /
  remove all clear that entry first.
- **No more progress flicker.** URLSession ticks ~10 ×/sec on a
  fast connection, which the Storage row re-rendered 10 ×/sec —
  speed, bytes, ETA flashed unreadably. The store now emits at most
  every 1.5 s per job; the speed EMA still samples on every tick so
  the displayed value stays accurate.
- **tvOS build.** Xcode Cloud's tvOS lane was failing on
  `'listRowSeparator(_:edges:)' is unavailable in tvOS`. Rather than
  re-skin the Storage screen for a fourth platform, downloads are
  dropped from tvOS entirely — Apple TV is a "lean back" surface
  with a persistent network, no swipe gesture for managing rows,
  and shared system storage users can't act on. `RootTabView`
  returns `nil` for `downloadManager` / `downloads` on tvOS so
  every download surface gates itself out via existing nil-checks;
  the Storage tab and `StorageView.swift` are `#if !os(tvOS)` gated.

## [0.3.0] — 2026-06-03

Phase 2 — offline downloads and a top-level Storage manager. Aether
becomes useful on the plane.

### Added

- **Offline downloads — start to finish.** A new Download button on
  movie / episode Detail kicks off a background `URLSession` job
  through the new `DownloadManager` actor (`AetherCore/Downloads/`),
  with a quality picker that re-uses the same eight-step
  `PlaybackQuality` ladder Detail's Playback section uses. The pipeline
  has six runtime pieces: `DownloadStatus` enum (queued /
  downloading(fraction) / paused / completed / failed / expired),
  `DownloadJob` (uuid + mediaID + snapshot of title / poster / series
  context / quality / createdAt), `DownloadStore` (actor-isolated
  Codable JSON file in Application Support), `DownloadManager` (single
  `URLSession.background` instance, one per app process), a
  `URLSessionDownloadDelegate` bridge class, and `DownloadObserver`
  (`@MainActor` `@Observable` mirror SwiftUI views read synchronously).
  Background URL session events get released via a singleton
  `BackgroundDownloadCompletions` + a minimal `UIApplicationDelegate`
  adapter on `AetherApp`. Tasks already in flight from a previous
  launch are re-bound on startup via `taskDescription = jobID`.
- **Storage tab — top-level download manager.** Replaces the Search
  tab in the bottom bar (`Home · Library · Storage · Settings`).
  Surfaces total downloaded bytes, device free space, per-source
  breakdown (Plex / Jellyfin, ready for Local / Synology), an
  **In Progress** section with state-specific actions (Pause / Resume
  / Cancel / Retry), a **Downloaded** section with per-item Delete,
  and a destructive Clear All. Tapping a row pushes the same
  `DetailView` the rest of the app uses — the offline-playback
  override in `PlaybackSession` then plays from the local file.
- **Library "Downloaded" rail.** Cross-source completed downloads as
  a horizontal rail on the Library tab. Posters fall back to the
  job's captured snapshot so the rail still renders offline.
- **Episode context end-to-end.** `MediaItem` gets `seriesTitle` /
  `seasonNumber` / `episodeNumber` populated from Plex's
  `grandparentTitle` / `parentIndex` / `index`. The new
  `displayTitle` computed property renders
  `"Breaking Bad · S1E1 · Pilot"` for episodes and falls back to
  `title` for movies. `DownloadJob` snapshots the same fields at
  enqueue time so the Storage row stays informative even when the
  source is unreachable.
- **Search lives in Home + Library tabs.** Both gain a
  `.searchable(text:)` modifier; the rails / hub swap for a shared
  `MediaSearchResults` view when the user types. Same client-side
  title filter the old Search tab ran, lifted out as a reusable view.
- **Playback quality picker — Plex Web's eight-step ladder.** A new section on
  Detail lets the user pick the playback quality before pressing Play, mirroring
  Plex Web exactly: **Original** (Direct Play priority — preserves the source
  codec via container remux when possible), **Convert Automatically** (server
  decides), and six bitrate caps (20 / 12 / 8 Mbps 1080p, 4 / 2 Mbps 720p,
  720 kbps). The choice rides on the new decision pipeline (see *Fixed*) as
  `maxVideoBitrate` / `videoResolution` query items, and the projected playback
  mode — *Original · Direct Play* / *Original · Direct Stream* / *Transcode* —
  surfaces inline next to the chosen quality so the user knows what's about to
  happen before they tap. New `PlaybackQuality` enum + `PlaybackDecisionMode`
  + `MediaInfo` types in `AetherCore/MediaSources/MediaSource`.
- **Aether wordmark + brand mark — a reusable identity component.** New
  `AetherWordmark` SwiftUI view (app target) combines the app-icon glyph with
  the "Aether" wordmark — SF Pro Display Semibold, white text, only the leading
  "A" wears the violet → aurora gradient (Apple-restrained, not a startup
  logo). Three variants (`.small` / `.medium` / `.large`) and an optional
  `tagline:` parameter for the landing-page block (`[logo] Aether / tagline`).
  Brand artwork ships as a separate `AetherBrandMark` imageset alongside the
  AppIcon set so `Image("AetherBrandMark")` resolves cleanly without touching
  app-icon assets. Used at the top of Home (signed-in *and* welcome),
  Library, Settings, and the Plex / Jellyfin sign-in / discovery sheets — the
  brand reads inside the app, not only on the home-screen icon.
- **`AetherDisclosureRow` — the row family's third member.** New atomic next to
  `AetherSettingsRow` / `AetherSelectionRow`: label + current value + chevron,
  tap-to-open. The iOS-native "current choice with more behind a tap" pattern
  from Settings.app and Plex Web's bottom-sheet pickers. Powers the new
  compact Audio / Subtitles / Quality rows on Detail (see *Changed*).
- **Warm gold accent — the cinematic partner to violet.** New
  `Palette.accentGold` (`#F5B524`) and `accentAmber` (`#F59E0B`) extracted from
  the app icon's neon "A" mark, plus `Gradients.cinematic` (violet → aurora →
  gold) used sparingly on hero glyphs. Violet stays the primary tint; gold is a
  *secondary* accent, never for selection or focus.

- **Jellyfin — a second media source.** Aether is no longer Plex-only. Connect a
  Jellyfin server by typing its URL and approving a **Quick Connect** code
  (ideal for the Apple TV remote — no password typing). New connector in
  `AetherCore/MediaSources/Jellyfin/` mirrors the Plex stack: `JellyfinConfiguration`
  (the `MediaBrowser` Authorization header), `JellyfinAuthClient` (validate
  server → Quick Connect initiate/poll/authenticate), `JellyfinAPI` DTOs,
  `JellyfinServerStore`/`Record`, and `JellyfinMediaSource` (libraries, items,
  seasons/episodes, hydrate, and `resolvePlayback` — direct-play for friendly
  containers, HLS transcode with a fresh `PlaySessionId`, audio/subtitle stream
  indexes + `startTimeTicks` offset). Images + media URLs carry the token as
  `api_key` (AVPlayer/AsyncImage can't set headers), exactly like Plex
  tokenises its URLs. Audio + subtitle track selection on Detail and the
  `-1008`-safe playback resolver work for Jellyfin unchanged — they were built
  on the source-agnostic `MediaSource` / `PlaybackRequest` abstraction.
- **Single active source, switchable.** You can connect both Plex and Jellyfin;
  exactly one is active at a time (Home / Library / Search render it), chosen in
  **Settings → Sources** and remembered across launches. Sign out of one and the
  app falls back to the other or to the welcome state. (`AppSession` gained the
  parallel Jellyfin lifecycle + an `activeSourceKind`.)

- **Aether visual identity — the violet "personal cinema" brand.** Aether's
  first real visual identity, replacing the grayscale developer look. A reusable
  brand token system in `DesignSystem/Tokens`: `AetherDesign.Palette` (Aether
  Violet `#8B5CF6` primary, Indigo `#6366F1`, Aurora `#A855F7`; near-black
  `#09090B` background, zinc surfaces, `#FAFAFA`/`#A1A1AA`/`#71717A` text, and
  semantic success/warning/error), authored from hex via a new `Color(hex:)`;
  `AetherDesign.Gradients` (`aurora` hero sweep, `progress`, `background` wash,
  `heroBloom`); and `AetherDesign.Materials` (translucent `card` / `chrome`).
  Applied across the app: the primary button + Continue Watching progress wear
  the aurora gradient, settings/source cards become frosted translucent material
  over a faint violet-washed background, the Welcome hero gets a radial violet
  bloom, and focus states everywhere (cards, buttons, rows, library tiles) use a
  soft **violet glow** + scale instead of flat black shadows or white borders.
  Status values are colour-coded from the semantic palette. tvOS tab selection
  and system controls pick up the violet tint automatically.

### Fixed

- **Plex downloads off-LAN — re-probe the connection list per request.** A
  Plex base URL cached from when the user was on LAN went stale when they
  walked out of Wi-Fi range, and downloads then aimed `URLSession.background`
  at a dead `192.168.x.x` host. `PlexMediaSource.downloadURL(for:quality:)`
  now invalidates the cached connection before resolving, so the ranked
  candidate list is re-evaluated and a reachable remote / relay endpoint
  picks up the work.
- **Plex Original-quality downloads — HTTP 400 from the remote transcoder
  endpoint.** Plex's `/video/:/transcode/universal/start?protocol=http`
  refuses the request shape over the remote connection (the LAN's local
  transcoder allows it, but remote requests need a different path). Mirrored
  Plex Web's download behaviour: for `.original` quality the request now
  hits the raw Part file URL (`/library/parts/{partId}/{ts}/{filename}?
  download=1`) — no transcoder involvement, single GET, works through
  remote. Bitrate-capped qualities still flow through the transcode
  endpoint (the server has to re-encode, no shortcut).
- **Downloads "couldn't move temp file" race.** The bridge yielded the
  URLSession temp URL into an `AsyncStream` and the actor handler moved
  the file from there — by then iOS had already deleted the temp file
  from the system daemon's container. Moved the
  `FileManager.moveItem(at:to:)` inside the
  `didFinishDownloadingTo` delegate callback itself, before the bridge
  yields, so we stay inside URLSession's guaranteed window.
- **Wrong file extension on downloads — `AVPlayer "Cannot Open"`
  `-11829`.** Downloads were saved as `{jobID}.mp4` regardless of the
  actual container. AVPlayer reads the path extension before sniffing
  bytes, so an MKV at `.mp4` failed with
  `AVErrorCodeFileFormatNotRecognized`. Extension now derives from
  `URLResponse.suggestedFilename` (URLSession parses the server's
  `Content-Disposition: attachment; filename="…ext"` header) →
  download URL path extension → `.mp4` fallback.
- **Pause immediately Failed.** `task.cancel(byProducingResumeData:)`
  triggers `didCompleteWithError(NSURLErrorCancelled)`; the
  `.failed` event then overwrote the `.paused` state set by the same
  public method. A new `expectedCancellations: Set<UUID>` on the
  actor records ids we're about to cancel ourselves, and the
  `.failed` handler drops events for those ids.
- **Non-2xx download responses landing as "Completed."** URLSession
  fires `didFinishDownloadingTo` even for HTTP 4xx/5xx — the
  response body becomes the "downloaded" file (a user saw an 89-byte
  `.mp4` reported as completed). The bridge now reads
  `(downloadTask.response as? HTTPURLResponse)?.statusCode` and
  yields `.failed(DownloadHTTPError(statusCode:))` for non-2xx; the
  Failed row shows `"HTTP 401 — server rejected the request (auth)"`
  or similar.
- **Local playback of unsupported containers.** A downloaded MKV
  whose codecs iOS can't decode (HEVC 10-bit + DV, DTS, TrueHD, …)
  failed with `AVFoundationErrorDomain -11828` even though it would
  stream fine via Plex's HLS transcode. `PlaybackSession`'s offline
  branch now runs `AVURLAsset.load(.isPlayable)` before committing to
  the local file URL; on failure the resolver falls through to the
  source layer, so playback transparently switches to streaming
  without an error screen.
- **Detail's first sheet tap rendered empty.** `.sheet(item:)`'s
  content builder discarded the closure parameter and re-read the
  `@State` value inside the body — on first presentation the state
  hadn't propagated yet and the switch fell through to `EmptyView`.
  Sheet body now takes the non-optional selector as a parameter so
  the value is the snapshot at presentation time.

- **Plex audio-switch unreliability + pause/resume `400` — by mirroring Plex
  Web's PUT-then-decide flow.** Audio-switching often kept playing the original
  track; pausing and resuming a minute later sometimes failed with HTTP 400 +
  `EXTM3U=false`. Root cause: Aether was jamming `audioStreamID` /
  `subtitleStreamID` onto the `start.m3u8` URL and hoping the server honoured
  it, while Plex's canonical state for a track selection lives on the **Part**
  itself. The resolver now matches Plex Web exactly: **(1)** `PUT
  /library/parts/{partId}?audioStreamID=…&subtitleStreamID=…` so the chosen
  streams become the Part's selection (the new `applyStreamSelection` step,
  using `Part.id` which is now decoded — previously discarded); **(2)** `GET
  /video/:/transcode/universal/decision` with the user's quality / stream / off
  set ask, reading back `Part.decision` (`directplay` / `copy` / `transcode`)
  and the post-decision codecs / bitrate / resolution (the new `fetchDecision`
  step + `PlexAPI.DecisionResponse` model); **(3)** build the playback URL from
  the verdict — a direct file URL for *directplay*, a `start.m3u8` URL with
  the same session id for *directstream* / *transcode*. The whole pipeline is
  fronted by structured `os.Logger` diagnostics (`subsystem
  cz.zmrhal.aether`, category `plex.playback`) that log quality / decision
  mode / verdict / codecs / warm-up status — token-free, debuggable from
  Console.app. Three new public types in `MediaSource.swift`
  (`PlaybackQuality`, `PlaybackDecisionMode`, `MediaInfo`); `PlaybackRequest`
  gains `partID` + `quality`; `ResolvedPlayback` gains `decision`. Selection
  on `MediaItem` becomes pure state — the URL-mutation helpers
  (`startingPlayback(at:)`, `replacingQueryItem(name:value:)`,
  `regeneratingPlexTranscodeSession()`) are gone, and the in-player audio /
  subtitle switching paths on `PlaybackSession` /
  `PlayerStateViewModel` are removed (the player is no longer responsible for
  configuring streams; Detail is).
- **Quality = Original HTTP 400 (the Tron: Ares incident).** Even with the
  PUT-then-decide pipeline live, the *Original* quality path failed with HTTP
  400 from the decision endpoint while *Convert Automatically* worked fine.
  Cause: my decision call sent `directPlay=1` for Original, expecting Plex to
  evaluate "may we direct play?" — but without `X-Plex-Client-Profile-Extra`
  (the detailed codec / container profile Plex Web sends) Plex returns 400
  instead of just "no directplay possible." The decision call now always sends
  `directPlay=0` regardless of quality; the "preserve original quality" intent
  is carried by `directStream=1` (lossless container remux when codecs match)
  plus the absence of a bitrate / resolution cap. Direct play for
  client-friendly containers (mp4 / mov / m4v) was already handled separately
  by `streamURL(for:)` mapping and stays unaffected. `start.m3u8` also pinned
  to `directPlay=0` so a future decision-endpoint shift can't reintroduce a
  contradictory transcode request. New regression test
  (`transcodeStartURLParams`) iterates **every** `PlaybackQuality` case and
  asserts `directPlay=0` on `start.m3u8` so the bug can't sneak back.
- **Jellyfin connectivity over plain HTTP — App Transport Security relaxed.**
  Connecting to a Jellyfin server at `http://your-server:8096` failed with
  `NSURLErrorDomain -1022` because iOS ATS blocks plain HTTP. Self-hosted media
  servers (Jellyfin, Emby, Synology DSM, generic NAS) typically don't ship
  with a valid TLS cert, and the user's hostname (DDNS, Tailscale Magic DNS,
  custom domain) defeats `NSAllowsLocalNetworking` even when it resolves to a
  private IP. The Info.plist now sets `NSAppTransportSecurity /
  NSAllowsArbitraryLoads = true` — the same pattern Infuse, VLC, and the
  official Jellyfin client use; Apple accepts the justification for
  personal-media clients at review time. Plex is unaffected — it already
  worked via `*.plex.direct` TLS.

- **Plex transcode HLS warm-up — the rest of the `-1008` story.** Even with a
  fresh session per playback, AVPlayer could still open the `start.m3u8` URL
  before Plex had produced a readable playlist, so audio-switch / resume could
  fail with `NSURLErrorDomain -1008` and only succeed if you waited and retried.
  The resolver now **warms up** the stream before returning: a new
  `PlexTranscodeSessionManager` fetches the master playlist with short
  exponential backoff (immediate, 250 ms, 500 ms, 1 s, 2 s) and only hands the
  URL to the player once it's HTTP 200 + `#EXTM3U`. Plus: small resume offsets
  (≤ 12 s) are no longer sent to the transcoder (the first segment may not
  exist) — playback starts at zero and seeks client-side; transcode sessions are
  explicitly **stopped** on close and after a track switch (old session stopped
  only once the new one is live); local connections send `location=lan`; and a
  failed warm-up shows a calm "Unable to prepare playback" Retry/Close state with
  token-free diagnostics behind *Details*. (The `ResolvedPlayback` contract is
  source-agnostic, so Jellyfin's HLS can adopt the same warm-up next.)
- **Playback `-1008` on audio switch and resume-after-a-delay.** Transcode
  playback URLs were built once (with a `session` id minted at fetch time) and
  then string-mutated / replayed — so a Plex transcode session reaped
  server-side after inactivity resurfaced as `NSURLErrorDomain -1008`
  ("resource unavailable") on resume, and audio switching reused fragile
  hand-rewritten URLs. Playback URL construction now lives entirely in the
  source layer behind a `PlaybackRequest` → `MediaSource.resolvePlayback(_:)`
  resolver: `PlaybackSession` asks for a **fresh** URL (new transcode session,
  current connection + token, requested audio/subtitle streams, baked-in
  offset) every time playback context changes — initial play, audio/subtitle
  switch, and resume. The player no longer owns any Plex URL mutation. Audio
  switching captures and restores the current position; a resolve failure
  surfaces the controlled Retry/Close state instead of a black screen. The
  player's failure message is now calm (no raw host / `NSURLErrorDomain`); the
  technical detail sits behind a **Details** disclosure.

### Changed

- **Tab bar reshuffle — `Home · Library · Storage · Settings`.** Search
  moves out of the tab bar and into a `.searchable` modifier on both
  Home and Library (iOS-native "search lives in the tab that owns the
  content" pattern). The freed slot goes to the new Storage tab.
- **Playback layer attaches the downloads catalogue.** `PlaybackSession`
  gains `attachDownloadStore(_:)`, wired by `AppSession.start()` after
  the manager + observer come up. `prepare(item:source:startAt:)`
  checks the store before the source layer — completed downloads play
  from disk with no transcode session, no warm-up, no network call.
- **`MediaSource.supportsDownloads`** capability flag — synchronous so
  Detail's Download button visibility decides at render time without
  an actor hop. Plex returns `true`; the protocol default is `false`.

- **Detail playback options collapse into compact rows + bottom sheet.** The
  Detail screen no longer scrolls through four expanded settings groups —
  Audio / Subtitles / Quality each collapse into a single `AetherDisclosureRow`
  under one **Playback** section, showing the current selection in muted text.
  Tap opens a half-height bottom sheet (`presentationDetents([.medium,
  .large])`) that reuses `AetherSelectionRow` for the option list. The
  *Media* block stays expanded as read-only source info (Video / Audio /
  Bitrate / HDR / Playback mode / Source). The in-player audio / subtitle
  pickers are gone — selection is *Detail's* responsibility, the player just
  plays what was configured.
- **Library tab — branded hub instead of two empty tiles.** The Library tab no
  longer opens to oversized Movies / TV Shows category tiles. New layout: a
  large `AetherWordmark` hero ("Aether Library" + tagline), a Continue Watching
  rail (cross-library), a Recently Added rail (round-robin merge across
  libraries, capped at 12), and a section per library — `"Movies (1,234)"`
  inline count + horizontal poster rail (top 12) + a `See all` link that
  pushes the existing `LibraryView` grid for deep browse. Reuses
  `HomeFeedBuilder` so no new endpoints land.
- **Home opens with the brand, not just artwork.** The signed-in Home now
  carries an `AetherWordmark(.large, tagline: "Your media, beautifully
  organized.")` hero above the rails — Home reads as Aether's product
  landing page rather than a generic rail browser. The Welcome (signed-out)
  hero swaps `play.circle` for the same wordmark to keep the identity
  consistent.
- **Settings reorganised + "Coming soon" → "Planned".** The Settings header
  pairs the `AetherWordmark(.medium)` with a calmer tagline ("Manage your
  media sources and playback.") — the inline version reference moved out;
  version still lives in the **About** section row. `AetherStatus.comingSoon`
  text changed from `"Coming soon"` to `"Planned"` — propagates to Synology,
  Direct Play, Transcoding, and Offline Downloads rows in one step.
- **Plex onboarding sheets carry the wordmark too.** Plex / Jellyfin sign-in
  and Plex discovery sheets now show a small `AetherWordmark(.small)` above
  the existing title — the user keeps a thread to Aether's identity even
  while staring at Plex / Jellyfin instructions.
- **`MediaItem.selectingAudioTrack` / `selectingSubtitleTrack` are now
  state-only.** Previously these returned a new `MediaItem` with a mutated
  `streamURL` (audio id baked into the query string + regenerated transcode
  session). Now they only update `selectedAudioTrackID` /
  `selectedSubtitleTrackID`; the source's `resolvePlayback` builds the URL
  fresh from these IDs every time Play is pressed. The URL-mutation
  helpers (`replacingQueryItem`, `regeneratingPlexTranscodeSession`,
  `startingPlayback(at:)`) are removed from `MediaItem`.

- **tvOS 26 redesign — native top navigation, cinematic Home, calmer player.**
  A UX/product pass to make Aether feel native on tvOS 26 (and ready for a
  Vision Pro TestFlight) rather than "an iPad app on Apple TV." No new backend.
  - **Navigation.** The single surface-switching `HomeView` (tvOS top-capsule /
    iOS bottom dock) is replaced by a native SwiftUI `TabView` (`RootTabView`)
    that renders as the tvOS top tab bar and the bottom bar / ornament
    elsewhere — one structure, no per-platform layouts, no sidebar. Tabs:
    **Home / Library / Search / Settings**, each its own `NavigationStack`.
  - **Settings is now a full-screen tab, not a modal sheet.** Rebuilt as grouped
    **focusable cards** (Account / Sources / Playback / About) with colour-coded
    status values (`Available` green, `Not connected` red, `Coming soon` grey)
    via a new `AetherStatus`. `AppSession.isSettingsPresented` /
    `presentSettings()` removed.
  - **Home is content-first.** No page chrome — opens straight into Featured,
    Continue Watching, then a rail per library. Signed-out shows a cinematic
    **Welcome** hero ("Connect a Plex or Synology source…") instead of a utility
    dashboard.
  - **Movie Detail is the decision screen.** Audio and subtitle tracks are now
    selected **before** playback, always visible, with Source + Quality shown.
    Resume splits into **Continue Watching** (with `Resume from HH:MM:SS`) and
    **Play From Beginning**. The configured item (with the chosen tracks baked
    in) is what launches.
  - **Player simplified.** The in-player custom audio menu is gone — AVKit's
    native transport owns Play/Pause, Seek, and the Audio/Subtitle picker; Aether
    adds only an iOS Back affordance. Chrome auto-hides ~2.5s with nothing left
    behind. Playback failure now shows a proper **Retry + Close** state instead
    of a dead-end black screen.
  - **New reusable design-system primitives:** `AetherStatus`, a tvOS focus-row
    treatment (`aetherFocusRow`), and `AetherSelectionRow` (the shared audio /
    subtitle picker row). Settings rows gained focus + status styles.

### Added

- **Subtitle track model + selection.** `MediaItem` now carries
  `subtitleTracks` / `selectedSubtitleTrackID` and a `selectingSubtitleTrack(_:)`
  transform that mirrors audio: it writes Plex's `subtitleStreamID`
  (`0` = off) and mints a fresh transcode session. Subtitle streams
  (`streamType == 3`) are parsed from the same Plex response audio comes from —
  no new endpoint. Direct-play subtitles fall back to AVKit's native picker.
- **Search tab.** Client-side title search across the source's libraries via
  `.searchable` — no new backend.

- **Library detail view with sort + pagination.** Tapping the "See all"
  accessory on any library section on Home now pushes a full-grid
  `LibraryView` for that library. Sort options in the toolbar menu —
  Title A→Z / Z→A, Year newest / oldest, Recently added, Top rated,
  Random — with the user's choice persisted per-library via a new
  `LibraryPreferencesStore`. Items are fetched in pages of 100 (Plex's
  `X-Plex-Container-Start` / `Size` query items) and the next page loads
  when an invisible sentinel scrolls into view at the end of the grid.
  Selecting an item still pushes `DetailView` through the same
  navigationDestination chain. Mock and any future flat source default to
  unsorted full fetches; Plex implements the parametric variant via
  `sort=<field>:<direction>` query items mapped from a new `LibrarySort`
  enum in `AetherCore/Models`.

### Distribution

- **Single multiplatform target — one app, every Apple destination.** The
  three separate `Aether` / `Aether-tvOS` / `Aether-visionOS` targets are
  collapsed into one `Aether` target with
  `supportedDestinations: [iOS, tvOS, visionOS]`. One bundle ID
  (`cz.zmrhal.aether`), one App Store Connect app record, one Xcode Cloud
  workflow that archives every destination, one TestFlight invite that
  works on iPhone, iPad, Apple TV, and Apple Vision Pro. The asset catalog
  hosts `AppIcon.appiconset` (iOS), `AppIcon.brandassets` (tvOS), and
  `AppIcon.solidimagestack` (visionOS) under the canonical name `AppIcon`
  so a single `ASSETCATALOG_COMPILER_APPICON_NAME` setting resolves the
  right variant per destination.
- **Xcode Identity panel now fills in.** `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` moved from literal Info.plist values into build
  settings (project-wide defaults `"0.1.0"` and `"1"`), with the single
  Info.plist referencing them via `$(MARKETING_VERSION)` /
  `$(CURRENT_PROJECT_VERSION)` substitution. Xcode's General → Identity →
  Version / Build fields read the build settings, so they're populated
  again. `INFOPLIST_KEY_CFBundleDisplayName: Aether` surfaces the Display
  Name field too.
- **Repo is TestFlight-ready for iOS, tvOS, and visionOS.** Three pieces
  landed:
  - `ci_scripts/ci_post_clone.sh` — Xcode Cloud installs XcodeGen via
    Homebrew and runs `xcodegen generate` inside the cloned workspace
    before `xcodebuild` ever fires. Aether's `.xcodeproj` stays out of git.
  - `ci_scripts/ci_pre_xcodebuild.sh` — patches `CFBundleVersion` in the
    single Info.plist to `$CI_BUILD_NUMBER` (PlistBuddy), so each cloud
    archive ships a unique build number without manual bumps. Local builds
    keep the static `"1"` from `project.yml`.
  - Placeholder layered app icons for tvOS and visionOS, generated by an
    extended `Tools/generate-app-icon.swift`. tvOS gets a Brand Asset (App
    Icon - App Store at 1280×768, App Icon - Home Screen at 400×240, Top
    Shelf Image at 1920×720, each 3-layer Back / Middle / Front); visionOS
    gets a Solid Image Set (3 layers at 1024×1024). Reuses the same indigo
    gradient + play triangle as iOS so the three feel like one app.
  Plus `ITSAppUsesNonExemptEncryption: false` in Info.plist so App Store
  Connect skips the encryption export compliance question every build
  (Aether ships only Apple URLSession HTTPS).

### Documentation

- Rewrote the 0.5 distribution plan around the single multiplatform target
  pattern: one app record (not three), one Xcode Cloud workflow with three
  archive actions (one per destination), one TestFlight invite. Apple-side
  step-by-step checklist now in
  [`docs/next-steps/0.5-distribution.md`](docs/next-steps/0.5-distribution.md).

### UI

- Started a modern mobile player shell inspired by dedicated media apps:
  Home/Files/Search surfaces now hang off a glass bottom dock, Home has compact
  top chrome for source and refresh actions, source tiles give Files a real
  destination, and empty artwork now renders as a designed playback placeholder
  instead of a flat gray block.
- **Settings screen + sign out from Plex — no more app reinstall to disconnect.**
  A new `SettingsView` reachable from a gear icon in the Home header. Four short
  sections: **Account** (Plex connection state, "Sign Out of Plex" — the only
  destructive action), **Sources** (Plex live, Synology marked "Coming soon"),
  **Playback** (Direct Play available, transcoding + downloads marked "Coming
  soon"), and **About** (app name, version, build, tagline). Sign-out routes
  through `AppSession.signOutOfPlex()`, which clears the keychain token, drops
  the persisted server, resets discovery state, and returns Home to its
  welcome state — no fake mock fallback, no error trap.
- **Aether Design System v1.** All reusable view primitives now share the
  `Aether*` prefix and live in `AetherCore/DesignSystem/`. New primitives:
  `AetherButton` (`.primary` / `.secondary` / `.destructive`, focusable on tvOS),
  `AetherEmptyState`, `AetherLoadingState` (skeleton rails, no spinners),
  `AetherErrorState`, `AetherSettingsRow` + `AetherSettingsSection`. Renames:
  `CardView` → `AetherCard` (with `.poster` / `.hero` / `.episode` factories);
  `SectionHeader` → `AetherSectionHeader`. Every empty / loading / error state
  in Home, Detail, and Player now flows through these — no more inline
  computed-property variants drifting per screen.
- **Cinematic Home polish.** Featured rail upgraded to hero-sized 16:9 cards
  via `AetherCard.hero`. Poster rails enlarged for couch-distance on tvOS
  (300pt vs 260pt) and iOS (168pt vs 160pt); inter-card spacing bumped from
  `m` to `l`. Section spacing tightened around `xl`.
- **Cinematic Detail polish.** Backdrop reaches a taller hero on both
  platforms (420pt iOS / 560pt tvOS); title + metadata sit over the bottom of
  the backdrop instead of below it, so the page opens with artwork loudest.
  Play button replaced with `AetherButton.primary` carrying the
  `play.fill` glyph and "Play" / "Resume 12:34" label. Unavailable state
  reuses `AetherErrorState` instead of a one-off surface.
- **Player chrome auto-hides.** The overlay `xmark` close button on iOS /
  visionOS used to stay visible for the entire playback session, fighting
  the native AVKit transport bar (which auto-hides after ~3 s of no
  interaction). It now fades out alongside the transport on the same idle
  timer and reappears when the user taps the player area (via
  `simultaneousGesture`, so AVKit's own tap-to-reveal still fires). On
  tvOS the dismiss surface moves into the native chrome itself as a
  `Done` contextual action — the Menu button remains the primary path.

### Added

- **TV shows are now browsable.** A show is a container, not a playable item —
  opening one used to dead-end at "Unavailable." Now Detail drills into the
  Plex hierarchy: a show lists its **seasons** (poster rail), a season lists
  its **episodes** (a thumbnail + title + summary list), and an episode plays
  like a movie. Backed by a new `MediaSource.children(of:)`
  (`GET /library/metadata/{ratingKey}/children` on Plex) and a `.season`
  media kind. Navigation recurses within the existing `NavigationStack`.

### Changed

- **Native video player.** Replaced SwiftUI's prototype `VideoPlayer` with
  `AVPlayerViewController` (wrapped as `SystemVideoPlayer`). This brings device
  rotation + full-screen, the system transport bar (scrub / skip / time),
  Picture-in-Picture, AirPlay, and the subtitle / audio-track picker — none of
  which the SwiftUI player offered. Fixes "the video doesn't rotate."
- Audio now uses the `.playback` session category, so video has sound even with
  the ring/silent switch on, and continues for PiP / background. Added the
  `audio` background mode to the iOS Info.plist.

### Added

- **Transcode fallback so incompatible files play.** Direct play only works
  for containers AVPlayer opens natively (mp4 / m4v / mov). Anything else —
  MKV, AVI, TS, … — now routes through Plex's universal transcoder
  (`/video/:/transcode/universal/start.m3u8`, `protocol=hls`,
  `directStream=1`), which AVPlayer always understands. The common
  MKV/H.264/AAC case gets a cheap, lossless remux rather than a full
  re-encode. The choice is made per item from the Plex `Media.container`:
  friendly container → pristine direct file, otherwise → transcode. mp4
  titles keep playing exactly as before.

### Fixed

- **Plex now works off the home network.** Discovery used to persist only the
  single best connection — almost always the LAN address — so leaving the
  house left the app stuck on a dead URL (and, while it hung, showing stale
  mock content). `PlexServerRecord` now persists **all** of a server's
  connections, ranked best-first, and `PlexMediaSource` resolves a reachable
  one at runtime by probing `/identity` in order (local → direct remote →
  relay) with a short 4s timeout. The home screen gained a "Try again" that
  drops the cached connection and re-probes — useful after switching networks.

### Changed

- **Removed the mock library from the running app.** It was 0.1 scaffolding
  before real connectors existed; now it only confused things (it appeared as
  fake content whenever Plex was briefly unreachable). The app shows real Plex
  content or an honest welcome / empty / error state — never fake data.
  `MockMediaSource` survives as **test-only** infrastructure;
  `Aether/Resources/MockLibrary.json` and `MockMediaSource.loadFromBundle` are
  gone. `AppSession.source` is now `nil` until a Plex server is selected, and
  `HomeView` renders the welcome/empty state for the `nil` case.

### Platforms

- Added an early **visionOS** base: a new `Aether-visionOS` app target
  (`project.yml`) and `.visionOS(.v26)` in the `AetherCore` package.
  It shares every view with iOS and runs in a window. Platform-
  conditional branches were taught about visionOS — the player's
  close button and the sign-in "Open in Safari" button now show on
  visionOS too; `AppSession` reports the right platform identity to
  Plex. A spatial-native experience (ornaments, glass, immersive
  player) is a separate future milestone, not part of this base.
  > Note: the visionOS app-target build hasn't been verified by the
  > author (needs Xcode + visionOS SDK); `swift build` of `AetherCore`
  > passes with the new platform.

### Chores

- Added a temporary app icon — a glowing rounded play triangle on a deep
  indigo→black gradient, generated by `Tools/generate-app-icon.swift`
  (Core Graphics, no Xcode needed). Wired into `Assets.xcassets/AppIcon`
  for the iOS target. A designed icon replaces it before release; tvOS
  layered brand assets are still pending.
- Generated `Info.plist` / `Info-tvOS.plist` are no longer tracked in
  git — they're produced by `xcodegen generate` from `project.yml`, so
  tracking them just caused drift commits. Added to `.gitignore`.

### 0.2 — Media Sources (in progress)

- Added `AetherCore/Networking/APIClient` — the small protocol every
  media source goes through to talk to a network. Ships with
  `URLSessionAPIClient` for production and a recording stub for tests.
- Added `AetherCore/Storage/KeychainStore` — actor wrapper around
  `kSecClassGenericPassword` for tokens and other small secrets
- Added `PlexConfiguration` carrying the `X-Plex-*` headers Plex
  requires on every request (product, version, client identifier,
  device name, platform, platform version)
- Added `PlexAPI` namespace with `Decodable` DTOs (`PIN`, `Resource`,
  `Resource.Connection`)
- Added `PlexAuthClient` actor implementing the PIN auth flow:
  `requestPIN()` → user enters the code at `plex.tv/link` →
  `pollForToken(pinID:interval:timeout:)` returns the user's token
- `PlexMediaSource` now takes `baseURL`, `accessToken`, `configuration`,
  and an `APIClient`. `libraries()` / `items(in:)` remain stubs — they
  land in the next PR alongside the metadata mapping
- Added `docs/next-steps/0.2-media-sources.md` planning doc
- Added `PlexSignInViewModel` (`@MainActor`, `@Observable`) — drives
  the PIN sign-in state machine (`idle → requesting → awaitingUser →
  success | failure`) and runs the poll loop in a single owned task
  with `cancel()` / `retry()`
- Added `PlexSignInView` — couch-friendly: shows the four-letter PIN
  in large rounded type, an `Open in Safari` button on iOS, a QR code
  on both platforms so the user can hand off to another device
- Added `QRCodeView` (app target) — Core Image QR generator with
  nearest-neighbour scaling for crisp pixel edges
- `AppSession` now owns the `KeychainStore`, a shared `URLSessionAPIClient`,
  the `PlexConfiguration`, and the `PlexAuthClient`; round-trips the
  per-install Plex `clientIdentifier` (UUID) and the auth token via
  Keychain so signed-in state survives across launches
- Home's empty state now branches on `isPlexSignedIn` — pre-sign-in
  shows the "Add a source" CTA which presents the sheet; post-sign-in
  acknowledges the connection and tells the user server discovery is
  coming next
- Added `PlexResourceClient` actor — fetches `/api/v2/resources` with
  the user's Plex token, with `includeHttps` / `includeRelay` query
  flags
- Added `PlexServerSelector` — pure, deterministic filtering and
  ranking of resources into "the server we should talk to next."
  Static ranking only: local > non-relay > HTTPS, with owned-server
  tiebreaker. RTT-based ranking is a documented follow-up
- Added `PlexServerRecord` — the persisted shape of a selected server
  (client identifier, name, per-server access token, base URL,
  locality + relay flags)
- Added `PlexServerStore` actor — round-trips `PlexServerRecord` as
  JSON through `KeychainStore`
- `AppSession` now owns `PlexResourceClient` + `PlexServerStore`, runs
  discovery automatically after sign-in, restores the persisted server
  on launch, and exposes a `DiscoveryState` enum (`idle`, `discovering`,
  `noServersFound`, `failed(message:)`, `completed(serverName:)`)
- `AppSession.plexSource` now exists — the live `PlexMediaSource`
  built from the persisted record. Library browsing wires up in the
  next PR; for now `source` stays as the mock fixture
- Added `PlexDiscoveryView` — designed states for discovering / no
  servers / failed / completed; `Try again` and `Done` actions
- `PlexOnboardingView` switches between sign-in and discovery views
  based on `AppSession.isPlexSignedIn`, so the sheet flows directly
  from PIN → discovery → done without surprise dismissals
- Home's empty state now reads *"Connected to \<serverName\>"* once a
  server has been selected, honest about the next step
- `PlexAPI` extended with `LibrarySection`, `Metadata`, and matching
  `MediaContainer` response wrappers
- `PlexMediaSource.libraries()` now hits `GET /library/sections` and
  filters to movie + show sections (music + photos skipped in 0.2)
- `PlexMediaSource.items(in:)` now hits `GET /library/sections/{key}/all`
  and maps Plex `Metadata` → Aether `MediaItem`
- Artwork URLs (poster + backdrop) are constructed against the server
  base URL with `X-Plex-Token` carried as a query parameter, so
  `CachedAsyncImage` / `AsyncImage` can fetch them without setting
  headers
- `AppSession` now swaps `source` to the live `PlexMediaSource` when
  one is available (on launch via restore, after discovery completes,
  reverted to the mock fixture on sign-out)
- Empty state and discovery completed-state copy updated — no longer
  references "library browsing arrives in the next update"; reflects
  reality post-merge
- `PlexAPI.Metadata` extended with `Media` / `Part` so the list
  response's inline file info can be read without an extra request
- `PlexMediaSource` now resolves a **direct-play** `streamURL` from the
  first Part's `key`, tokenised against the server. Movies and episodes
  become playable; containers (shows, seasons) keep a `nil` streamURL
  because they aren't directly playable
- Plex movies now play end-to-end in the existing `PlayerView` /
  `PlaybackSession` for codecs AVPlayer supports (MP4/MOV/M4V/HLS).
  Incompatible containers (e.g. MKV) need the transcode fallback that
  lands in the next PR

### 0.1 — Foundation
- Verified `xcodegen generate` produces a clean project; relocated generated
  `Info.plist` and `Info-tvOS.plist` to `Aether/SupportingFiles/` so they're
  referenced via `INFOPLIST_FILE` only (not bundled as Resources)
- Excluded `.gitkeep` placeholders from the `Aether/Resources` resource phase
- DesignSystem: added `SectionHeader`, `BackdropImage`, `CachedAsyncImage`
- DesignSystem: `CardView` now supports artwork via `CachedAsyncImage`, lifts
  softly on tvOS focus, and renders a progress bar overlay
- Documented concrete token numbers (spacing, radii, motion, color,
  typography) in `docs/ux/DESIGN_PRINCIPLES.md`
- Added `Aether/Resources/MockLibrary.json` — 10 movies + 1 show with 6
  episodes, curated featured list, seed resume points
- Added `MockFixture` Codable DTOs and `MockMediaSource(fixture:)` /
  `MockMediaSource.loadFromBundle()` for loading the fixture
- Added `HomeFeed` value type and source-agnostic `HomeFeedBuilder` that
  produces Featured / Continue Watching / per-library sections
- Home now renders sectioned rails (Featured, Continue Watching, Movies,
  Shows) using `SectionHeader` + `CardView`, with skeleton loading state
- Detail screen now shows the backdrop hero, metadata row, summary, and
  a Resume / Play button reflecting the persisted resume point
- Player now seeks to the persisted resume point on open and writes the
  latest position back to `ResumeStore` on dismiss
- `AetherApp` introduces an `@Observable AppSession` that owns the active
  source and resume store, and seeds the store from the mock fixture
- `PlaybackSession` is now a real actor that owns the `AVPlayer`,
  performs all UI-touching calls via `MainActor.run`, seeks to the
  persisted resume on `prepare`, and writes resume points every 5s while
  playing (plus on pause and stop)
- Added `PlayerStateViewModel` (`@MainActor`, `@Observable`) — the bridge
  between the actor and SwiftUI's `VideoPlayer`. Views observe `state`
  and read `player`; commands flow through the view model
- `PlayerView` now drives the shared `PlaybackSession` via the view
  model instead of owning its own `AVPlayer`
- `AppSession` now also owns the single `PlaybackSession` instance for
  the app process
- tvOS focus polish: horizontal library rails are now `focusSection()`s
  so D-pad up/down moves between rails predictably instead of dropping
  focus wherever the last X-position was
- tvOS card sizes scaled up for couch distance (poster 160→260,
  episode 280→440); iOS sizes unchanged
- Detail screen's Play / Resume button now has a tvOS-tuned focused
  state (lift + accent strengthen) via a small isolated label view
- Documented in `PlayerView` that tvOS deliberately has no custom close
  chrome — Menu button on the Siri Remote is the exit
- Added `docs/architecture/TOP_SHELF.md` — explicit stub describing what
  the future Top Shelf extension needs to do and when
- Designed empty state for Home when a source has no content — calm
  hero icon, single sentence, "Add a source" CTA (no-op in 0.1; flow
  arrives in 0.2)
- Designed empty state on Detail when an item has no `streamURL` — the
  Play button is replaced with a soft "Unavailable" surface explaining
  why, instead of a disabled grey button
- Detail → Player is now a real crossfade (`.transition(.opacity)` +
  `Motion.hero`) via a ZStack overlay instead of `fullScreenCover`;
  audio pauses on the same frame the fade begins
- `accessibilityReduceMotion` collapses the crossfade to an instant cut
- tvOS player exit is wired via `.onExitCommand` so the Menu button
  triggers the same dismiss path as the iOS close button
