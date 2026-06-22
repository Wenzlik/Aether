# Player stack rework — VLCKit → AVFoundation-first, capability-tiered (#476)

> **Branch:** `feature/video-engine-protocol` (long-lived; the whole #476 epic
> lands here and integrates later, in parallel with other work — **not** split
> into per-phase `staging` PRs).
> **Goal:** a GPL-free, App-Store-licensable playback stack for the iOS family
> (iOS/iPadOS/tvOS/visionOS), removing VLCKit. macOS keeps libmpv, out of scope.

## Why

VLCKit is an LGPL-over-GPL wrapper we don't hold the copyright to → an App Store
takedown risk. The replacement is AVFoundation-first with a capability-tiered
fallback: each title routes to the cheapest engine that can play it.

| Tier | Engine | Covers |
|---|---|---|
| 0 | **AVFoundation** | mp4/mov/m4v/HLS + H.264/HEVC/AAC. Default. SMB via the range proxy. |
| 1 | **Remux-to-fMP4 shim** | local/SMB MKV (etc.) wrapping Apple-decodable codecs → rewrite container, no re-encode → AVPlayer via the proxy. |
| 2 | **Server transcode** | codecs Apple can't decode (DTS/TrueHD/VC-1…) → Plex/Jellyfin/Emby remux/transcode. Already supported; just route here. |
| 3 | **libmpv-LGPL fallback** | local/SMB exotic codecs with no server. |

## Phase status

- **P1 — Player protocol.** ✅ `VideoEngine` protocol + `VideoEngineResolver` in
  AetherCore replace the `PlaybackEngine` enum. Lowest-tier-that-can-play
  routing; `AVFoundationEngine` (tier 0) + `VLCEngine` (tier 3) conformers.
- **P2 — SMB browse off VLCKit.** ✅ Dead VLCKit `SMBBrowser` removed; browsing
  is fully native (`SMBSession`/`SMBClient`). `import VLCKit` now lives in
  exactly one file (`VLCPlayerView`).
- **P4 — Tier 1 remux shim.** ⏳ **Reordered before P3** — building the remux
  fallback *first* means deleting VLCKit (P3) regresses nobody. **AetherCore
  pipeline complete** (pure-Swift, 46 tests): `EBMLReader` → `MatroskaDemuxer`
  (probe) → `MatroskaFrameReader` (clusters→samples) → `RemuxEngine` (tier-1
  routing on codec decodability) → `MP4Box`/`FragmentedMP4Writer` (ftyp/moov/
  moof/mdat) → `MatroskaRemuxer` (end-to-end MKV→fMP4). Supports H.264/HEVC +
  AAC; samples pass through (no transcode). **Remaining: iOS integration** —
  `SMBRangeProxy` remux mode (serve the fMP4 over HTTP range), `DetailView`
  async probe → fill `MediaDescriptor` codecs → route to `.remux`, and
  on-device validation on a corpus of real rips. See below.
- **P3 — Delete VLCKit + ship App-Store-viable cut.** After P4 lands.
- **P5 — libmpv-LGPL port** (iOS/iPadOS full, tvOS focus-engine UI, visionOS
  windowed-fallback only — **never** the immersive/Cinema/spatial path).
- **P6 — Subtitle conversion.** ⏳ SRT (`S_TEXT/UTF8`) tracks are repackaged as
  a WebVTT-in-ISOBMFF (`wvtt`) track so AVPlayer shows a subtitle menu. Pure
  Swift, no burn-in. **Design:** subtitles ride in ONE eager media segment right
  after the init segment (their cues span the whole movie, the data is tiny),
  *not* fragmented per cluster — per-cluster WebVTT would break the analytic
  stream index (segment sizes come from frame bytes alone, but a WebVTT sample's
  size depends on its cue text + `vtte` gap-fillers). `WebVTTSampleBuilder` tiles
  the timeline with cue (`vttc`→`payl`) and empty (`vtte`) samples; SRT is
  non-overlapping, overlaps clamp. Image subs (PGS/VobSub) + ASS are dropped (not
  remuxed) — playback still works. Unit-tested end to end (`RemuxByteReader`, the
  resource-loader path, serves it too). **Remaining gate: on-device/sim
  validation on a real SRT-bearing rip** (RemuxValidate already reports the
  `.legible` selection group) before flipping `player.remuxLocalMKV` ON.

---

## P4 — Tier 1 remux shim (design)

