# AGENTS.md — guide for AI contributors

This file is the contract between Aether and any AI coding agent working on it. It is read by **Claude Code**, **OpenAI Codex**, **Google Gemini**, **GitHub Copilot**, **Cursor**, and any future agent that opens this repository.

If you are an AI agent: read this file in full before making changes. If you are a human: this is also a useful onboarding doc.

---

## Fast read order

When you open this repo cold, read in this order. It will take ~5 minutes and will save hours of guessing.

1. [`README.md`](README.md) — product framing
2. `AGENTS.md` *(this file)* — how we work
3. [`ROADMAP.md`](ROADMAP.md) — what we are building, in order; status legend at the top
4. [`CHANGELOG.md`](CHANGELOG.md) — what's actually landed (the `[Unreleased]` block is what to read)
5. [`docs/product/PRODUCT_SPEC.md`](docs/product/PRODUCT_SPEC.md) — audience, scope, non-goals
6. [`docs/architecture/ARCHITECTURE.md`](docs/architecture/ARCHITECTURE.md) — module layout
7. [`docs/ux/DESIGN_PRINCIPLES.md`](docs/ux/DESIGN_PRINCIPLES.md) — visual language and the `Aether*` component naming convention
8. [`docs/next-steps/`](docs/next-steps/) — the current milestone plan (`0.2-media-sources.md` is in flight; `0.3-offline.md` is queued). `0.1-foundation.md` is closed and kept for context.

Only after this should you open Swift files.

### Current state in one paragraph

`0.1 Foundation` is shipped. `0.2 Media Sources` is **in flight**: Plex is end-to-end (PIN sign-in → server discovery with off-LAN failover → libraries → direct-play streams + transcode fallback → show / season / episode drill-down → native `AVPlayerViewController` with auto-hiding chrome). Settings + Sign Out land in the polish sprint that closes the Plex side. Synology connector, persistent SwiftData-backed `ResumeStore`, and the upgraded artwork pipeline are the remaining 0.2 work. `0.3 Offline` is queued behind that.

---

## Repository philosophy

Aether is a small, opinionated product. It is **not** a kitchen-sink media center. Every change should make the product feel more like a premium Apple-platform app, or it should not land.

- **Docs change before implementation.** If a change alters architecture, behavior, or UX, update the relevant doc in the same PR (or in a doc-only PR that lands first).
- **Prefer Apple frameworks.** SwiftUI, AVKit, URLSession, Core Data / SwiftData, Combine where it fits. Reach for third-party only when Apple cannot reasonably do the job.
- **Keep Aether Apple-native.** No cross-platform UI toolkits. No web views for primary UI.
- **Avoid unnecessary abstraction.** Three concrete call sites is not a pattern. Wait for the fourth.
- **One feature per branch.** Don't bundle a refactor with a feature with a docs change.
- **Every PR must explain why.** "What" is in the diff. "Why" goes in the description.
- **No Plex or Synology branding in the app name or icon.** Aether is its own product.

These rules are non-negotiable. If you find yourself wanting to break one, raise it in a PR comment first.

---

## Architecture rules

The high-level shape is documented in [`docs/architecture/ARCHITECTURE.md`](docs/architecture/ARCHITECTURE.md). The rules an agent must respect:

- **App target stays thin.** `Aether/` is SwiftUI views, navigation, and platform glue. No networking, no parsing, no playback logic.
- **`AetherCore` is the brain.** Models, media sources, playback session, downloads, persistence, design tokens.
- **One module per concern.** `MediaSources/Plex`, `MediaSources/Synology`, `Playback`, `Downloads`, `Storage`, `DesignSystem`, `Models`. Don't add a new folder unless you can name a clear concern.
- **Models are value types.** Reach for `struct`. Use `class` only when reference semantics or identity actually matter.
- **Side effects live in actors or services.** Networking, file I/O, playback state — all behind an `actor` or a clearly named service type.
- **No singletons.** Inject dependencies via initializers or the SwiftUI environment.
- **Cross-platform first.** If a type belongs in `AetherCore`, it must compile on both iOS and tvOS. Platform-specific code goes in the app target, gated by `#if os(...)`.

---

## Swift style

