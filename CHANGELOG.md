# Changelog

All notable changes to Aether are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Initial repository bootstrap
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
