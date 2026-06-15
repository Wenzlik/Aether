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

### 3. Notarization credentials (notarytool keychain profile)
Generate an **app-specific password** at [appleid.apple.com](https://appleid.apple.com)
▸ Sign-In & Security ▸ App-Specific Passwords. Then store it once:
```sh
xcrun notarytool store-credentials aether-notary \
  --apple-id "vasek@zmrhal.cz" --team-id 8PW5FWH7P2
# (omit --password and it prompts, so it stays out of shell history)
```
The profile name **`aether-notary`** is what `package-mac.sh` expects.

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
to the home dir and can't reach `/volume1/web`.

---

## Cutting a release

1. **Bump the version** in `project.yml` → `MARKETING_VERSION` (e.g. `0.7.4`).
   The build number is set automatically from the date by `package-mac.sh`.
2. **Build the DMG**:
   ```sh
   scripts/package-mac.sh
   ```
   Steps it runs: `xcodegen generate` → `xcodebuild archive` (Release; the
   post-build phase bundles libmpv's dylib tree into the .app and re-signs it
   with your Developer ID) → export (Developer ID) → notarize the **app** + staple
   → build the DMG → notarize the **DMG** + staple. Notarization waits on Apple
   (a few minutes). Result: `build/Aether-<version>.dmg`.
3. **Deploy to the web** (on the LAN/VPN):
   ```sh
   scripts/deploy-dmg.sh                       # newest build/Aether-*.dmg
   # or: scripts/deploy-dmg.sh build/Aether-0.7.4.dmg
   ```
   Uploads to `web/aether/downloads/`, checks the sha256 local-vs-remote, and
   curls the public URL.
4. **Update the download page version** — `web/aether/download/index.html` (local
   working copy at `/Users/vasek/Git/aether-web`) hardcodes the DMG filename and
   the `· 0.7.3` label. Change both to the new version and re-deploy that file
   (e.g. copy it onto the SMB mount, or `ssh 'cat > /volume1/web/aether/download/index.html'`).

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

---

## The website

- Served from the Synology `web` share, vhost root = `web/aether` → `aetherplayer.com`.
- **Download page**: `web/aether/download/index.html` → https://aetherplayer.com/download/
- **DMGs**: `web/aether/downloads/Aether-<version>.dmg`
- The **`/download/` page is plain static HTML** (not Next.js) — it renders fine
  and is safe to edit/deploy directly in the export.
- ⚠️ **The homepage download link must go in the Next.js SOURCE, not the export.**
  The homepage is a hydrated Next.js page: editing the deployed `index.html`
  (and `cs/`, `uk/`) to add a link "works" in the raw HTML but React **removes it
  on hydration** (it re-renders nav/hero from its component tree). So add it in
  the homepage component and rebuild. The source is **not in this repo** (it's on
  a separate machine; put it in git). What to add — a link in the nav and a hero
  button, e.g.:
  ```tsx
  <Link href="/download/" className="rounded-full px-3 py-1.5 text-sm font-medium text-white/70 hover:text-white">Download</Link>
  // and a secondary hero button next to "Join the Beta":
  <Link href="/download/" className="rounded-full px-8 py-3.5 font-medium text-white glass hover:opacity-85">Download for Mac</Link>
  ```
  Localize the label per locale (cs: "Stáhnout" / "Stáhnout pro Mac"; uk:
  "Завантажити" / "Завантажити для Mac"). Then `next build && next export` and
  redeploy. The `/download/` page + the DMG in `downloads/` are independent of
  the rebuild.

## Why no Xcode Cloud for macOS
A `macos/…` tag + Xcode Cloud workflow exists, but it's **not** the distribution
path: the Cloud archive signs ad-hoc (can't carry entitlements / isn't Developer
ID) and the App Store can't host the GPL engine anyway. Build macOS locally with
the scripts above.