- **Swift 6**, strict concurrency, `Sendable` everywhere it should be.
- **async/await first.** No completion handlers in new code. No `DispatchQueue` for app-level work.
- **`actor` for shared mutable state.** Not locks, not serial queues.
- **`@MainActor` only on UI types** and the seams that touch them — not as a blanket "make warnings go away."
- **Naming:** Apple's API Design Guidelines. Types are nouns. Methods are verbs. Booleans read like assertions. No Hungarian prefixes.
- **Files:** one primary type per file, file named after the type.
- **Indentation:** 4 spaces. Trailing commas where Swift allows them. Line length is soft — readability wins.
- **Tests** live in `AetherTests/`, mirror the source tree, and use the new Swift Testing framework (`import Testing`).
- **No force-unwraps in shipping code.** `try!` is allowed only in tests and previews.

---

## Design system (`Aether*`)

Every reusable view primitive lives in `AetherCore/Sources/AetherCore/DesignSystem/` and is named with the `Aether*` prefix. Reach for these before composing a new one.

| Primitive | Purpose |
|---|---|
| `AetherCard` + `.poster` / `.hero` / `.episode` factories | Posters (2:3), hero featured cards (16:9 with optional subtitle), episode stills (16:9 with progress overlay). |
| `AetherSectionHeader` | Title row above every horizontal rail. |
| `AetherButton` (`.primary` / `.secondary` / `.destructive`) | The one button. Three roles, one shape, one focus motion. |
| `AetherEmptyState` | Designed glyph + title + body + optional CTA. Used wherever a screen would have stubbed `"No items."`. |
| `AetherLoadingState` (`.rails(count:)` / `.inline`) | Skeleton rails or inline pulse — never a spinner. |
| `AetherErrorState` | Same shape as `AetherEmptyState`, with a required retry. |
| `AetherSettingsRow` + `AetherSettingsSection` | Settings list primitives — calm, factual, no `Form` chrome. |
| `BackdropImage`, `CachedAsyncImage` | Full-bleed Detail backdrops and any image that should later flow through the artwork pipeline (kept their original names; not user-facing primitives). |

If you find yourself building a one-off empty / loading / error / button / card surface in a view, **extend the primitive instead**. A second variant of `AetherButton` is cheaper than two near-identical bespoke buttons drifting apart over time.

Tokens (spacing, radii, motion, palette, typography) live in `DesignSystem/Tokens.swift` under the `AetherDesign.*` namespace. Never hard-code a value in a view — pull from `AetherDesign.Spacing.l`, `AetherDesign.Typography.heroTitle`, etc.

---

## Settings + sign out

The Settings surface is reachable from the gear icon in `HomeView`'s header. On every platform it presents as a `.sheet` (full-screen modal on tvOS / visionOS — acceptable here because it's a single-purpose destination with a clear dismiss).

- `SettingsView` is composed entirely from `AetherSettingsSection` + `AetherSettingsRow`. Adding a new section is a copy-paste of an existing one with new content.
- `SettingsViewModel` is `@Observable @MainActor` and derives its state from `AppSession`. The only behavior it owns is `signOut()`, which delegates to `session.signOutOfPlex()` and then flips `session.isSettingsPresented = false`.
- **Sign Out of Plex is the only destructive action in the app today.** It clears the keychain token, drops the persisted server, resets discovery state, and points `source` back to `nil` (Home renders its welcome state without a mock fallback). Adding another destructive action is a design discussion — open an issue with the `ux` label first.

The version + build strings come from `Bundle.main.infoDictionary["CFBundleShortVersionString"]` and `"CFBundleVersion"`. The source of truth is `project.yml` — bump them there.

---

## Player chrome behavior

The player wraps `AVPlayerViewController` (`SystemVideoPlayer`). Its native transport bar auto-hides after ~3 s of no interaction; the overlay `xmark` close button on iOS / visionOS mirrors that behavior on the same idle window via a `simultaneousGesture` so the SwiftUI tap doesn't consume AVKit's tap-to-reveal-chrome. `accessibilityReduceMotion` collapses the fade.

On tvOS the dismiss surface is a `Done` `contextualAction` inside the native chrome (tvOS-only API) plus `.onExitCommand` for the Menu button. There is no SwiftUI overlay on tvOS — adding one would fight the focus model.

When `PlayerView` is overlaid on `DetailView`, the host `NavigationStack`'s back button is hidden via `.toolbar(.hidden, for: .navigationBar)` so it doesn't compete with the transport.

---

## UI philosophy

Anything that draws a pixel must respect [`docs/ux/DESIGN_PRINCIPLES.md`](docs/ux/DESIGN_PRINCIPLES.md). The short version:

- **Typography-first hierarchy.** Type and spacing carry weight before color does.
- **Cinematic artwork.** Posters, backdrops, and stills are the loudest things on screen.
- **Minimal chrome.** Hide what isn't needed. Reveal on intent.
- **Restrained color.** A small accent palette, lots of grayscale, real blacks on OLED.
- **Soft depth.** Materials, subtle shadows, no hard cards.
- **Calm motion.** Spring animations, no bouncy excess, no spinners where a skeleton would do.
- **No bespoke design language fighting Apple.** Use system fonts, system materials, system focus.

---

## tvOS rules

tvOS is the platform Aether is judged on. It must feel like an Apple app, not a port.

- **Focus engine is sacred.** Use `.focusable`, `.focusSection`, and `@FocusState` correctly. Never re-implement focus with gesture hacks.
- **No tap gestures pretending to be focus.** The Siri Remote is the cursor.
- **Top shelf** ships once we have real content. Stub it explicitly until then.
- **Type sizes scale up.** tvOS is read from a couch. Don't ship iOS body type.
- **Test on a real Apple TV before claiming "done."** The simulator hides motion and focus issues.
- **Avoid modals** on tvOS where a focus push will do.

---

## Playback philosophy

- **AVPlayer is the foundation.** No custom decoders.
- **One playback session at a time.** Owned by an actor (`PlaybackSession`), surfaced via a `@MainActor` view model.
- **No UI in `Playback/`.** Playback is a service. Player UI lives in the app target.
- **Resume points are sacred.** Every started playback writes resume state; every detail screen reads it.
- **Network-aware.** Detect Wi-Fi vs cellular, adapt bitrate hints, never silently burn cellular data.
- **AirPlay and PiP are first-class** on iOS/iPadOS. tvOS has its own playback rules.
- **Transcoding is a Plex concern.** Aether requests; the server decides. Direct play on Synology when the codec is supported.

---

## Download architecture philosophy

- **Background `URLSession`** for resumable downloads. Never foreground-only.
- **Single source of truth** for download state lives in `Downloads/`. Views observe; they do not mutate.
- **Disk budget is explicit.** The user chooses a cap; the manager respects it.
- **Sandboxed paths only.** Use the app's documents/caches directory; never absolute paths.
- **Encrypt nothing locally** unless the server requires it — these are the user's files on the user's device.
- **Offline = first-class.** If a title is downloaded, it must play with the network completely off. This is tested.

---

## Xcode project gotcha — always regenerate after pulling

`Aether.xcodeproj` is **not** checked in. The Xcode project is generated by `xcodegen generate` from `project.yml`, which scans `Aether/Sources/` recursively and bundles every `.swift` file it finds. New files only appear in the project file **at the moment `xcodegen generate` runs**.

This means: **every time you pull a branch that adds files in `Aether/Sources/`, you must run `xcodegen generate` again** before opening Xcode (or, if Xcode is open, close and reopen the project after running it).

If you see errors like `Cannot find 'SomeView' in scope` after a pull, and the file is on disk, the fix is almost always:

```bash
xcodegen generate
```

The same gotcha applies to `AetherCore/Sources/AetherCore/`, but to a lesser extent: SwiftPM rediscovers files automatically when Xcode resolves the package, so it's mostly self-correcting.

### Test target needs `GENERATE_INFOPLIST_FILE: YES`

The `AetherTests` target in `project.yml` carries `GENERATE_INFOPLIST_FILE: YES` under `settings.base`. Without it, Xcode 26+ refuses to link the test bundle with `error: Cannot code sign because the target does not have an Info.plist file`. Don't remove it.

### `AppSession.init` accepts a keychain for tests

`AppSession.init(keychain:api:)` defaults to a `KeychainStore()` with the production service prefix `cz.zmrhal.aether`. Tests pass `KeychainStore(service: "cz.zmrhal.aether.tests.<uuid>")` so they don't touch the user's real keychain. New tests that need to round-trip sign-in / sign-out state should follow that pattern (see `AetherTests/AppSessionTests.swift` and `AetherTests/SettingsViewModelTests.swift`).

---

## Documentation workflow

- **Every meaningful change updates docs.** New surface → `PRODUCT_SPEC.md`. New module → `ARCHITECTURE.md`. New visual pattern → `DESIGN_PRINCIPLES.md`. New milestone → `ROADMAP.md` and `docs/next-steps/`.
- **`CHANGELOG.md` is updated in every PR**, under `## [Unreleased]`, before release.
- **`docs/next-steps/<milestone>.md`** is a living plan. Edit it as scope shifts.
- **Doc-only PRs are encouraged** when an architectural decision deserves debate before code.

---

## Commit conventions

