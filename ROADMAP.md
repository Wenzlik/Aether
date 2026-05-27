# Roadmap

Aether ships in small, named milestones. Each one is shippable on its own — no milestone depends on a future one being "completed."

> Roadmap items are promises about *order*, not deadlines. The dates appear in `CHANGELOG.md` when a milestone actually ships.

---

## 0.1 Foundation

The skeleton: a multi-platform SwiftUI shell that compiles on iOS and tvOS, with a mock library and a working AVPlayer prototype. No real network calls yet.

- SwiftUI multi-platform app shell (iOS + tvOS)
- XcodeGen setup (`project.yml`) — project file is generated, not checked in
- Shared package structure (`AetherCore`) wired into both app targets
- Mock media library (in-memory, shipped as a JSON fixture)
- Design system foundation: tokens, type, spacing, color, basic components
- AVPlayer prototype: pick a mock title, play a sample video, show resume state

**Definition of done:** clone → `xcodegen generate` → build & run on iOS and tvOS simulators → see a mock library → play a sample video → app feels Apple-native.

Planning notes: [`docs/next-steps/0.1-foundation.md`](docs/next-steps/0.1-foundation.md).

---

## 0.2 Media Sources

Real media, from real servers. This is the milestone that turns Aether from a shell into a player.

- Plex connector: discovery, PIN auth, libraries, items, stream URLs
- Synology connector: auth (Video Station / DSM), shares, items, stream URLs
- Metadata mapping: a unified `MediaItem` model that both sources fill in
- Artwork caching: disk-backed image cache, prefetch on focus
- Continue watching: resume points written on playback, surfaced on home

**Definition of done:** sign in to a real Plex server, sign in to a real Synology, browse both libraries, play a title from each, see resume state on next launch.

---

## 0.3 Offline

Travel mode. Downloaded titles must play with the network completely off.

- Background downloads (resumable `URLSession` background config)
- Offline playback (local URLs, no fallback to remote)
- Local persistence: download metadata, resume points, library snapshots
- Storage management: disk budget, eviction policy, per-title size, clear-cache UI

**Definition of done:** download a title on Wi-Fi → toggle airplane mode → playback works end-to-end → resume state syncs back when network returns.

---

## 0.4 Premium UX

The polish milestone. This is where Aether earns the "premium" label.

- Immersive detail screens — cinematic backdrops, typography-led metadata, soft depth
- Cinematic transitions between library, detail, and player
- Player overlays — chrome that fades, gestures that feel right, scrubbing that feels expensive
- Subtitle and audio track controls (selection, sizing, positioning)
- tvOS focus polish — every focusable element has intentional focused/unfocused states; section focus works; remote feels great

**Definition of done:** a stranger can use the app on Apple TV without instructions and the experience feels at home next to the system TV app.

---

## 0.5 Distribution

Get it into people's hands without embarrassment.

- TestFlight build pipeline (manual is fine to start; automate later)
- Localization scaffolding (`Localizable.xcstrings`) and at least English + Czech
- Accessibility: VoiceOver labels, Dynamic Type on iOS, sufficient contrast, focus reachability on tvOS
- App Store preparation: privacy manifest, screenshots, store copy, support URL

**Definition of done:** a TestFlight invite link works on iPhone, iPad, and Apple TV; accessibility audit passes; the App Store listing is reviewable.

---

## Beyond 0.5

Captured as ideas, not promises. Lives in [`docs/product/PRODUCT_SPEC.md`](docs/product/PRODUCT_SPEC.md) under "Future ideas."

Examples currently on the table:

- iCloud sync of resume state across devices when no media server is reachable
- Shared watchlists between Plex and Synology libraries
- Apple Watch now-playing surface
- Picture-in-picture on iPad with multi-touch gestures
- Personal "watch with friends" via SharePlay
