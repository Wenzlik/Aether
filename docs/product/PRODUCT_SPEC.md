# Aether — Product Specification

> Personal media, beautifully played.

This document defines what Aether is, who it is for, and — equally important — what it is not.

---

## Target audience

Aether is built for people who:

- Already own the media they want to watch (movies, TV, family video, concerts, talks).
- Already run, or are willing to run, a Plex server or a Synology NAS at home.
- Care about how an app *feels* on Apple hardware — typography, motion, focus, depth.
- Use multiple Apple devices (typically iPhone + Apple TV, often + iPad).
- Travel and want to take a few titles offline without ceremony.

Aether is not for:

- People looking for free streaming of someone else's content.
- People who want a do-everything HTPC frontend (Kodi, Jellyfin Kitchen Sink).
- Power users who measure a media player by how many obscure codecs it brute-forces.

These audiences are well served elsewhere. Aether explicitly declines to compete for them.

---

## UX philosophy

Aether is a **calm, premium, native** player. Everything else flows from that.

- **Calm:** the interface gets out of the way until you ask for it. Restrained chrome, generous space, type and artwork carry the experience.
- **Premium:** the small details — focus rings, transitions, loading states, empty states — feel considered, not generic.
- **Native:** SwiftUI, AVKit, system focus, system materials. Aether feels like Apple shipped it.

See [`../ux/DESIGN_PRINCIPLES.md`](../ux/DESIGN_PRINCIPLES.md) for the visual language.

---

## Competitive positioning

| | **Aether** | Plex (app) | Infuse |
|--|--|--|--|
| Native SwiftUI, all surfaces | ✅ | partial | partial |
| Multiple media sources | ✅ Plex + Synology | Plex only | broad |
| Apple TV focus polish | first-class | adequate | strong |
| Offline travel mode | first-class | yes | yes |
| Visual polish | premium-first | functional | strong |
| Server features (transcode, sync, share) | uses what's there | full Plex feature set | partial |
| Scope | deliberately narrow | broad | broad |

**Where Aether wins:**
- A second source: Synology Video Station / DSM, which the Plex app cannot do.
- Visual and motion polish, especially on tvOS, deliberately tuned for couch viewing.
- Predictable, calm UX — fewer features, better executed.

**Where Plex and Infuse stay ahead (for now):**
- Live TV / DVR, IPTV.
- Wide format support out of the box (Infuse).
- Plex-specific features like Plexamp, Watch Together, friends/sharing.

Aether is **not** trying to match feature-for-feature. It is trying to be the *nicest player* for the use case it covers.

---

## Supported platforms

| Platform   | Minimum | Notes |
|------------|---------|-------|
| iPhone     | iOS 26  | Primary mobile surface |
| iPad       | iPadOS 26 | Adapted layout, multi-column, PiP |
| Apple TV   | tvOS 26 | First-class focus engine |
| Vision Pro | visionOS 26 | Early base — the app target exists and runs in a window, sharing all UI with iOS. A spatial-native experience (ornaments, glass, an immersive player) is a future milestone, not part of this base. |

Not planned:

- macOS — possible later if it falls out of SwiftUI naturally
- Android, Windows, Web — explicit non-goals

---

## MVP definition

The MVP is everything in **0.1 + 0.2 + 0.3** of [`../../ROADMAP.md`](../../ROADMAP.md):

- A multi-platform app shell with a design system.
- A working Plex connector and a working Synology connector.
- Real playback through AVPlayer for both sources.
- Background downloads and reliable offline playback.

At MVP, Aether is usable as a primary player at home and on the road. **0.4 (Premium UX)** is what makes it feel premium; **0.5 (Distribution)** is what gets it to other people.

---

## Media source architecture

Two connectors at launch:

### Plex
- Account-based PIN auth (web flow) — no username/password in app.
- Server discovery via Plex.tv → preferred connection picked by RTT.
- Library and item listings via Plex Media Server HTTP API.
- Playback follows Plex Web's three-step flow: **PUT** stream selection on the Part → **GET** the decision endpoint for the verdict + post-decision codec/bitrate → build the playback URL from the verdict (file URL for direct play, `start.m3u8` for direct stream / transcode). Stream URLs include a session token; transcoding decisions stay with the server. See [`../architecture/ARCHITECTURE.md`](../architecture/ARCHITECTURE.md) for the full pipeline.
- Tokens stored in Keychain.

