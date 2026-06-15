# macOS App — status & where to continue

Native macOS app (`AetherMac` target), Apple Silicon, sharing `AetherCore` with
the iOS/iPadOS/tvOS/visionOS app. Shipped as a **Developer ID notarized DMG over
the web** — not the Mac App Store (the bundled GPL mpv/FFmpeg stack rules it
out, same reason VLC/IINA aren't there).

- **Current version:** 0.7.6 · live at <https://aetherplayer.com/downloads/Aether-0.7.6.dmg>
- **Branch:** `feature/macos-app` (→ PR to `staging` → `main`)
- **Engine:** libmpv (IINA's engine), rendered via Metal (software render → MTLTexture)
- **Build identifier:** the short git commit (`AetherGitCommit`), shown in Settings → About

---

## How to build & release

Everything is scripted. One-time setup must already be in place:

- A **Developer ID Application** cert in the login keychain (team `8PW5FWH7P2`).
- A notarytool keychain profile named **`aether-notary`**:
  ```sh
  xcrun notarytool store-credentials aether-notary \
    --apple-id vasek@zmrhal.cz --team-id 8PW5FWH7P2 --password <app-specific-password>
  ```
  (If notarization fails with "No Keychain password item found for profile", re-run this.)
- **TMDb fallback key** for local builds: `Config/Secrets.xcconfig` (gitignored)
  with `TMDB_API_KEY = <v3 key>`. Baked into the DMG's Info.plist as
  `TMDBAPIKey`; users can still override it in Settings. Empty = metadata
  matching disabled (a *wrong* value is worse — TMDb returns 401).
- Homebrew `dylibbundler`, `create-dmg`, and libmpv (`scripts/fetch_mpv.sh`).

Then:

```sh
scripts/package-mac.sh    # xcodegen → archive → Developer ID export → notarize →
                          # staple → DMG (create-dmg) → notarize+staple the DMG
scripts/deploy-dmg.sh     # upload to the NAS web root + verify sha256 + https
                          # (needs LAN/VPN to 192.168.1.10; SSH key ~/.ssh/aether_synology)
```

Local verify build (no signing):
```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild -project Aether.xcodeproj -scheme AetherMac \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/aether-verify build
```

See `RELEASING-macos.md` for the full release runbook.

---

## What's implemented (parity matrix)

| Area | Status |
|------|--------|
| Plex / Jellyfin / local files | ✅ |
| libmpv Metal player (HW decode, HDR, subs) | ✅ |
| Inline player window, auto-hiding controls, keyboard shortcuts | ✅ |
| Continue Watching / resume (local + server-seeded) | ✅ |
| Detail: Resume / Restart, Mark Watched, Favorite, episode→season→show nav | ✅ |
| Library: multi-source, sort, multi-year + rating filters (#351) | ✅ |
| Discover: curated rails, hide in-progress (#350) | ✅ |
| Home/Discover cache + animated loading (iOS parity) | ✅ |
| Auto-Play-Next, Skip Intro / Skip Credits, finish handling | ✅ |
| Desktop-native Detail layout (left hero, two-column, big Play) | ✅ |
| TMDb metadata (fallback key + Settings override + validation) | ✅ |
| Appearance (Dark/Light), Settings hub | ✅ |

---

## Cross-device resume (server-side) — in progress

Tracked under **#352** (epic), **#353** (write), **#354** (read). macOS can't use
iCloud KVS (Developer ID build, no entitlement), so resume syncs through the
**media server**:

- **Write (#353, landed):** `MediaSource.recordProgress` → Plex `/:/timeline`,
  Jellyfin `/Sessions/Playing/Progress`. Fired from the player's resume tick + pause/stop.
- **Read (#354, landed):** `MediaSource.serverResumePoints` → Plex `/library/onDeck`,
  Jellyfin `/Users/{id}/Items/Resume`, seeded into `ResumeStore` on a forced
  Home refresh (kept off the cold path for speed).
- **Verify on real servers:** play on the iPhone, open the Mac with an empty
  local resume cache → the title should appear in Continue Watching at the right
  offset. Not yet confirmed against live Plex/Jellyfin — that's the next check.

The local `ResumeStore` (disk + iCloud on the Apple platforms) stays the offline
cache and the only sync for Local/SMB/DLNA.

---

## Where to continue (next steps)

**Detail screen — deferred from the redesign feedback:**
- Fill the right rail / desktop space with more info panels: Source Information,
  File Information, Audio Track details, Related / Similar content, Watch
  Providers (future). Currently the lower half of the screen is empty for movies.
- Optional narrower / collapsible sidebar (Finder / Apple Music style).
- Keep tuning: left-gradient strength, Play size, description width, spacing —
  iterate against screenshots on a real display.

**Player / playback:**
- Confirm Skip Intro / Skip Credits + Auto-Play-Next against live Plex markers
  and Jellyfin MediaSegments (built, not yet verified on real content).
- PiP / AirPlay equivalents, if desired (libmpv has no native PiP).

**Distribution / web:**
- **Cache-busting** the download link (same filename `Aether-0.7.3.dmg` is cached
  by browsers/CDN). Add `?b=<commit>` on the `aether_web` download button, or
  `Cache-Control: no-cache` for `.dmg` — otherwise a re-shipped 0.7.3 serves stale.
- Auto-update mechanism (Sparkle) — not started.

**Cross-platform follow-ups:**
- #352/#353/#354 verification (above), then close.
- Sidebar width / collapse (point 7 of the Detail feedback).

---

## Key files

- `AetherMac/Sources/MacSession.swift` — app state, sources, library/rails cache,
  resume, segments/nextEpisode, TMDb key resolution.
- `AetherMac/Sources/MacPlayerModel.swift` — libmpv player model: resume, skip
  segments, Auto-Play-Next, finish handling.
- `AetherMac/Sources/MpvPlayerView.swift` / `MpvVideoView.swift` / `MpvClient.swift`
  — player UI + Metal render + libmpv bridge.
- `AetherMac/Sources/MediaDetailView.swift` — desktop Detail screen.
- `AetherMac/Sources/DiscoverView.swift` / `LibraryGridView.swift` / `ContentView.swift`
  — Home/Discover, Library, window/navigation shell.
- `AetherMac/Sources/MacSettingsView.swift` — Settings (TMDb key, appearance, About).
- `project.yml` — AetherMac target: deployment macOS 26, hardened-runtime
  entitlements, `Config/App.xcconfig`, "Stamp git commit" + "Bundle libmpv" phases
  (incl. the LC_RPATH de-dup that fixed the macOS-26 launch crash).
- `scripts/package-mac.sh`, `scripts/deploy-dmg.sh`, `ci_scripts/ExportOptions-DeveloperID.plist`.

---

## Gotchas (learned the hard way)

- **Duplicate `LC_RPATH`** on a bundled dylib makes macOS 15+/26 dyld refuse to
  launch the app. dylibbundler can add `@executable_path/../Frameworks` twice
  across incremental builds — the "Bundle libmpv" phase now de-dups. If a launch
  crash returns ("Library not loaded … duplicate LC_RPATH"), check that.
- **No iCloud entitlement** on the Developer ID build — don't add iCloud KVS; it
  can't be signed and blocks the archive. Cross-device sync goes via the server.
- **Same-filename DMG is cached** — verify a fresh download by checking
  Settings → About → Build matches the shipped commit.
- **`CachedAsyncImage` is `.fill` by default** — pass `contentMode: .fit` for
  logos/wordmarks so they don't overflow their frame.
