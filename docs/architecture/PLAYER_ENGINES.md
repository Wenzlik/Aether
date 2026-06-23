# Player engines — VLCKit (iOS/tvOS/visionOS) vs libmpv (macOS)

Aether plays media through **two different playback engines depending on the
platform**. This is deliberate, and isolated to the app targets — the shared
`AetherCore` package stays engine-agnostic.

| Platform | Engine | Why |
|----------|--------|-----|
| iOS · tvOS · visionOS | **VLCKit 4** (`+ AVPlayer` fast path) | One engine across the mobile/TV/spatial trio; VLCKit 4 is the only build with a working visionOS slice. AVPlayer is used first for natively-decodable files (HW decode, PiP, AirPlay); everything else (mkv, DTS, …) falls back to VLCKit. |
| macOS | **libmpv** (the engine behind IINA) | VLCKit 3 is the only VLCKit with a working macOS video output, and it's old (2021-era) — its GL vout asserted on modern macOS. libmpv gives best-in-class VideoToolbox HW decode, HDR/Dolby Vision, and libass subtitles, and is what serious macOS players use. |

> **One sentence:** mobile/TV/spatial = VLCKit 4; Mac = libmpv. They never mix —
> the Mac libmpv code is not compiled into the iOS/tvOS/visionOS app, and VLCKit
> is not linked by the Mac app.

---

## Why the split is safe

`AetherCore` (the shared SPM package) is **engine-agnostic**. It handles auth,
sources, the unified library, and `resolvePlayback(_:) -> ResolvedPlayback` —
which returns a ready-to-play **URL** (a direct file/stream URL, or a Plex/
Jellyfin transcode HLS URL). It never constructs a player.

The **player lives in each app target**:

```
AetherCore (shared)            resolvePlayback → URL, MediaSource, UnifiedLibrary
   │
   ├── Aether        (iOS/tvOS/visionOS)  → VLCKit 4  + AVPlayer   (Aether/Sources/…)
   └── AetherMac     (macOS)              → libmpv                 (AetherMac/Sources/Mpv*.swift)
```

So adding libmpv to the Mac touched no shared code and nothing the other
platforms ship. The iOS `.ipa` does **not** contain libmpv; the Mac `.app` does
**not** link VLCKit.

---

## iOS / tvOS / visionOS — VLCKit 4

- **Vendored binary** `Vendor/VLCKit/VLCKit.xcframework` (~522 MB), **gitignored**,
  fetched by `scripts/fetch_vlckit.sh` (CI runs it via `ci_scripts/ci_post_clone.sh`).
- Linked as a local SPM `binaryTarget` and used by the `Aether` app target only.
- `VideoEngineResolver` (AetherCore) routes natively-decodable containers to
  **AVPlayer** (system chrome, PiP, AirPlay, HDR) and everything else to
  **VLCKit** — see *Engine selection* below.
- VLCKit **4** specifically, because it is the only build with a usable visionOS
  slice. (VLCKit 3 has the macOS vout but no visionOS.)

