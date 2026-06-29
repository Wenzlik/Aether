# AGENTS.md — guide for AI contributors

This file is the contract between Aether and any AI coding agent working on it. It is read by **Claude Code**, **OpenAI Codex**, **Google Gemini**, **GitHub Copilot**, **Cursor**, and any future agent that opens this repository.

If you are an AI agent: read this file in full before making changes. If you are a human: this is also a useful onboarding doc.

---

## Fast read order

When you open this repo cold, read in this order. It will take ~5 minutes and will save hours of guessing.

1. [`README.md`](README.md) — product framing
2. `AGENTS.md` *(this file)* — how we work
3. [`docs/PROJECT_CONTEXT.md`](docs/PROJECT_CONTEXT.md) — persistent AI-safe project context
4. [`docs/CURRENT_SPRINT.md`](docs/CURRENT_SPRINT.md) — what matters right now
5. [`docs/ROADMAP.md`](docs/ROADMAP.md) — quick roadmap summary for AI sessions
6. [`ROADMAP.md`](ROADMAP.md) — full roadmap and status legend
7. [`CHANGELOG.md`](CHANGELOG.md) — what's actually landed (read `[Unreleased]` and the latest shipped version)
8. [`docs/product/PRODUCT_SPEC.md`](docs/product/PRODUCT_SPEC.md) — audience, scope, non-goals
9. [`docs/architecture/ARCHITECTURE.md`](docs/architecture/ARCHITECTURE.md) — module layout
10. [`docs/ux/DESIGN_PRINCIPLES.md`](docs/ux/DESIGN_PRINCIPLES.md) — visual language and the `Aether*` component naming convention
11. [`docs/next-steps/`](docs/next-steps/) — milestone-specific plans and design work

Only after this should you open Swift files.

### Current state in one paragraph

The product is well past the early connector milestones and is shipping `0.8.0` ("Eridanus"). Aether now ships a unified multi-source media experience across iOS, iPadOS, tvOS, visionOS, and macOS, with Plex multi-server support, Jellyfin, Emby, Local Library, SMB, downloads, cross-device resume, and visionOS Cinema Mode. The main day-to-day focus is no longer "can the feature exist?" but "is it stable, premium, and release-ready across every platform?".

---

## AI team system

Aether now carries a lightweight specialized-agent system for AI sessions that need narrower context and clearer role boundaries.

### Shared AI docs

- [`docs/PROJECT_CONTEXT.md`](docs/PROJECT_CONTEXT.md) — stable project knowledge
- [`docs/CURRENT_SPRINT.md`](docs/CURRENT_SPRINT.md) — current working focus
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — AI-friendly roadmap summary
- [`docs/ai/`](docs/ai/) — role files for specialized agents

### Slash-command role index

- `/design` → [`docs/ai/product-designer.md`](docs/ai/product-designer.md)
- `/engineer` → [`docs/ai/senior-engineer.md`](docs/ai/senior-engineer.md)
- `/qa` → [`docs/ai/qa-lead.md`](docs/ai/qa-lead.md)
- `/perf` → [`docs/ai/performance-engineer.md`](docs/ai/performance-engineer.md)
- `/pm` → [`docs/ai/product-manager.md`](docs/ai/product-manager.md)
- `/release` → [`docs/ai/release-manager.md`](docs/ai/release-manager.md)
- `/triage` → [`docs/ai/github-triage.md`](docs/ai/github-triage.md)
- `/visionos` → [`docs/ai/visionos-specialist.md`](docs/ai/visionos-specialist.md)
- `/tvos` → [`docs/ai/tvos-specialist.md`](docs/ai/tvos-specialist.md)
- `/review` → [`docs/ai/app-store-reviewer.md`](docs/ai/app-store-reviewer.md)
- `/docs` → [`docs/ai/technical-writer.md`](docs/ai/technical-writer.md)
- `/marketing` → [`docs/ai/marketing-lead.md`](docs/ai/marketing-lead.md)
- `/architect` → [`docs/ai/chief-architect.md`](docs/ai/chief-architect.md)

### Required AI session flow

Every new AI session should:

1. Read [`docs/PROJECT_CONTEXT.md`](docs/PROJECT_CONTEXT.md)
2. Read [`docs/CURRENT_SPRINT.md`](docs/CURRENT_SPRINT.md)
3. Load the requested role from [`docs/ai/`](docs/ai/)
4. Stay within that role's responsibilities before broadening scope

