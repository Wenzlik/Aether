# Releasing Aether for macOS (Developer ID + web DMG)

macOS ships **differently** from iOS/tvOS/visionOS. Those go through Xcode Cloud →
TestFlight/App Store (tag-gated — see [RELEASING.md](RELEASING.md)). macOS does
**not**: the player bundles **libmpv + FFmpeg (GPL)**, which the Mac App Store
can't host (same reason VLC/IINA aren't there). So macOS is distributed as a
**Developer ID-signed, notarized DMG**, downloaded from the website.

The whole thing is two commands once set up:

```sh
scripts/package-mac.sh     # build → sign (Developer ID) → notarize → staple → DMG
scripts/deploy-dmg.sh      # upload the DMG to the website + verify it's live
```

Output: `build/Aether-<version>.dmg`, then live at
`https://aetherplayer.com/downloads/Aether-<version>.dmg`.

---

## One-time setup (per machine)

You need all of these on the Mac you build from.

### 1. Toolchain + engine
- **Xcode** with the **macOS 26 SDK** (the app targets macOS 26). The scripts
  default `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` —
  override the env var if your Xcode is elsewhere.
- **XcodeGen**: `brew install xcodegen` (the `.xcodeproj` is generated from
  `project.yml`; `package-mac.sh` runs `xcodegen generate`).
- **libmpv + dylibbundler** (the macOS player engine + the tool that bundles it
  into the .app): `bash scripts/fetch_mpv.sh` (or `brew install mpv dylibbundler`).
- **VLCKit**: `bash scripts/fetch_vlckit.sh`. macOS doesn't *use* VLCKit, but it's
  a project-level SPM binaryTarget (iOS links it), so SwiftPM won't resolve the
  package graph without the xcframework present — even for the AetherMac scheme.

### 2. Signing — Developer ID Application certificate
Xcode ▸ Settings ▸ Accounts ▸ (your Apple ID) ▸ **Manage Certificates** ▸ **+** ▸
**Developer ID Application**. Confirm with:
```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
# → "Developer ID Application: Vaclav Zmrhal (8PW5FWH7P2)"
```
(No provisioning profile is needed — Developer ID apps don't use one. That's also
why the app carries **no iCloud entitlement**: iCloud is App-Store-only and can't
be Developer-ID signed.)

### 3. Notarization credentials — pick one

