# Releasing Aether

Aether is **one app, one repo, one `main`** — but it ships to several platforms,
each of which can release on its own cadence. This document is the source of
truth for how a build reaches TestFlight.

## Branch model

- **`staging`** — the working base. Every feature/fix branches from it and PRs
  back into it; CI (`AetherCore build`, `App build + AetherTests`,
  `Build (tvOS)`, `Build (visionOS)`) must be green before merge.
- **`main`** — the release branch. Merging `staging → main` is what produces a
  TestFlight build, so it's done deliberately, one promotion at a time.

Never make per-platform branches — platform differences live in code
(`#if os(…)` and platform-specific files), not in branches.

## How each platform ships (Xcode Cloud)

Each Xcode Cloud workflow archives **exactly one platform** (set in its
*Archive* action). To let platforms ship independently — and to avoid App Store
Connect rejecting two simultaneous deliveries — the workflows have different
**start conditions**:

| Platform | Workflow start condition | Builds when |
|----------|--------------------------|-------------|
| **iOS**  | Tag Changes → `ios/…`    | an `ios/…` tag is pushed |
| **tvOS** | Tag Changes → `tvos/…`   | a `tvos/…` tag is pushed |
| **visionOS** | Tag Changes → `visionos/…` | a `visionos/…` tag is pushed |
| **macOS** | Tag Changes → `macos/…` | a `macos/…` tag is pushed _(workflow must be created first — see below)_ |

**Every platform is tag-gated** — nothing auto-builds on a plain push to `main`.
Merging `staging → main` means "ready"; pushing the tags means "ship". This
keeps all platforms building the **same commit** and avoids App Store Connect
rejecting simultaneous deliveries.

## The release flow

1. **Promote** the release: merge `staging → main` (CI green first). This does
   **not** trigger any build by itself.
2. **Tag the platforms** so they build the same commit:

   ```sh
   scripts/ship-platforms.sh        # tags origin/main for iOS + tvOS + visionOS
   ```

   This reads `MARKETING_VERSION` from `project.yml`, takes the short SHA of
   `origin/main`, and pushes one tag per platform.

That's it — all platforms build the same commit from the tags.

### Shipping one platform first (e.g. iOS, then the rest)

To validate one platform before the others, push its tag by hand, then run the
script for the remainder (it skips tags that already exist):

```sh
SHA=$(git rev-parse --short origin/main)
VER=$(git show origin/main:project.yml | grep -m1 MARKETING_VERSION: | sed -E 's/.*"([^"]+)".*/\1/')
git tag "ios/$VER-$SHA" origin/main && git push origin "ios/$VER-$SHA"   # iOS first
# …verify iOS on TestFlight, then ship the rest:
scripts/ship-platforms.sh                                               # tvOS, visionOS, (macOS)
```

### macOS shipping setup (one-time)

macOS is a **separate App Store Connect record** (bundle id `cz.zmrhal.aether.mac`),
so it never collides with the iOS delivery. Before the first Mac release:

1. Create a macOS **Xcode Cloud workflow** — Archive action = macOS (scheme
   `AetherMac`), start condition **Tag Changes → `macos/…`**.
2. Add `macos` to the `PLATFORMS` array in `scripts/ship-platforms.sh`.
3. The macOS archive is **Release** config, which runs the post-build phase that
   bundles libmpv + its ffmpeg deps into the `.app` (self-contained, arm64-only).
   `ci_post_clone.sh` installs libmpv + `dylibbundler` via `scripts/fetch_mpv.sh`.
   The bundled dylibs are re-signed in the build phase; verify codesign/notarization
   on the first archive. See [docs/architecture/PLAYER_ENGINES.md](docs/architecture/PLAYER_ENGINES.md).

### Tag format

```
<platform>/<MARKETING_VERSION>-<short-sha>     e.g.  tvos/0.6.4-b436e24
```

- **Unique per build** — `MARKETING_VERSION` stays on a value (e.g. `0.6.4`)
  across many builds, so the short SHA makes each tag distinct; otherwise
  re-pushing the same tag wouldn't trigger a new Xcode Cloud build.
- **Traceable** — every platform build maps back to an exact commit + version.

## Build numbers

`CFBundleVersion` is stamped at build time by `ci_scripts/ci_pre_xcodebuild.sh`
from `CI_BUILD_NUMBER` (globally unique per build across the team), so each
platform's TestFlight track gets unique, non-colliding build numbers
automatically. `MARKETING_VERSION` in `project.yml` is the shared, human
version and is bumped by hand (patch bumps are routine; minor/major are a
deliberate call).

## Notes & gotchas

- **App Store Connect processes one delivery per app at a time.** If two
  platform archives finish and deliver simultaneously, the second fails with
  _"An update has already been initiated by another request…"_ — just **Rebuild**
  it once the first clears "Processing". `ship-platforms.sh` pushes the tags
  back-to-back, which usually staggers delivery enough; if you still hit it,
  Rebuild the loser.
- **Nothing builds on a plain push/merge to `main`** — every platform is
  tag-gated, so docs/CI-only changes never spend a build. Builds happen only
  when you push the `ios/…` `tvos/…` `visionos/…` tags (i.e. run the script).
- `ci_scripts/ci_post_clone.sh` runs for **every** workflow (fetches VLCKit +
  libmpv, writes secrets from the `TMDB_API_KEY` env var). It can branch on
  `CI_PRODUCT_PLATFORM` / `CI_WORKFLOW` if a platform ever needs different setup.
- **macOS is Apple Silicon only** (`ARCHS = arm64`) — Homebrew's libmpv has no
  x86_64 slice. An Intel Mac build would need a separately-built libmpv.
