# Current Sprint

AI-facing snapshot of the current working focus. Update this whenever staging priorities materially change.

## Current Release Train

- Branch baseline: `staging`
- Marketing version: `0.7.8`
- Recent shipped scope: Emby connector (Quick Connect auth), new app icon, background performance fixes (VLC ticker / AVPlayer poll / image prefetch / resume loop), DetailView split (#241)

## Sprint Goal

Close the gap between "feature-complete for internal use" and "confident enough for broader external testing and release preparation."

## Active Issues

- visionOS playback ergonomics, especially player controls and dismissal behavior
- Release hardening across App Store / TestFlight / Xcode Cloud workflows
- Platform parity gaps between iOS-family targets, tvOS, visionOS, and macOS
- Localized titles and artwork language (#344, #345, #340)
- SMB + MKV playback latency (#347, #213)

## Features In Progress

- visionOS Cinema and playback polish
- macOS polish and release path improvements
- Localization tail (#320)
- DetailViewModel refactor (#241)

## Immediate Priorities

- Keep `staging` stable and releasable
- Avoid regressions in playback, watched state, resume, and navigation
- Verify platform-specific interaction details before declaring UX changes done
- Keep docs, changelog, and release notes aligned with shipped behavior

## Guardrails

- Prefer finishing and stabilizing existing work over opening broad new surface area
- Treat playback regressions as high severity
- Treat platform interaction mismatches as product issues, not polish-only issues
- Update docs when product behavior or architecture meaningfully changes