**(a) App Store Connect API key — recommended.** A `.p8` key file is immune to the
keychain-profile problem below (it has no keychain ACL, so an Xcode-beta update
can't make it "disappear"), and it works headless / in CI / on a second Mac.

1. App Store Connect ▸ **Users and Access** ▸ **Integrations** ▸ **App Store
   Connect API** ▸ generate a key (a **Developer** role is enough for notarizing).
2. **Download `AuthKey_<KEYID>.p8`** — you only get one chance; store it somewhere
   safe (e.g. `~/.private_keys/`), never commit it.
3. Note the key's **Key ID** and the **Issuer ID** (shown at the top of that page).
4. Point the script at it (e.g. in your shell profile):
   ```sh
   export NOTARY_API_KEY=~/.private_keys/AuthKey_XXXXXXXXXX.p8
   export NOTARY_API_KEY_ID=XXXXXXXXXX
   export NOTARY_API_ISSUER=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
   ```
   When all three are set, `package-mac.sh` notarizes with the key; otherwise it
   falls back to the keychain profile (b).

**(b) Keychain profile — fallback.** Generate an **app-specific password** at
[appleid.apple.com](https://appleid.apple.com) ▸ Sign-In & Security, then store it:
```sh
xcrun notarytool store-credentials aether-notary \
  --apple-id "vasek@zmrhal.cz" --team-id 8PW5FWH7P2
# (omit --password and it prompts, so it stays out of shell history)
```
The profile name **`aether-notary`** is what `package-mac.sh` defaults to. ⚠️ This
profile's keychain item is ACL-bound to the `notarytool` binary, so a new
**Xcode-beta** breaks access ("No Keychain password item found for profile…") and
you must re-run `store-credentials`. Prefer (a) to avoid this entirely.

### 4. NAS access for deploy (SSH key)
The website lives on the Synology at `192.168.1.10` (SSH **port 5002**, user
`venda`), web root `/volume1/web/aether`. **You must be on its LAN — via VPN if
you're off-site.**

Either copy an existing key, or create one and install it (password auth, once):
```sh
ssh-keygen -t ed25519 -N "" -f ~/.ssh/aether_synology -C "aether-deploy"
# install the public key (you'll be asked for venda's password once):
ssh -p 5002 -o PubkeyAuthentication=no venda@192.168.1.10 \
  "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys" < ~/.ssh/aether_synology.pub
# verify keyless:
ssh -i ~/.ssh/aether_synology -p 5002 venda@192.168.1.10 'echo OK'
```
`deploy-dmg.sh` uses `~/.ssh/aether_synology` by default (override with `SSH_KEY`,
`NAS_HOST`, `NAS_PORT`, `NAS_USER`, `WEB_ROOT`, `SITE_URL`). It uploads by piping
through the login shell (`ssh 'cat > …'`) because the NAS's SFTP/scp is chrooted
to the home dir and can't reach `/volume1/web`. It also uploads `appcast.xml`
(see below) to the web root.

### 5. Sparkle auto-update — tools + signing key (#405)
The app self-updates from the website via **Sparkle**. Each update is EdDSA-signed;
the public half is baked into the build (`SUPublicEDKey` in `project.yml`), the
private half lives in **your login Keychain** (account `ed25519`).

- **CLI tools** (not part of the SPM package): `bash scripts/fetch-sparkle-tools.sh`
  — downloads the official Sparkle release tarball and drops `generate_keys` /
  `sign_update` / `generate_appcast` in `Vendor/Sparkle/bin` (gitignored). The
  release scripts call `sign_update` from there.
- **Signing key — already generated once.** `generate_keys` created the EdDSA key
  pair; the public key is in `project.yml` (`SUPublicEDKey`). **Do not regenerate
  it** — a new key would orphan every installed copy (they only trust the baked-in
  public key). To confirm it's present: `Vendor/Sparkle/bin/generate_keys -p`
  should print the same public key that's in `project.yml`.
- **First signing prompts once.** `package-mac.sh` signs via the Keychain; the
  first run in a Terminal session shows a macOS prompt to allow `sign_update` to
  read the key — click **Always Allow**.
- **Second Mac / CI** (no Keychain key): export the key from this Mac with
  `Vendor/Sparkle/bin/generate_keys -x sparkle-private-key.txt` (a secret — never
  commit it), copy it across securely, then either import it
  (`generate_keys -f sparkle-private-key.txt`) or point the release at the file:
  `SPARKLE_ED_KEY_FILE=…/sparkle-private-key.txt scripts/package-mac.sh`.

---

## Cutting a release

1. **Bump the version** in `project.yml` → `MARKETING_VERSION` (e.g. `0.7.4`).
   The build number is set automatically from the date by `package-mac.sh`.
2. **⚠️ Verify the macOS build compiles FIRST** — before the (slow) notarized
   package. **Xcode Cloud does not build the `AetherMac` target** (see "Why no
   Xcode Cloud" below), so macOS-only compile errors reach `main` undetected and
   only surface when you archive. This has bitten two releases running — 0.7.6
   (`MacTheme` vs `AetherMacTheme`) and 0.7.7 (Discover hero `MediaItem` vs
   `UnifiedMediaItem`). The verify build fails in ~1 min instead of after a full
   archive + notarize wait:
   ```sh
   export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
   xcodebuild -project Aether.xcodeproj -scheme AetherMac \
     -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
     -derivedDataPath /tmp/aether-verify build      # expect: ** BUILD SUCCEEDED **
   ```
   If it fails, fix on a branch → PR to `staging` (never commit to `main`), then
   build the DMG from that branch so the stamped `AetherGitCommit` is real.
3. **Build the DMG**:
   ```sh
   scripts/package-mac.sh
   ```
   Steps it runs: `xcodegen generate` → `xcodebuild archive` (Release; the
   post-build phase bundles libmpv's dylib tree into the .app and re-signs it
   with your Developer ID) → export (Developer ID) → notarize the **app** + staple
   → build the DMG → notarize the **DMG** + staple → **EdDSA-sign the DMG and write
   `build/appcast/appcast.xml`** (Sparkle, #405). Notarization waits on Apple
   (a few minutes). Result: `build/Aether-<version>.dmg` + the appcast. The script
   **fails** if it can't sign the update (so it never ships a silently unsigned
   appcast that clients would reject).
4. **Deploy the DMG** (on the LAN/VPN):
   ```sh
   scripts/deploy-dmg.sh                       # newest build/Aether-*.dmg
   # or: scripts/deploy-dmg.sh build/Aether-0.7.4.dmg
   ```
   Uploads the DMG to `web/aether/downloads/`, checks the sha256 local-vs-remote,
   curls the public URL, **and uploads `appcast.xml` to the web root** so running
   copies see the update (Sparkle polls `https://aetherplayer.com/appcast.xml`).
5. **Bump the version on the website** — the download page is a **Next.js
   component**, not static HTML (see "The website" below). In the
   **`aether_web`** repo (`/Users/vasek/Git/aether_web`):
   - `components/DownloadContent.tsx` → `const VERSION = "0.7.x"` (single source:
     drives the DMG link, the button label, and the "What's new in" heading).
   - `lib/i18n.ts` → the `latest:` "Latest release" line **and** the `whatsNew`
     items, in **all three** locales (`en` / `cs` / `uk` — the build fails if a
     locale is missing a key).
   - Then `npm run deploy` (= `next build` + `scripts/deploy.sh`). See
     `aether_web/docs/DEPLOY.md` for that repo's full runbook.

   ⚠️ **Same-version rebuild?** If you re-ship without bumping `MARKETING_VERSION`,
   the DMG filename is unchanged, so browsers/CDN may serve a stale copy. Confirm
   a fresh download via **Settings → About → Build** (matches the shipped commit),
   or add `?b=<commit>` cache-busting to the download link.

### Verify
```sh
# Gatekeeper accepts the app (notarized):
hdiutil attach build/Aether-<version>.dmg -nobrowse -readonly
spctl -a -vv "/Volumes/Aether <version>/Aether.app"   # → accepted, Notarized Developer ID
# public download:
curl -sI https://aetherplayer.com/downloads/Aether-<version>.dmg | head -1   # → 200
```
(`spctl -a -t open` on the *DMG itself* says "rejected/no usable signature" — that's
normal; DMGs are notarized+stapled, not Developer-ID *signed*. The stapled ticket
is what Gatekeeper checks on a quarantined download. The app assessment is the
real test.)

Also confirm the appcast is live and points at this release:
```sh
curl -s https://aetherplayer.com/appcast.xml | grep -E "shortVersionString|enclosure"
# → <sparkle:shortVersionString>0.7.x</sparkle:shortVersionString>
# → <enclosure url=".../Aether-0.7.x.dmg" … sparkle:edSignature="…"/>
```

---

## Auto-update (Sparkle, #405)

Running copies update themselves — no need to re-download from the site. The app
polls `SUFeedURL` (`https://aetherplayer.com/appcast.xml`), and when the appcast's
`sparkle:version` (the build number) is higher than the running build, Sparkle
offers the update, downloads the DMG, verifies its EdDSA signature against the
baked-in `SUPublicEDKey`, installs it, and relaunches.

- **It keys off the build number, not the marketing version** — so even a
  same-version re-ship (e.g. another `0.7.7`) is correctly offered, because
  `package-mac.sh` stamps a higher date-derived `CURRENT_PROJECT_VERSION`. This
  retires the "same DMG filename is cached" worry for auto-updating users (a fresh
  manual download from the site can still be cached — that caveat stays for the
  website only).
- **Both scripts handle it automatically:** `package-mac.sh` signs + writes the
  appcast; `deploy-dmg.sh` uploads it. No manual step.
- **The signing key is the one secret that matters.** It's in your login Keychain
  (and only there). Back it up (`generate_keys -x`) — if it's ever lost you must
  ship a new public key, which breaks auto-update for everyone already on an old
  build (they'd have to re-download manually once). See One-time setup §5.
- **Test an update end-to-end** by installing an older build, then releasing a
  newer one: the older copy should prompt within a day (or immediately via
  Settings ▸ About ▸ Check for Updates…).

---

## The website

- Served from the Synology `web` share, vhost root = `web/aether` → `aetherplayer.com`.
- **The entire site is a Next.js app**, repo **`aether_web`** at
  `/Users/vasek/Git/aether_web` (Wenzlik/aether_web). It's a static export
  (`output: "export"`) deployed with `npm run deploy`. **Clone that repo on any
  machine you publish from** — the whole site, including `/download/`, is
  generated from it; do **not** hand-edit the deployed HTML (React re-renders it
  on hydration and your change disappears).
- **Download page**: `app/[locale]/download` + `components/DownloadContent.tsx`
  → https://aetherplayer.com/download/ (and `/cs/download/`, `/uk/download/`).
- **DMGs**: `web/aether/downloads/Aether-<version>.dmg` — uploaded by
  `scripts/deploy-dmg.sh` from *this* repo, independent of the site rebuild.
- The version shown on the site is the `VERSION` constant in
  `components/DownloadContent.tsx`; copy (incl. the "Latest release" line and the
  "What's new" items) lives in `lib/i18n.ts` across `en` / `cs` / `uk`. See
  `aether_web/docs/DEPLOY.md` for the website's own runbook (SSH, atomic swap,
  signup endpoint).

## Why no Xcode Cloud for macOS
A `macos/…` tag + Xcode Cloud workflow exists, but it's **not** the distribution
path: the Cloud archive signs ad-hoc (can't carry entitlements / isn't Developer
ID) and the App Store can't host the GPL engine anyway. Build macOS locally with
the scripts above.