The goal is specialization, smaller context, and better continuity across parallel AI sessions.

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

Settings is a **top-navigation tab** (`RootTabView`), a full-screen destination — not a modal. (It used to be a `.sheet`; the tvOS-26 redesign moved it into the tab bar alongside Home / Library / Search.)

- `SettingsView` is composed from `AetherSettingsSection` + `AetherSettingsRow`. Rows use the `status:` style for colour-coded state (`AetherStatus` → `Available` green / `Not connected` red / `Coming soon` grey); actionable rows are focusable (tvOS focus lift). Adding a new section is a copy-paste of an existing one.
- `SettingsViewModel` is `@Observable @MainActor` and derives its state from `AppSession`. It owns `signOut()` (delegates to `session.signOutOfPlex()`) and `connect()` (delegates to `session.presentSignIn()`). There's no sheet to dismiss anymore — `isSettingsPresented` / `presentSettings()` were removed.
- **Sign Out of Plex is the only destructive action in the app today.** It clears the keychain token, drops the persisted server, resets discovery state, and points `source` back to `nil` (Home renders its welcome state without a mock fallback). Adding another destructive action is a design discussion — open an issue with the `ux` label first.

The version + build strings come from `Bundle.main.infoDictionary["CFBundleShortVersionString"]` and `"CFBundleVersion"`. The source of truth is `project.yml` — bump them there.

---

## Player chrome behavior

The player wraps `AVPlayerViewController` (`SystemVideoPlayer`) and is deliberately bare: AVKit's native transport owns Play/Pause, Seek, and the Audio/Subtitle media-options picker (HLS renditions on transcode titles), so Aether adds only what the system doesn't. **Primary audio/subtitle selection happens on Detail, before the player opens** — there is no custom in-player track menu anymore.

- **iOS** is the only platform with a SwiftUI overlay: a single `xmark` Back button. It mirrors AVKit's transport bar via a `simultaneousGesture` (so the SwiftUI tap doesn't consume AVKit's tap-to-reveal-chrome) and auto-hides ~2.5 s after the last interaction. `accessibilityReduceMotion` collapses the fade. Nothing is left behind when hidden.
- **visionOS** dismisses through AVKit's native `Back` contextual action — no SwiftUI overlay.
- **tvOS** dismisses through the native `Done` contextual action plus `.onExitCommand` (Menu button). No SwiftUI overlay — one would fight the focus model.

Playback failure never dead-ends: `state.status == .failed` shows a **Retry + Close** state with human-readable copy, not a black screen.

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

## Localization

Aether ships English + Čeština (+ Ukrainian), via the String Catalog at
[`Aether/Resources/Localizable.xcstrings`](Aether/Resources/Localizable.xcstrings).
The default language follows the device, overridable in Settings ▸ Appearance.

**Hard rule: any user-facing text you add must be a catalog entry, with a `cs`
translation, in the same PR.** No English-only strings reach the UI. If you add
a `Text("…")`, a label, a button title, a placeholder, an empty/error/loading
message, an accessibility label — it goes in the catalog. (Developer logs and
diagnostics stay English; server-provided data like Plex/Jellyfin titles is not
ours to translate — see #344.)

Three ways a string silently *fails* to localize — avoid all three:

- **(a) Not in the catalog.** A literal `Text("More")` is extractable, but you
  still must add the `cs` value. Dynamic keys (`Text(LocalizedStringKey(someVar))`,
  e.g. genre names) are *not* auto-extracted — add them manually with
  `extractionState: "manual"` so they aren't pruned.
- **(b) Passed as `String`, not `LocalizedStringKey`.** `Text(aStringVariable)`,
  `Button(aStringTernary)`, `TextField(aString, …)`, and any `Aether*` component
  whose label param is typed `String` use the *verbatim* initializer and never
  localize. Type label params `LocalizedStringKey`, render via
  `Text(LocalizedStringKey(x))`, and split ternaries into two literal branches.
- **(c) `Locale.current` instead of the app locale.** `Locale.current` is the
  *device* locale, not Aether's chosen language. Format dates / language names /
  numbers against the view's `@Environment(\.locale)` (thread it into AetherCore
  helpers; they have no SwiftUI environment).

