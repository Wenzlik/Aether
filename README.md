# Aether

> Personal media, beautifully played.

Aether is a premium, native cinematic media player for **iPhone**, **iPad**, **Apple TV**, **Vision Pro**, and **Mac**.

It plays your own media from your own infrastructure — a Synology NAS on the local network, a Plex server at home or on the road, or files you've downloaded for offline travel — wrapped in a calm, typography-forward interface that feels at home on every Apple platform.

---

## Supported platforms

| Platform   | Minimum | Status |
|------------|---------|--------|
| iOS        | 26      | primary |
| iPadOS     | 26      | primary |
| tvOS       | 26      | primary |
| visionOS   | 26      | early base — runs in a window, shares all UI; spatial-native experience TBD |
| macOS      | 15      | native app (Apple Silicon) — sidebar + inline player; plays through libmpv |

Aether is built top-to-bottom on the modern Apple stack. SwiftUI for every surface, Swift 6 with full concurrency, AVKit for playback, and a shared `AetherCore` package for everything that isn't view code.

**Playback engine differs by platform:** iOS/iPadOS/tvOS/visionOS use **VLCKit 4** (with an AVPlayer fast path for natively-decodable files); macOS uses **libmpv** (the engine behind IINA). The shared `AetherCore` is engine-agnostic — see [`docs/architecture/PLAYER_ENGINES.md`](docs/architecture/PLAYER_ENGINES.md).

---

## Product direction

Aether is not a generic media-center kitchen sink.

Priority:
- native Apple feel
- fast browsing
- reliable playback
- beautiful library views
- offline-first travel mode
- privacy-friendly personal media

Aether is **not** a torrent client, an IPTV-first app, a piracy tool, or a do-everything media center. It is opinionated about being a beautiful player for media you already own and host yourself.

---

## Philosophy

- **Native Apple UX.** SwiftUI, AVKit, system-standard navigation, real focus engine on tvOS.
- **Calm interface.** Restrained chrome, generous spacing, typography-first hierarchy, soft depth.
- **Speed over surface.** Browsing should never feel laggy; artwork should load before you notice.
- **Reliability.** Playback Just Works — local NAS, remote Plex, offline cache.
- **Premium feel.** Cinematic detail screens, immersive transitions, polished tvOS focus.
- **Privacy-friendly.** Your media stays on your hardware. No telemetry beyond what Apple ships.

---

## Architecture summary

```
Aether (app target, iOS + tvOS)
  └── depends on → AetherCore (shared Swift package)
                     ├── Models          // media domain types
                     ├── MediaSources    // Plex + Synology connectors
                     ├── Playback        // AVPlayer wrappers, queue, session
                     ├── Downloads       // background download manager
                     ├── Storage         // local persistence + cache
                     └── DesignSystem    // tokens, components, motion
```

The app target stays thin — it is mostly SwiftUI views, navigation, and platform glue. All real logic lives in `AetherCore` so it can be unit-tested and shared across iOS and tvOS.

See [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md) for the full picture.

---

## Stack

- **SwiftUI** — every view, every platform
- **Swift 6** with strict concurrency
- **async/await** + **actors** for all asynchronous work
- **AVKit / AVFoundation** for playback
- **URLSession** with background configuration for downloads
- **XcodeGen** to keep the Xcode project file regenerable from `project.yml`

Apple frameworks are strongly preferred. Third-party dependencies are added only when an Apple framework cannot reasonably do the job, and each one must be justified in the PR that adds it.

---

## Roadmap preview

- **0.1 Foundation** — multi-platform shell, design system, AVPlayer prototype
- **0.2 Media Sources** — Plex + Synology connectors, metadata, artwork, continue watching
- **0.3 Offline** — background downloads, offline playback, storage management
- **0.4 Premium UX** — immersive detail screens, cinematic transitions, tvOS focus polish
- **0.5 Distribution** — TestFlight, localization, accessibility, App Store prep

Full roadmap: [ROADMAP.md](ROADMAP.md).

---

## Build instructions

```bash
# 1. Install XcodeGen (one-time)
brew install xcodegen

# 2. Generate the Xcode project from project.yml
xcodegen generate

# 3. Open in Xcode
open Aether.xcodeproj
```

Requirements: Xcode with iOS 26 and tvOS 26 SDKs.

The repository is intentionally checked in **without** `Aether.xcodeproj` — the project file is generated from `project.yml` to keep diffs sane and merge conflicts rare.

---

## Documentation

| Where | What |
|-------|------|
| [docs/product/PRODUCT_SPEC.md](docs/product/PRODUCT_SPEC.md) | Audience, scope, MVP, non-goals |
| [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md) | Module layout, data flow, actors, caching |
| [docs/architecture/PLAYER_ENGINES.md](docs/architecture/PLAYER_ENGINES.md) | Playback engines: VLCKit 4 (iOS/tvOS/visionOS) vs libmpv (macOS), bundling |
| [docs/ux/DESIGN_PRINCIPLES.md](docs/ux/DESIGN_PRINCIPLES.md) | Visual language, motion, focus behavior |
| [docs/next-steps/0.1-foundation.md](docs/next-steps/0.1-foundation.md) | Implementation plan for the current milestone |
| [docs/next-steps/0.2-media-sources.md](docs/next-steps/0.2-media-sources.md) | Plex/Synology source plan and remaining connector work |
| [docs/next-steps/0.3-offline.md](docs/next-steps/0.3-offline.md) | Offline downloads, storage, and resume-sync plan |
| [docs/next-steps/0.5-distribution.md](docs/next-steps/0.5-distribution.md) | Internal TestFlight and Xcode Cloud setup checklist |
| [AGENTS.md](AGENTS.md) | Conventions for AI coding agents (Claude Code, Codex, Gemini, Copilot, Cursor) |

---

## Trademark disclaimer

Aether is an independent project. It is not affiliated with, endorsed by, or sponsored by **Plex Inc.**, **Synology Inc.**, or **Apple Inc.**

"Plex" is a trademark of Plex Inc. "Synology" is a trademark of Synology Inc. "Apple", "iPhone", "iPad", and "Apple TV" are trademarks of Apple Inc. These names are used in this repository only to describe interoperability and supported hardware/services.

Aether does not bundle Plex or Synology branding in its app name, icon, or in-app surfaces.

---

## License

[MIT](LICENSE).