> **⚠️ VLCKit is on its way out (#476).** It's an LGPL-over-GPL wrapper we don't
> hold the copyright to → an App Store license risk. The plan is an
> AVFoundation-first, capability-tiered stack (remux shim + libmpv-LGPL
> fallback) that lets us drop VLCKit from the iOS family. macOS keeps libmpv and
> is out of scope. The routing seam below is the first step (P1).

---

## Engine selection — capability tiers (#476)

The choice of engine lives in **`AetherCore/Playback/VideoEngine.swift`** and is
pure, deterministic, and unit-tested (`VideoEngineResolverTests`). It is
UIKit-free — AetherCore never constructs a player, it only *decides* which one
the app target should present.

- **`MediaDescriptor`** — the routing inputs (URL scheme + container), built
  from a resolved URL or a raw container name (download-time, before a URL
  exists).
- **`VideoEngine`** protocol — a `canPlay(_:)` capability plus a `tier`
  (lower = cheaper / preferred). Conformers today: `AVFoundationEngine` (tier 0)
  and `VLCEngine` (tier 3, universal fallback).
- **`VideoEngineResolver`** — picks the **lowest-tier engine that can play** the
  descriptor. `.standard` is the app-wide immutable default; tests inject a
  custom engine list.

Routing rules (unchanged from the old enum, now expressed as tiers):

| Input | Engine |
|---|---|
| mp4 / m4v / mov / m4a / HLS (`.m3u8`) / extension-less transcode URL | AVFoundation |
| mkv / avi / ts / webm / … (local) | VLCKit |
| `smb://` anything (even `.mp4`) | VLCKit — AVPlayer can't open SMB (#214) |

> The tier model is the extension seam for #476: the planned **remux-to-fMP4
> shim** and **libmpv-LGPL fallback** slot in as new `VideoEngine` conformers at
> their tier; deleting VLCKit (P3) is removing the `VLCEngine` conformer + its
> view. No routing call site changes.

---

## macOS — libmpv

The Mac player is `AetherMac/Sources/Mpv*.swift`:

- **`MpvClient`** — a thin wrapper over one `mpv_handle`: load, transport,
  property reads, track selection. Owns the OpenGL render context too, so
  teardown is ordered.
- **`MpvVideoView`** — an `NSOpenGLView` backing an `mpv_render_context`; mpv
  renders into the view's framebuffer.
- **`MacPlayerModel`** — the `@Observable` model the SwiftUI controls bind to
  (IINA-style: scrubber, ±10s, audio/subtitle menus, full-screen). The player is
  presented **inline in the main window** (an overlay swap), not a separate window.

### How libmpv is obtained and shipped

libmpv has a large dependency tree (ffmpeg, libass, dav1d, x264/5, …) so it is
**not committed** to the repo — same policy as VLCKit.

- **Headers** are vendored in `Vendor/Mpv/include` with a `Cmpv` module map
  (`Vendor/Mpv/module.modulemap`), wired into the target via `OTHER_SWIFT_FLAGS`
  + `HEADER_SEARCH_PATHS`. These are committed (small, stable).
- **The dylib** comes from **Homebrew** for dev builds — `scripts/fetch_mpv.sh`
  runs `brew install mpv dylibbundler`. Dev builds link `/opt/homebrew/lib/libmpv`.
- **For distribution** (Xcode Cloud / end users), a **Release-only post-build
  phase** runs `dylibbundler`: it copies libmpv + its whole dependency tree into
  `AetherMac.app/Contents/Frameworks`, rewrites install names to
  `@executable_path/../Frameworks`, and re-signs the bundled dylibs. The result
  is a self-contained `.app` that runs on a Mac **without Homebrew** (verified:
  zero `/opt/homebrew` references in the archived binary).
- The Mac target is **arm64-only** (`ARCHS = arm64`) — Homebrew's libmpv has no
  x86_64 slice. Apple Silicon only. (Intel would need a separately-built libmpv.)
- Links with `-headerpad_max_install_names` so `dylibbundler` can rewrite the
  load commands.

### libmpv integration gotchas (hard-won)

- **Callbacks must be non-isolated.** mpv calls its render-update / wakeup
  callbacks from raw pthreads (e.g. the `vo` thread). A closure written inside an
  `@MainActor` view (`NSView` is `@MainActor`) inherits that isolation and the
  Swift runtime traps (`swift_task_isCurrentExecutor` → `dispatch_assert_queue`,
  SIGTRAP) the instant mpv invokes it. The callbacks are **file-scope, non-isolated
  functions** that hop to main via `DispatchQueue.main.async` (not `Task { @MainActor }`).
- **Terminate off the main thread.** `mpv_terminate_destroy` joins every mpv
  thread, including a demux thread blocked in a network read (Plex HLS) — on the
  main thread that froze the UI on close/quit. It runs on a background queue.
- **Never block main with `mpv_get_property`.** It goes through mpv's dispatch
  lock and blocks until the core services it; a stalled network stream froze the
  UI when recording resume on stop. The playhead is cached from `time-pos` events
  and used at teardown — teardown touches no mpv API.

---

## SMB / network

The iOS range-proxy (#213) exists because **VLCKit** reads SMB slowly; it serves
the share over a fast localhost HTTP range-proxy. **It is not relevant on macOS**:
libmpv opens `smb://` natively (via ffmpeg) and reads Finder-mounted shares
(`/Volumes/…`) as plain files. So the proxy work is for the VLCKit platforms only.

---

## Build / fetch scripts

| Script | Purpose |
|--------|---------|
| `scripts/fetch_vlckit.sh` | Fetch the iOS/tvOS/visionOS VLCKit 4 xcframework (gitignored). |
| `scripts/fetch_mpv.sh` | Install libmpv + `dylibbundler` via Homebrew for the macOS build. |
| `ci_scripts/ci_post_clone.sh` | Xcode Cloud: runs both of the above + installs XcodeGen and the pinned `Package.resolved`. |

(The former `scripts/fetch_vlckit_mac.sh` — VLCKit 3 for macOS — was removed when
the Mac switched to libmpv.)