Full inventory + rationale for the current tail: #320.

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

- **Every meaningful change updates docs.** New surface → `PRODUCT_SPEC.md`. New module → `ARCHITECTURE.md`. New visual pattern → `DESIGN_PRINCIPLES.md`. New milestone → `ROADMAP.md` and `docs/next-steps/`. **New user-facing string → `Localizable.xcstrings` with a `cs` value** (see *Localization*).
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

Aether runs a **two-stage flow**: agents land into `staging`, then `staging`
gets promoted to `main` in batches. The point isn't process for its own sake;
it's that **every merge into `main` triggers an Xcode Cloud archive** (three
destinations, ~15 minutes each), and we don't need an archive after every
small PR. Batching cuts cost and gives TestFlight testers fewer "version 0.1
build 47" notifications they don't care about.

### The two long-lived branches

- **`main`** — always shippable. The state TestFlight reflects. Tagged for
  releases. Direct pushes are reserved for emergency hotfixes only.
- **`staging`** — integration branch. Every feature / fix / docs PR from
  Claude, Codex, Gemini, or a human targets `staging`, not `main`.

### Feature branches → `staging`

- **Feature branches:** `feature/<short-slug>` — one feature, one branch.
- **Fix branches:** `fix/<short-slug>`.
- **Docs branches:** `docs/<short-slug>`.
- **Spike branches:** `spike/<short-slug>` — explicitly disposable; never
  merged without follow-up work.
- PRs target **`staging`** as the base branch.
- **Rebase, don't merge.** Keep history linear; squash-merge in the PR UI.
- **No long-lived feature branches.** If one is open for a week, split it.

### Promotion `staging → main`

A separate PR with `staging` as head, `main` as base. Open when you've
accumulated something shippable on `staging` and you actually want a new
TestFlight build. Typical cadence: a few times a week, or whenever something
meaningful is ready — there's no fixed schedule.

Format:

- **Title:** `Promote staging → main — <short theme>` (e.g.
  `Promote staging → main — Library view + visionOS playback fix`)
- **Body:**
  - Bullet list of every PR being promoted (number + title), in merge order.
  - Consolidated "What to Test" notes for TestFlight — one short bullet per
    user-visible change.
  - Any known caveats or partial work (e.g. "tvOS untested locally; Xcode
    Cloud will verify").
- **Merge:** regular merge (no squash) so individual PR commits stay
  visible in `main`'s history. The promo PR itself is the squash boundary.

### Xcode Cloud trigger

The "Internal TestFlight" workflow builds **automatically on every change to
`main`** (branch-change trigger). So merging a promotion PR *is* the release
action — there's nothing to click. Don't merge to `main` unless you want a
TestFlight build to go out.

### CI gate

GitHub Actions (`.github/workflows/ci.yml`) runs `swift build` on AetherCore
plus `xcodebuild test` on `AetherTests` against every PR targeting **either**
`main` **or** `staging`. CI failure blocks merge on both (`main` is branch-
protected: these checks are *required*, and the rule applies to admins too —
no direct pushes / force-pushes).

⚠️ **CI only compiles the iOS Simulator.** It does **not** build the visionOS
or tvOS targets, so a platform-availability mistake behind an `os(visionOS)` /
`os(tvOS)` gate compiles green in CI and only fails in the Xcode Cloud archive
(exit 65). When gating a SwiftUI modifier per-platform, verify the API actually
exists there (e.g. `scrollDismissesKeyboard` is iOS-only; `.focusSection()` is
tvOS-only). Adding visionOS/tvOS build steps to CI is an open follow-up.

### Bug-bisect note

When a regression shows up after a promotion, identify the offending PR by
inspecting `main`'s merge commit list since the previous promotion (regular
merges into `main`, so the individual PR commits are still there). Revert
the specific PR via a new fix branch on `staging`; don't revert the
promotion as a whole.

---

## Release process & versioning

Three rules, applied **continuously** — not as an end-of-release scramble.

### 1. Bump the version at the START of its work, not the end

The moment the first PR toward a new version lands, bump
`MARKETING_VERSION` in `project.yml` to that version. So `staging` and `main`
**always carry the version currently being built**, and every TestFlight build
is labelled with the version it's actually working toward — never the previous
one. (Build numbers are separate: `CURRENT_PROJECT_VERSION` is overwritten per
build by Xcode Cloud.)