### Jellyfin
- Manual server URL + **Quick Connect** sign-in (no password typing — ideal for Apple TV remotes).
- Library and item listings via Jellyfin's `/Users/{id}/Items` API.
- Direct play for AVPlayer-friendly containers; HLS transcode (`master.m3u8`) for everything else, with `audioStreamIndex` / `subtitleStreamIndex` and `startTimeTicks` resume offset.
- Token stored in Keychain. `api_key` query param attached to image + media URLs (AVPlayer / `AsyncImage` can't set headers).
- Works alongside Plex via the single-active-source model: connect both, switch in Settings → Sources, the rest of the app renders the active one.

### Synology *(deferred)*
- DSM session auth or Video Station auth — whichever produces a usable stream URL with the least friction.
- Library = configured shares + Video Station collections.
- Direct play when codec is supported by AVPlayer; fall back to server transcoding via DSM's transcoding endpoints when available.
- Credentials stored in Keychain.
- *Lower priority now that Jellyfin covers the "second source" goal; Synology remains on the roadmap as an optional add for users who only run DSM.*

All connectors implement a small, shared protocol so the rest of the app sees a unified `MediaItem` and `MediaStream`. See [`../architecture/ARCHITECTURE.md`](../architecture/ARCHITECTURE.md).

---

## Playback goals

- **Direct Play first. Transcode only when needed.** Priority is always Direct Play → Direct Stream (container remux, lossless) → Transcode (re-encode). The user's quality choice biases this; sources confirm via the decision endpoint where available.
- **Quality picker on Detail** — Plex Web's eight-step ladder (Original / Convert Automatically / 20·12·8 Mbps 1080p / 4·2 Mbps 720p / 720 kbps). Default = Original. The picker shows the projected playback mode inline (*Original · Direct Play* / *Original · Direct Stream* / *Transcode*) so the user knows what's about to happen before pressing Play.
- **Track selection lives on Detail, not in the player.** Audio / Subtitles / Quality each open a half-height bottom sheet showing the option list. The player carries no track-switching API — Detail is the configuration surface, the player just plays what was configured.
- Resume points written every few seconds; respected on next open.
- AirPlay and PiP on iOS/iPadOS are first-class — not afterthoughts.
- tvOS playback uses the system player chrome where it makes sense; custom only where Aether can do meaningfully better.

Non-goals for MVP:

- Live TV / DVR
- Surround downmix configuration (use the system)
- Custom decoders (no FFmpeg in-app)
- Mid-playback track switching from the player overlay (it's a Detail-screen choice — the user goes back to change it)

---

## Offline goals

- Downloads are background, resumable, and survive an app kill.
- Offline playback works with no network reachable at all.
- A disk budget the user picks (default: 8 GB, configurable).
- Eviction is least-recently-watched first, with explicit "Keep" toggles.
- Resume points written offline sync back to the server when reachable.

Non-goals for MVP:

- Selective episode-by-episode downloads with smart prefetch (just whole items).
- Cellular auto-download.

---

## Metadata strategy

Metadata is **read-only** in Aether. Editing belongs in Plex / DSM.

- Titles, descriptions, cast, runtimes, ratings: fetched from the server, cached locally.
- Artwork: posters, backdrops, thumbnails — disk-cached, prefetched on focus, evicted on disk pressure.
- No internet metadata lookups in app (no TMDb / IMDb calls).
- Resume state: authoritative copy lives on the server; local copy is a cache plus an outbox.

---

## tvOS experience

tvOS is the platform Aether is *judged* on. It must feel at home next to the Apple TV app.

- Home: rows of artwork, focus-driven, edge-case-aware (empty state, offline state).
- Detail: full-bleed backdrop, type-led metadata, single "Play" CTA, secondary actions.
- Player: minimal overlay, big timeline on scrub, intentional focus targets.
- Search: tvOS keyboard, predictive, debounced.
- Settings: short list, single column, no nested labyrinth.

Every focusable element has an intentional focused/unfocused state. Cards lift softly. Type doesn't reflow when focused.

---

## iPad experience

iPad gets a multi-column layout when there's room.

- Sidebar (libraries / sources) + content column.
- Picture-in-picture for playback, with the library reachable behind it.
- Trackpad and keyboard support: arrow keys move focus, space toggles play.
- Stage Manager friendly — no fixed full-screen assumptions.

The iPad app is the iOS app with adaptive layout, not a separate target.

---

## Explicit non-goals

These are off the table for the foreseeable future. They are recorded here so they don't get rediscovered as ideas every quarter.

- **No torrent tooling.** No magnet links, no torrent client, no integration with torrent sites.
- **No piracy tooling.** No scraping unauthorized streams. No "scene" metadata sources.
- **No IPTV-first direction.** Live TV may appear later as a small feature, but Aether is not an IPTV player.
- **No Android app planned.** Aether is an Apple-platform product.
- **No web client initially.** The web is Plex's strength; we don't need to duplicate it.
- **No bundled Plex or Synology branding** in the app name or icon — Aether is its own product.
- **No ads. No telemetry beyond what Apple ships.** Privacy is part of the product.

---

## Future ideas

Captured as ideas, not promises. Promoted to `ROADMAP.md` if and when they become committed.

- iCloud sync of resume state across devices when no media server is reachable.
- Shared watchlists across Plex + Synology libraries.
- Apple Watch now-playing surface.
- visionOS spatial player.
- SharePlay co-watching for personal libraries.
- Family profiles with per-profile resume state.
- A small set of metadata enrichment hooks (poster overrides, custom playlists) — done locally, not by phoning home.
