# Aether

> Personal media, beautifully played.

Aether is a premium, native cinematic media player for **iPhone**, **iPad**, **Apple TV**, **Vision Pro**, and **Mac**.

It plays your own media from your own infrastructure — a Plex or Jellyfin server at home or on the road, a NAS or SMB share on the local network, or files you've downloaded for offline travel — wrapped in a calm, typography-forward interface that feels at home on every Apple platform.

---

## Supported platforms

| Platform   | Minimum | Status |
|------------|---------|--------|
| iOS        | 26      | primary |
| iPadOS     | 26      | primary |
| tvOS       | 26      | primary |
| visionOS   | 26      | primary — spatial Cinema mode (Dark Theater, screen size, seat distance) |
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
Aether (app target, iOS + iPadOS + tvOS + visionOS + macOS)
  └── depends on → AetherCore (shared Swift package)
                     ├── Models          // media domain types
                     ├── MediaSources    // Plex, Jellyfin, SMB/NAS connectors
                     ├── Playback        // VLCKit 4 / libmpv wrappers, queue, session
                     ├── Downloads       // background download manager
                     ├── Storage         // local persistence + cache
                     └── DesignSystem    // tokens, components, motion
```

The app target stays thin — it is mostly SwiftUI views, navigation, and platform glue. All real logic lives in `AetherCore` so it can be unit-tested and shared across platforms.

See [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md) for the full picture.

---

## Stack

- **SwiftUI** — every view, every platform
- **Swift 6** with strict concurrency
- **async/await** + **actors** for all asynchronous work
- **VLCKit 4** for playback on iOS / iPadOS / tvOS / visionOS (AVPlayer fast path for natively-decodable files); **libmpv** on macOS
- **URLSession** with background configuration for downloads
- **XcodeGen** to keep the Xcode project file regenerable from `project.yml`

Apple frameworks are strongly preferred. Third-party dependencies are added only when an Apple framework cannot reasonably do the job, and each one must be justified in the PR that adds it.

---

## Roadmap preview

- **0.1–0.5** ✅ — multi-platform shell, Plex + Jellyfin connectors, offline downloads, unified library, immersive detail screens
- **0.6 "Cassiopeia"** ✅ — full design system refresh, tvOS focus polish, clearLogos, visionOS Cinema (Dark Theater)
- **0.7** ✅ — native macOS app (libmpv), SMB/NAS native source, cross-device resume, Netflix availability badges
- **0.8** 🚧 — Plex direct play, mid-playback audio/subtitle track switching, VLC player controls, SMB performance

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

> **Note:** Playback requires `VLCKit.xcframework` (~2.4 GB), which is not checked in. Symlink or copy it from an existing checkout before building:
> ```bash
> ln -s /path/to/existing/Aether/VLCKit.xcframework VLCKit.xcframework
> ```

---

## Documentation

| Where | What |
|-------|------|
| [docs/product/PRODUCT_SPEC.md](docs/product/PRODUCT_SPEC.md) | Audience, scope, MVP, non-goals |
| [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md) | Module layout, data flow, actors, caching |
| [docs/architecture/PLAYER_ENGINES.md](docs/architecture/PLAYER_ENGINES.md) | Playback engines: VLCKit 4 (iOS/tvOS/visionOS) vs libmpv (macOS), bundling |
| [docs/ux/DESIGN_PRINCIPLES.md](docs/ux/DESIGN_PRINCIPLES.md) | Visual language, motion, focus behavior |
| [CHANGELOG.md](CHANGELOG.md) | Release history with per-version feature lists |
| [RELEASING.md](RELEASING.md) | Ship procedure: staging → main promotion + Xcode Cloud tagging |
| [AGENTS.md](AGENTS.md) | Conventions for AI coding agents (Claude Code, Codex, Gemini, Copilot, Cursor) |

---

## Trademark disclaimer

Aether is an independent project. It is not affiliated with, endorsed by, or sponsored by **Plex Inc.**, **Synology Inc.**, or **Apple Inc.**

"Plex" is a trademark of Plex Inc. "Synology" is a trademark of Synology Inc. "Apple", "iPhone", "iPad", and "Apple TV" are trademarks of Apple Inc. These names are used in this repository only to describe interoperability and supported hardware/services.

Aether does not bundle Plex or Synology branding in its app name, icon, or in-app surfaces.

---

## License

Copyright © 2026 Vašek Zmrhal. All rights reserved.

Aether is **source-available, not open-source**: the code is published for
transparency and reference, but it is proprietary. You may view, study, and
build it locally for personal, non-commercial evaluation — you may not copy,
modify, redistribute, or sell it, or use it to build a competing product. See
[LICENSE](LICENSE) for the full terms. Bundled third-party components (libmpv,
FFmpeg, libass, VLCKit, …) remain under their own licenses.

For commercial licensing, contact vasek@aetherplayer.com.