- **Imperative mood:** "Add Plex auth flow", not "Added" or "Adds".
- **Subject under 72 characters.** Body wraps at 72.
- **Body explains why.** What is in the diff.
- **One logical change per commit.** Refactors are separate commits from features.
- **Reference issues** in the body when relevant: `Refs #42`, `Closes #42`.
- **No noise commits** on `main`. Squash or rewrite on the branch before merging.

Example:

```
Add Plex authentication flow

Adds PIN-based PlexAuth actor and the SwiftUI sign-in surface in the
app target. Tokens are stored in the Keychain via Storage.KeychainStore.

Closes #14
```

---

## Branching strategy

- **`main`** is always shippable. Tags cut releases.
- **Feature branches:** `feature/<short-slug>` — one feature, one branch.
- **Fix branches:** `fix/<short-slug>`.
- **Docs branches:** `docs/<short-slug>`.
- **Spike branches:** `spike/<short-slug>` — explicitly disposable; never merged without follow-up work.
- **Rebase, don't merge.** Keep history linear on `main`.
- **No long-lived branches.** If a branch is open for a week, split it.

---

## What Claude Code should handle

- Multi-file architectural changes
- Documentation drafting and revising (`AGENTS.md`, `ARCHITECTURE.md`, `PRODUCT_SPEC.md`)
- New Swift modules in `AetherCore/` (Plex connector, Synology connector, Downloads, etc.)
- tvOS focus and SwiftUI navigation work
- Cross-cutting refactors that need a mental model of the whole repo
- Anything that requires reading several files before changing one

Claude Code is the agent of choice for "think first, then change a lot."

## What Codex should handle

- Tight, well-specified Swift tasks where the change is local
- Implementing a function whose signature and tests already exist
- Filling in `// TODO` blocks left by a higher-level plan
- Quick test additions and parameterizations
- Small, mechanical refactors with no architectural ambiguity

Codex is the agent of choice for "the design is decided; write the code."

## What Gemini should handle

- Large-context reviews (reading lots of files to spot inconsistencies)
- Whole-repo audits — naming consistency, doc/code drift, missing tests
- Brainstorming product or UX direction in `docs/`
- Long-form competitive analysis against Plex, Infuse, Apple TV app
- Reading external API references (Plex, Synology) and summarizing what matters for Aether

Gemini is the agent of choice for "read everything and tell me what's off."

> Copilot and Cursor are useful for inline edits while a human drives. They should follow the same Swift style and architecture rules but don't need a dedicated section — their scope is whatever the human in the editor decided.

---

## How issues should be written

Every GitHub issue should have:

1. **A noun-phrase title.** "Plex authentication" — not "implement plex auth".
2. **Context.** Why this exists, what user-facing outcome it enables.
3. **Scope.** Bulleted "in scope" and "out of scope" — be explicit about what is *not* this issue.
4. **Definition of done.** Concrete, observable signals: code, tests, docs updated, screenshot if UI.
5. **Labels.** One area label (`plex`, `synology`, `playback`, …) and at minimum one type label (`architecture`, `ux`, `documentation`, …).
6. **Milestone.** Tied to a `ROADMAP.md` milestone (`0.1`, `0.2`, …) when known.

Issues that don't meet this bar should be triaged: clarified, merged into another, or closed.

---

## How roadmap updates happen

- `ROADMAP.md` is the **promise**. It changes via PR, with a one-line reason in the description.
- Don't add speculative items. If it isn't going to land in the next two milestones, it goes in `docs/product/PRODUCT_SPEC.md` under "Future ideas" instead.
- Move an item between milestones by editing the file, not by leaving stale entries.
- When a milestone ships, prepend `✅ Shipped <date>` to its heading and start a new file in `docs/next-steps/` for the following one.

---

## Expectations for architecture discussions

- Before adding a new module, opening a new third-party dependency, or changing how data flows through the app, **open a doc-only PR or an issue with the `architecture` label.**
- The PR description should answer: what problem, what alternatives, why this one, what we give up.
- Architectural pushback is welcomed in line comments. Architectural debates that exceed three back-and-forths should move to a synchronous conversation and be resolved in `ARCHITECTURE.md`.
- "We can refactor later" is acceptable, but only if the PR describes the seam that makes the refactor cheap.

---

## When in doubt

Read [`README.md`](README.md) and [`docs/product/PRODUCT_SPEC.md`](docs/product/PRODUCT_SPEC.md) again. If your change does not make Aether feel more like a premium Apple-platform media player, it probably belongs in a different repo.