### What it must do

Two responsibilities behind a single `RemuxEngine` (tier 1) conformer:

1. **Probe / demux.** Parse the container (MKV/EBML first) → track list, codecs,
   timestamps, sample positions. Needed because **SMB files carry no codec
   metadata before playback** — only Plex/Jellyfin downloads do (`MediaInfo.codec`).
   So Tier 1 routing is codec-aware where we have metadata, and **probe-on-open**
   where we don't (read the header over the existing `SMBSession`/proxy).
2. **Remux.** Wrap the *elementary streams* into fragmented MP4 (no re-encode),
   served seekably over the existing `SMBRangeProxy` localhost HTTP pattern, so
   `AVPlayer` plays it with PiP/AirPlay. Only valid when **every** track is a
   codec AVFoundation decodes (H.264/HEVC/AAC/AC-3…); otherwise fall through to
   Tier 2 (server) or Tier 3 (libmpv).

### How it plugs into the existing seam

- `RemuxEngine.canPlay(_:)` returns true only for unsupported containers whose
  codecs are Apple-decodable. This needs **codec info in `MediaDescriptor`** —
  extend it with optional `videoCodec` / `audioCodecs`, populated from
  `MediaInfo` (Plex) or the probe (SMB). When codecs are unknown, Tier 1 can't
  promise playback at routing time → it commits only after the probe.
- Output flows through `SMBRangeProxy`'s pattern (a `127.0.0.1` HTTP range
  server). The proxy gains a "remuxing entry" mode: byte ranges map onto
  generated fMP4 boxes + repackaged samples instead of raw passthrough.
- Lives in the **app target** (it's a player/proxy concern, like the proxy
  itself), with any pure parsing logic factored into AetherCore so it's testable.

### The decision — remux/demux core

This is a **new-dependency / new-module** call (AGENTS → architecture review).
Two ways to build the demux+mux core:

**Path A — LGPL FFmpeg (`libavformat`), remux-only xcframework.**
Build a trimmed FFmpeg (`--disable-gpl --disable-nonfree --disable-decoders
--disable-encoders`, keep demuxers/muxers/parsers) as an LGPL xcframework for
iOS/tvOS/visionOS (device+sim).
- ➕ Battle-tested demux/mux across MKV/AVI/TS/… incl. timestamp/lacing/A-V-sync
  edge cases. **Reuses the exact xcframework toolchain P5 (libmpv) needs anyway**
  — build the LGPL FFmpeg once, serve both P4 and P5.
- ➖ Stand up the cross-platform LGPL build pipeline now; ~3–8 MB/arch; C module
  map (like `Cmpv`); ours to maintain + security-patch; LGPL relink-compliance
  (publish build scripts/object files).

**Path B — Pure-Swift EBML demuxer + fMP4 muxer.**
Hand-write Matroska (EBML) parsing + ISOBMFF fragmented-MP4 muxing in Swift.
- ➕ Zero new binary, zero build pipeline, no LGPL relink burden, smallest app,
  fully `Sendable`/unit-testable Swift. Ships the SMB-MKV fix without a C
  toolchain. MKV is ~95% of real-world "unsupported container" rips.
- ➖ Substantial careful code (EBML, SimpleBlock/BlockGroup, lacing, timestamp
  scaling; fMP4 boxes; codec sample packaging — H.264 Annex-B→AVCC, HEVC hvcC,
  AAC ADTS→raw). MKV-first (AVI/TS later = more code). Largely **throwaway if P5
  libmpv lands** (libmpv demuxes natively) — though P4 ships value before P5.

**The crux:** is P5 (libmpv on the iOS family) a firm commitment?
- **Yes →** Path A amortizes one FFmpeg build across P4+P5.
- **Maybe / last-resort only →** Path B ships P4 leaner and faster, keeps the iOS
  family dependency-free, and defers the heavy C toolchain to if/when an exotic
  codec actually forces libmpv.

**Recommendation:** lean **Path B** unless libmpv is firmly committed. It fits
Aether's "prefer Apple frameworks, keep it small" philosophy, fixes the only
real regression (SMB/local MKV with Apple-decodable codecs) with no new binary,
and the remux shim *only ever helps codecs AVFoundation already decodes* — so a
focused Swift MKV→fMP4 packager is sufficient and the FFmpeg heavy lift is
genuinely only needed at Tier 3 (true decoding of exotic codecs).
