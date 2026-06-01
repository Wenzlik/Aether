# Changelog

All notable changes to Aether are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

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