- **Only the patch digit is auto-bumped.** At the start of new work, bump the
  last number (`0.4.4 → 0.4.5`) without asking — that's the default for fixes
  *and* features alike.
- **Minor / major bumps are the user's call.** Do **not** roll a `0.4.x → 0.5.0`
  (or major) bump on your own initiative — that signals a release milestone, and
  the user decides when something earns it. Ask first; if they haven't said so,
  stay on the patch track. (We wrongly auto-jumped `0.4.4 → 0.5.0` once — don't
  repeat it.)
- The bump is its own tiny commit/PR (or rides the first PR of the version).
- Tag `vX.Y.Z` on `main` only when the version is **finished** and promoted.

### 2. Keep the in-app "What's New" current

`SettingsViewModel.whatsNewBullets` drives the **What's New** modal (About →
version row). When a user-visible feature lands in the in-progress version,
add/adjust a bullet **in the same PR** — so the app always reflects what it
actually does now. Don't let it drift to a past release. Cumulative highlights,
not a raw commit log; the full history lives in `CHANGELOG.md`.

### 3. Every release gets a codename

Releases carry a **codename** alongside the number, surfaced in the What's New
modal (`SettingsViewModel.releaseCodename`) and the `CHANGELOG` heading
(`## [0.4.1] — <date> · "Andromeda"`).

- **Theme: constellations, alphabetical.** Each release takes the next letter:
  0.4.1 **Andromeda** → next **Boötes** → **Cassiopeia** → **Draco** → … It's
  a fun anchor for "which build is this," nothing more — swap the theme freely
  if you want, just keep it consistent and ordered.

### Cut-a-release checklist

When a version is ready to promote + tag:

1. `MARKETING_VERSION` already bumped (rule 1) — confirm it's right.
2. `CHANGELOG.md`: the in-progress `## [X.Y.Z] — Unreleased · "Codename"`
   section is filled in; set its date.
3. `whatsNewBullets` reflects the shipped highlights (rule 2).
4. Promotion PR `staging → main` (regular merge) → auto TestFlight build.
5. Tag `vX.Y.Z` on `main`.
6. Open the next version's `## [Unreleased]` / bump for the next cycle.

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

---

## Cursor Cloud specific instructions

**Cursor Cloud Agent VMs are Linux (Ubuntu); this repo cannot be built, tested, or run on them.** Aether is a macOS/Xcode-only Apple project, so a Linux cloud agent can edit source, docs, `project.yml`, and `Localizable.xcstrings`, but it cannot produce build/test evidence. Treat any build/test/run verification as **must happen on a macOS host with Xcode** (mirroring the `macos-15` CI runners) — don't burn cycles trying to make a Linux VM compile this.

Why it's impossible on Linux (verified, not assumed):

- **No Swift toolchain** is installed on the VM, and even installing Swift-for-Linux wouldn't help.
- **`AetherCore/Package.swift` declares only Apple platforms** (`.iOS(.v26) .tvOS(.v26) .visionOS(.v26) .macOS(.v15)`), and its sources pervasively `import SwiftUI / AVFoundation / AVKit / UIKit / AppKit / Security / FoundationModels / Observation` — none of which exist in Swift-for-Linux. So `swift build` / `swift test` on `AetherCore` fails immediately on missing modules; it is *not* a portable SwiftPM library.
- The **app targets** (`Aether`, `AetherMac`) and **`AetherTests`** require Xcode + iOS/tvOS/visionOS/macOS **26** SDKs + simulators (`xcodeVersion: 16.0`), which are macOS-only.
- **All CI jobs run on `macos-15`** ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)); there is no Linux job, by design.

The real local-dev bootstrap (macOS only, mirrors [`ci_scripts/ci_post_clone.sh`](ci_scripts/ci_post_clone.sh)): `brew install xcodegen` → `./scripts/fetch_vlckit.sh` → `xcodegen generate` → open `Aether.xcodeproj` (and `./scripts/fetch_mpv.sh` for the Mac target). See the "Xcode project gotcha" section above — `Aether.xcodeproj` is generated, so re-run `xcodegen generate` after every pull that touches `Aether/Sources/`.

Because of this, there is **no meaningful update script** for the Linux cloud VM — nothing in this repo is installable/runnable there.
