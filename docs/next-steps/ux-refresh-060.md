# Aether 0.6.0 — UX/UI Refresh: Design-System Spec & Delivery Plan

**Codename target:** 0.6.0 ("Vega" — premium blue, cinematic depth)
**Scope:** One coordinated sprint, one branch off `staging`, one release. Foundation tokens first, then ripple outward. Do NOT split across versions.
**Source of truth:** `AetherCore/Sources/AetherCore/DesignSystem/Tokens.swift` + `docs/ux/DESIGN_PRINCIPLES.md`.

---

## 1. Design Review Summary

### What's wrong today
The app shipped its first real identity on **Aether Violet (`#8B5CF6`)** with near-black zinc surfaces. It is coherent but reads *streaming-adjacent / gaming* rather than *premium Apple ecosystem*. Five structural problems:

1. **Wrong brand color.** Violet is warm and muted; it does not align with the visionOS / Apple TV+ / Infuse language the owner wants. There is no premium-blue primary and no defined secondary tier.
2. **Flat base + over-subtle blooms.** `Palette.background` is a single flat `#09090B`; the cinematic blooms sit on top at 2–5% opacity (too faint). There is no layered depth.
3. **Background inconsistency.** Some screens use `Gradients.background`, others fall back to flat `Palette.background` (Detail, Library, UnifiedLibraryGrid, the wordmark wrapper). Navigating Home → Detail produces a visible background shift. There is **no reusable modifier** — every screen hand-composes it.
4. **Focus reads as a dev-tool outline.** Cards draw a 2pt violet `strokeBorder`; rows apply a 14% wash + hairline. Premium apps use *scale + shadow + depth only*. Three different scales (1.02 / 1.05 / 1.06) and three shadow radii (16 / 18 / 24) make tvOS feel scattered.
5. **Component & layout drift.** Headers duplicated across Home/Library/Search with divergent conditionals; secondary CTAs are sometimes rows, sometimes buttons, sometimes links; DetailView re-implements section headers and hardcodes scrim opacities; Continue Watching is a utilitarian 3px bar; Continue Watching + Downloaded appear on *both* Home and Library.

### The thesis
**Premium blue, cinematic depth, native restraint.** Swap violet → a visionOS-inspired premium blue as the single primary; demote purple to a subtle secondary. Replace the flat black base with a layered three-stop gradient + slightly stronger blooms, applied through **one modifier** everywhere. Replace focus *outlines* with a single unified *lift-and-glow* depth treatment. Unify the duplicated chrome (header, focus, rows, scrims, progress) into shared primitives. Clarify Home (watch-now dashboard) vs Library (collection browser). Ship it as one 0.6.0, foundation-first so the ripple is mechanical.

---

## 2. Color System — FINAL (single source of truth for `AetherDesign.Palette`)

These are the **final exact values**. No alternatives, no "or".

### Brand accents
| Token | Hex | Role |
|---|---|---|
| `accent` | **`#6A8BFF`** | Premium Blue — **PRIMARY**. Focus, selection, primary actions, links, section accents, active chevrons, checkmarks. The one accent everything reads against. |
| `accentBright` | **`#5B7CFF`** | Brightened blue — focus glow, progress fill, hover/active, gradient bright stop. |
| `accentIndigo` | **`#4C63E0`** | Darker indigo — gradient depth partner (the dark stop of `aurora`/`progress`). |
| `accentSecondary` | **`#9B7EBF`** | Subtle Purple — **SECONDARY only**. Muted/planned status, tertiary badges, the secondary background bloom. Never used for primary interactive state. |
| `accentGold` | **`#F5B524`** | Brand-mark only (the neon "A" / wordmark pairing). Never interactive. |
| `accentAmber` | **`#F59E0B`** | Soft warm glow anchor for `cinematic` gradient only. |

> **Migration rule:** `accent` keeps its name and *changes value* violet → blue. Every existing `Palette.accent` call site (cards, buttons, rows, badges, headers, icons) instantly becomes blue with zero call-site edits. This is the key lever that makes the rebrand a one-line-of-tokens change rippling everywhere. `accentAurora` is **removed** (its old call sites move to `accentSecondary` for blooms or are folded into the recomposed gradients).

### Surfaces
| Token | Light | Dark | Note |
|---|---|---|---|
| `background` | `#F6F6F6` | **`#0B0D12`** | Top anchor of the layered gradient (was `#09090B`). |
| `backgroundMid` | `#FFFFFF` | **`#111827`** | NEW — charcoal-blue mid depth stop. |
| `backgroundBottom` | `#F6F6F6` | **`#0A0A0F`** | NEW — near-black bottom anchor. |
| `surface` | `#FFFFFF` | `#18181B` | Unchanged — card base. |
| `surfaceElevated` | `#FAFAFA` | `#27272A` | Unchanged — elevated rows. |
| `separator` | black @10% | white @10% | Unchanged. |

### Text (unchanged — already correct, Apple-native zinc ramp)
| Token | Light | Dark |
|---|---|---|
| `textPrimary` | `#0A0A0A` | `#FAFAFA` |
| `textSecondary` | `#52525B` | `#A1A1AA` |
| `textTertiary` | `#71717A` | `#71717A` |

### Semantic
| Token | Hex | Note |
|---|---|---|
| `success` | `#22C55E` | Unchanged. |
| `warning` | **`#F97316`** | CHANGED orange-red — disambiguates status warning from brand gold (`#F5B524`). |
| `error` | `#EF4444` | Unchanged. |
| `focusGlow` | **aliases `accentBright` (`#5B7CFF`)** | CHANGED from `accent`. The glow is the bright blue; the fill/border identity is `accent`. |

### Final Tokens.swift `Palette` block
```swift
public enum Palette {
    // Brand accents — premium blue primary, subtle purple secondary
    public static let accent          = Color(hex: 0x6A8BFF) // Premium Blue (PRIMARY)
    public static let accentBright    = Color(hex: 0x5B7CFF) // glow / progress / active
    public static let accentIndigo    = Color(hex: 0x4C63E0) // gradient depth partner
    public static let accentSecondary = Color(hex: 0x9B7EBF) // Subtle Purple (SECONDARY)
    public static let accentGold      = Color(hex: 0xF5B524) // brand-mark pairing only
    public static let accentAmber     = Color(hex: 0xF59E0B) // cinematic warm anchor only

    // Surfaces — layered dark base
    public static let background       = Color(light: Color(hex: 0xF6F6F6), dark: Color(hex: 0x0B0D12))
    public static let backgroundMid    = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x111827))
    public static let backgroundBottom = Color(light: Color(hex: 0xF6F6F6), dark: Color(hex: 0x0A0A0F))
    public static let surface          = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x18181B))
    public static let surfaceElevated  = Color(light: Color(hex: 0xFAFAFA), dark: Color(hex: 0x27272A))
    public static let separator        = Color(light: .black.opacity(0.10), dark: .white.opacity(0.10))

    // Text (unchanged)
    public static let textPrimary   = Color(light: Color(hex: 0x0A0A0A), dark: Color(hex: 0xFAFAFA))
    public static let textSecondary = Color(light: Color(hex: 0x52525B), dark: Color(hex: 0xA1A1AA))
    public static let textTertiary  = Color(light: Color(hex: 0x71717A), dark: Color(hex: 0x71717A))

    // Semantic
    public static let success = Color(hex: 0x22C55E)
    public static let warning = Color(hex: 0xF97316) // orange-red, distinct from gold
    public static let error   = Color(hex: 0xEF4444)

    public static let focusGlow = accentBright // bright blue glow
}
```

> **Decision on naming:** keep `accent` (not `accentPrimary`). Several proposals wanted a rename — rejected. Renaming churns ~80 call sites for zero visual gain and risks merge pain on a single sprint branch. Re-pointing `accent` to blue is the decisive, low-risk move. `AetherStatus.muted` keeps `textTertiary` (no change needed); use `accentSecondary` only where a purple tint is explicitly wanted.

---

## 3. Background System — FINAL

### Gradient stops (dark)
`#0B0D12` (top-leading) → `#111827` (mid) → `#0A0A0F` (bottom-trailing), diagonal.

### Recomposed gradient tokens
```swift
public enum Gradients {
    // Hero / featured wash, primary button fill — indigo → bright blue
    public static var aurora: LinearGradient {
        LinearGradient(colors: [Palette.accentIndigo, Palette.accentBright],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Progress fill (Continue Watching, scrubbers) — indigo → bright blue
    public static var progress: LinearGradient {
        LinearGradient(colors: [Palette.accentIndigo, Palette.accentBright],
                       startPoint: .leading, endPoint: .trailing)
    }

    // NEW: layered base, replaces flat Palette.background as the bloom substrate
    public static var backgroundBase: LinearGradient {
        LinearGradient(colors: [Palette.background, Palette.backgroundMid, Palette.backgroundBottom],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Whole-screen atmosphere — layered base + two blooms (slightly stronger)
    public static var background: some View {
        ZStack {
            backgroundBase
            RadialGradient(colors: [Color(light: Palette.accentBright.opacity(0.04),
                                          dark:  Palette.accentBright.opacity(0.08)), .clear],
                           center: UnitPoint(x: 0.15, y: 0.10), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(light: Palette.accentSecondary.opacity(0.03),
                                          dark:  Palette.accentSecondary.opacity(0.06)), .clear],
                           center: UnitPoint(x: 0.88, y: 0.18), startRadius: 0, endRadius: 600)
        }
    }

    public static var heroBloom: RadialGradient {
        RadialGradient(colors: [Palette.accentBright.opacity(0.28), Palette.background],
                       center: .center, startRadius: 0, endRadius: 640)
    }

    // Brand-mark pairing only — preserved (blue → blue → gold for the "A")
    public static var cinematic: LinearGradient {
        LinearGradient(colors: [Palette.accentBright, Palette.accent, Palette.accentGold],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
```
> Blooms move from 2–5% to **6–8%** on dark for stronger cinematic depth while staying subtle. **No noise/texture overlay in 0.6.0** — deferred; ship the gradient first and only add texture if banding appears on-device.

### The reusable modifier (new — `AetherModifiers.swift`)
```swift
public extension View {
    /// Standard full-screen cinematic background (layered gradient + blooms),
    /// safe-area-ignoring. Apply on every root screen body.
    func aetherScreenBackground() -> some View {
        background(AetherDesign.Gradients.background.ignoresSafeArea())
    }
}
```

### Adoption (every root screen calls `.aetherScreenBackground()`)
| Screen | Today | Action |
|---|---|---|
| HomeView | `Gradients.background` ✓ | → modifier |
| SearchView | `Gradients.background` ✓ | → modifier |
| SettingsView | `Gradients.background` ✓ | → modifier |
| DiscoverView | `Gradients.background` ✓ | → modifier |
| StorageView | `Gradients.background` ✓ | → modifier |
| LibraryBrowseView | `Gradients.background` ✓ | → modifier |
| PlexSignInView / JellyfinSignInView | `Gradients.background` ✓ | → modifier |
| **DetailView** | flat `Palette.background` ❌ | → modifier (fixes the Home→Detail shift) |
| **LibraryView** | flat ❌ | → modifier |
| **UnifiedLibraryGridView** | flat ❌ | → modifier |
| **AetherWordmark** wrapper | flat ❌ | → modifier |
| **PlayerView** | hardcoded `Color.black` | **KEEP black** — do NOT apply. Full-screen video must not compete. |

---

## 4. Typography & Spacing

**No changes.** The current scale is already Apple-native and correct:
- Typography: `heroTitle` (largeTitle/bold), `sectionTitle` (title2/semibold), `cardTitle` (headline/medium), `body`, `metadata` (subheadline/medium), `caption`.
- Spacing: `xxs=4, xs=8, s=12, m=16, l=24, xl=32, xxl=48`.
- Radius: `card=12, cardTV=16, sheet=20`.

One **additive** token only, to support the compact "More" / tertiary actions in Detail (Section 6/7):
- `Typography` gains nothing; reuse `metadata` for compact buttons.
- Spacing is sufficient (`xs=8` is a safe icon-button inset). **Do not add `xxs` variants.** Keep the scale clean.

> Decision: resist token sprawl. Several proposals invented `glyph-small/tvos/large`, `ornament-corner-radius`, `Typography.sectionLabel`, `Materials.cardDiscovery`. **Rejected for 0.6.0.** Glyph sizes are literals inside `AetherGlyph`; discovery cards reuse `Materials.card`; section labels reuse `metadata` + `textTertiary`.

---

## 5. tvOS Focus Pattern — FINAL

**Replace all borders/washes with one unified lift-and-glow.** Focus = depth, never an outline.

### Canonical values
- **Scale:** `1.06` for cards (large posters/hero), `1.04` for buttons and rows. (Two tiers only — cards earn a bigger lift because they're physically larger; one value for everything else.)
- **Glow:** `focusGlow` (`#5B7CFF`) shadow, **radius `20`**, **y `8`**, **opacity `0.6`** when focused, `0` otherwise. Single radius across all components (replaces 16/18/24).
- **Motion:** `Motion.focus` = `.spring(response: 0.18, dampingFraction: 0.85)` (unchanged).
- **No `strokeBorder`. No fill wash. No hairline.**

### Reusable modifier (in `AetherRowStyle.swift` or `AetherModifiers.swift`)
```swift
struct PremiumFocus: ViewModifier {
    var scale: CGFloat = 1.04
    @Environment(\.isFocused) private var isFocused
    func body(content: Content) -> some View {
        content
            .shadow(color: AetherDesign.Palette.focusGlow.opacity(isFocused ? 0.6 : 0.0),
                    radius: isFocused ? 20 : 0, y: isFocused ? 8 : 0)
            .scaleEffect(isFocused ? scale : 1.0)
            .animation(AetherDesign.Motion.focus, value: isFocused)
    }
}
public extension View {
    func premiumFocus(scale: CGFloat = 1.04) -> some View { modifier(PremiumFocus(scale: scale)) }
}
```
On iOS/iPadOS/visionOS `\.isFocused` stays false inside button labels, so this collapses to identity automatically — no `#if`.

### Component changes
- **AetherCard:** delete the `.strokeBorder(accent…)` overlay (lines 47–50). Replace inline shadow+scale (lines 51–55) with `.premiumFocus(scale: 1.06)`. Watched badge stays (white check on `accent` — now blue).
- **AetherButton:** delete role-dependent `glowColor` complexity; all roles glow with `focusGlow`. Keep the *permanent* soft bloom under `.primary` (it reads as the hero CTA), but drive the focused state through `.premiumFocus(scale: 1.04)`. Destructive still tints red for fill/text; glow stays blue.
- **AetherFocusRow:** delete the `surfaceElevated` fill + 14% wash + 45% hairline overlay (lines 54–66). Keep only `.premiumFocus(scale: 1.04)`. Rows now lift and glow from the cinematic surface instead of painting a violet box.
- **Tab bar:** native tvOS rendering, no customization.

---

## 6. Component Patterns — Unified Across Platforms

### Card with integrated progress (`AetherCard`)
Replace the 3px utilitarian bar with a **bottom-anchored cinematic strip**:
- Height: **32pt tvOS/visionOS, 24pt iOS/iPadOS**.
- Backdrop: `Materials.card` (ultraThin) frosted strip across the card's lower edge, leading corners `8pt` continuous.
- Fill: `Gradients.progress` (indigo → `accentBright`), bottom-aligned **2pt** fill bar over the frosted strip, width = `progress`.
- Position: `.overlay(alignment: .bottomLeading)` spanning card width.
- Focus glow: now blue (inherited via the `accent`/`focusGlow` repoint — no separate work).

### Buttons — Resume / Restart / More hierarchy (`AetherButton` + Detail)
Three visual weights, Apple-native:
1. **Primary** (Resume / Play): `aurora` gradient (indigo→bright blue), white text, `cardTitle`, full-width or lead position. At most one.
2. **Secondary** (Restart, Watch in Cinema): `surface @0.8`, `textPrimary`, `cardTitle`, equal width in an HStack beside/below primary.
3. **Tertiary** (Download, More): add a `.tertiary` role to `AetherButton` — no fill (or `surfaceElevated`), `textSecondary`, `metadata` font, compact padding (`.horizontal s`, `.vertical xs`). **More** = `ellipsis.circle` — icon-only on iOS/visionOS; **on tvOS keep a small "More" text label** (icon-only is undiscoverable by the focus engine).

Spacing: group internally at `Spacing.s`, separate groups by `Spacing.m`. On tvOS wrap each group in `.focusSection()` so **Up escapes to the hero**.

### Hero scrim (new `AetherHeroScrim` modifier)
Tokenize DetailView's hardcoded scrim (`0.55 / 0.96`):
```swift
public extension View {
    func aetherHeroScrim() -> some View {
        overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear,
                                    AetherDesign.Palette.background.opacity(0.55),
                                    AetherDesign.Palette.background.opacity(0.96)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}
```

### Section headers (`AetherSectionHeader`)
Make it the **canonical** header everywhere. Add a `.plain` style (text only, no accessory). **DetailView** replaces its raw `Text(sectionTitle)` for "More Like This" / "Children" / "Episodes" with `AetherSectionHeader(title:, style: .plain)`. Accent in headers = `accent` (blue).

### Nav / logo placement (`AetherGlyph` + `AetherTabHeader`)
- **Stop repeating the 60pt wordmark per tab.** Move the brand mark into the navigation container as a compact glyph.
- New `AetherGlyph` component: the "A" mark, sizes `24pt` (iOS/iPadOS/visionOS nav), `18pt` (tvOS top bar), `32pt` (modal reveal). Tinted with `cinematic` gradient (blue→blue→gold) — the *only* place gold appears interactively-adjacent.
- New `AetherTabHeader` (extract the duplicated branded-header pattern from Home/Library/Search into one component): wordmark/glyph + search field + conditional tvOS reload. Used by Home, Library, Discover (reload-only), Search.
- **Keep the full large wordmark only on Settings root** (first-impression surface).
- iOS/iPadOS search → native `.searchable()` on the NavigationStack (reclaims ~40–60pt per tab).
- tvOS: 18pt glyph as a static status ornament ("Connected: Plex"); reload stays.
- visionOS: glass ornament top-leading (40pt inset), 24pt glyph + connection badge.

> **Decision — scope the nav rework down.** Full `.searchable()` migration + ornament docking is the highest-risk, device-only item. For 0.6.0: ship `AetherGlyph` + `AetherTabHeader` (dedupe + glyph-in-header), adopt `.searchable()` on iOS/iPadOS where it's a clean win, and the tvOS/visionOS ornament. If `.searchable()` integration fights the custom header on iPad Split View during the sprint, fall back to the glyph-in-header on that platform — **do not** let it block the release.

---

## 7. Per-Area Implementation Notes (feasible-now vs future)

### Detail (`DetailView.swift`)
- **NOW:** apply `.aetherScreenBackground()` (fixes background shift); adopt `aetherHeroScrim()`; adopt `AetherSectionHeader(.plain)` for subsections; rebuild action row into the 3-tier hierarchy (Section 6) with `.tertiary` "More"; wrap action groups in `.focusSection()` on tvOS; move audio/subtitle/quality disclosure rows *below* the action stack.
- **Series vs Movie:** Movies → hero → actions → config. Series → hero → Next Up (largest) → season selector → episodes → details.
- **Future (0.6.1):** AetherRow base container for the detail tech-detail/picker rows (nice-to-have consolidation, not required for the visual refresh).

### Search (`SearchView.swift`)
- **NOW:** replace the passive empty state with a **Search Discovery** layout — `ScrollView` of Continue Watching (from `ResumeStore`, same as LibraryView pattern) + Recently Added + Recently Released (all from `UnifiedLibrary.homeRails()` / `UnifiedRails`), plus a one-line search-tips caption. tvOS wraps each rail in `.focusSection()` (gives D-pad targets without typing). Graceful degradation: no sources → fallback empty state; loading → `AetherLoadingState.rails(count: 2)`.
- **Future (0.6.1):** Genre/category pills (needs `genres()` source method); Collections rail (needs source API). Don't block 0.6.0 on these.

### Settings (`SettingsView.swift`)
- **NOW:** right-column "Discover Aether" panel on wide layouts — version card, "Recently Shipped" (reuse existing hardcoded `whatsNewBullets`, top 3, green checkmarks), capabilities card (static list, `accent`/blue icons; Cinema Mode gated `#if os(visionOS)`), unified Storage & Cache card. Left column = config, framed "Your Setup". iPhone = single column with dividers between config and discovery. Each column `.focusSection()` on tvOS.
- **Future (0.6.1):** runtime CHANGELOG/ROADMAP parsing, release-notes sheet, roadmap card. Keep bullets hardcoded for now (no runtime markdown parsing).

### Home / Library split (`HomeView`, `LibraryBrowseView`, `UnifiedLibraryGridView`, `UnifiedLibrary`)
- **HOME = DASHBOARD:** Continue Watching (top) → Featured → Recently Added → Recently Released → Downloaded → per-library discovery (single-source only). Owns watch-now.
- **LIBRARY = COLLECTION BROWSER:** **remove** Continue Watching, Downloaded, Featured from Library. Movies / TV Shows rails gain **inline sort + genre-filter affordances** (lift `genreFilterRow` + sort toolbar/sheet out of `UnifiedLibraryGridView` as reusable helpers); 12-item preview + "See all" → grid. Add a subtle "across all sources" caption to surface the dedup model.
- **NOW:** the rail moves + dedupe of the branded header via `AetherTabHeader`. Add a `UnifiedLibrary.libraryRails()` (kind + count, no watch-now cruft) or rename `homeRails` consumption.
- Genre filtering stays client-side; cache `unifiedItems()` if extraction is slow.

### Discover (`DiscoverView.swift`)
- **NOW:** retitle hero to "Aether Discovery Hub" / "Curated for your library". Reorder: hero → Recently Added → Top Rated → Genre rails → Random Picks (demoted to tail). Top Rated **fallback** to Recently Released when no ratings exist (never empty). Add genre subtitles ("N titles"). Introduce a lightweight `DiscoverSection` model so future rails (Trending/Popular/Collections) need no render-branching.
- **Future (0.6.1):** Trending/Popular/Collections (need source APIs).

---

## 8. Milestone Breakdown WITHIN 0.6.0

One branch off `staging` (`feature/0.6.0-ux-refresh`), built in ordered internal milestones. Foundation first so the rebrand ripples mechanically.

### M1 — Foundation: Color + Background tokens (do first, lands the whole rebrand)
- **Files:** `Tokens.swift` (Palette repoint to blue, surfaces, semantic, gradients recomposed), new `AetherModifiers.swift` (`aetherScreenBackground`, `aetherHeroScrim`, `premiumFocus`), `docs/ux/DESIGN_PRINCIPLES.md` (color/gradient tables).
- **Effect:** every `Palette.accent` call site flips violet→blue instantly. App is already 80% rebranded after this.
- **Verify:** build clean on iOS sim; eyeball blue accent + gradient on iOS.

### M2 — Focus system (tvOS depth)
- **Files:** `AetherCard.swift` (drop stroke, `premiumFocus(1.06)`), `AetherButton.swift` (simplify glow, `premiumFocus(1.04)`), `AetherRowStyle.swift` (drop fill/wash/hairline, `premiumFocus(1.04)`). `AetherSettingsRow`/`AetherDisclosureRow`/`AetherSelectionRow` inherit via `aetherFocusRow` — no direct edits.
- **Verify:** ⚠️ **TestFlight on tvOS device only.**

### M3 — Card progress + section headers + scrim
- **Files:** `AetherCard.swift` (cinematic progress strip), `AetherSectionHeader.swift` (add `.plain`), DetailView (adopt `.plain` headers + `aetherHeroScrim`).

### M4 — Background adoption sweep
- **Files:** DetailView, LibraryView, UnifiedLibraryGridView, AetherWordmark, HomeView, SearchView, SettingsView, DiscoverView, StorageView, LibraryBrowseView, PlexSignInView, JellyfinSignInView → `.aetherScreenBackground()`. PlayerView untouched.

### M5 — Shared chrome: glyph + tab header
- **Files:** new `AetherGlyph.swift`, new `AetherTabHeader.swift`; `RootTabView.swift` (glyph in nav / ornament); HomeView, LibraryBrowseView, SearchView, DiscoverView adopt `AetherTabHeader`; SettingsView keeps large wordmark; add `.tertiary` role to `AetherButton`.
- **Verify:** ⚠️ **device** — tvOS ornament focus, visionOS ornament docking/gesture, iPad Split View `.searchable()` behavior.

### M6 — Screen restructures (parallelizable after M1–M5)
- **Detail** action hierarchy + focus sections (`DetailView.swift`).
- **Search** discovery state (`SearchView.swift`).
- **Settings** discovery panel (`SettingsView.swift`).
- **Home/Library split** (`HomeView.swift`, `LibraryBrowseView.swift`, `UnifiedLibraryGridView.swift`, `UnifiedLibrary.swift`).
- **Discover** reorder + `DiscoverSection` model (`DiscoverView.swift`).

### M7 — Polish, version bump, changelog
- `project.yml` `MARKETING_VERSION` 0.5.9 → **0.6.0**; CHANGELOG entry; run `xcodegen generate` after the file-set changes (new files: AetherModifiers, AetherGlyph, AetherTabHeader).

### CANNOT be visually verified without a device — must check on TestFlight
- **tvOS:** focus glow intensity (`#5B7CFF` @ 0.6 / 20pt radius) against `#0B0D12`; card 1.06 vs button/row 1.04 hierarchy at couch distance; bloom intensity (6–8%) on a real TV panel; tab-bar ornament focus chain; "More" text-label discoverability; `.focusSection()` Up-escape from action groups.
- **visionOS:** glass ornament docking + tap-to-reveal gesture; blue alignment with system spatial accent; bloom over translucent materials.
- **iOS/iPad:** OLED bloom banding (may need −1–2% on blooms); `.searchable()` in iPad Split View vs custom header; safe-area edge cases for the nav glyph near the Dynamic Island.
- **All:** `#6A8BFF` text/icon contrast on `#0B0D12` under VoiceOver / varied lighting; `accentSecondary` purple legibility when paired with blue on hero.

---

## 9. Risks + Sequencing Notes

- **Highest risk: M5 nav rework** (medium). The `.searchable()` migration + ornament docking is device-only and platform-divergent. **Mitigation:** glyph-in-header is the floor; `.searchable()` and ornaments are layered on top and can degrade per-platform without blocking the release. Sequence M5 *after* M1–M4 so the rebrand is shippable even if nav slips to a follow-up commit on the same branch.
- **Single sprint branch, shared working dir:** the user has Xcode open on the repo. Work in a **git worktree**, run **`xcodegen generate`** after adding `AetherModifiers.swift` / `AetherGlyph.swift` / `AetherTabHeader.swift` (the project is generated from `project.yml`). Branch off **`staging`**, PR `--base staging`.
- **Sequencing is foundation-first by design:** M1 alone delivers the rebrand (the `accent` repoint cascades everywhere); M2–M4 are mechanical token-driven ripples; M6 restructures are independent of each other and parallelizable once primitives exist.
- **CI gap (known):** CI builds iOS Sim only — M2 (focus) and M5 (ornaments) breakage on tvOS/visionOS will slip past CI to the Xcode Cloud archive. **Verify platform availability of every gated SwiftUI API** (`.searchable` placements, ornament APIs, `focusSection`) and add a tvOS/visionOS compile leg if possible before merging.
- **Low-risk areas** (background adoption, Discover reorder, Search discovery, Settings panel) can land early and independently; they only consume existing data.
- **Versioning:** this is the owner's explicit minor bump to **0.6.0** — not an auto patch bump. Land the version change last (M7).

---

**Key files (absolute paths):**
- Tokens: `/Users/vasek/Git/Aether/AetherCore/Sources/AetherCore/DesignSystem/Tokens.swift`
- Focus/rows: `/Users/vasek/Git/Aether/AetherCore/Sources/AetherCore/DesignSystem/AetherRowStyle.swift`
- Card: `/Users/vasek/Git/Aether/AetherCore/Sources/AetherCore/DesignSystem/AetherCard.swift`
- Button: `/Users/vasek/Git/Aether/AetherCore/Sources/AetherCore/DesignSystem/AetherButton.swift`
- Section header: `/Users/vasek/Git/Aether/AetherCore/Sources/AetherCore/DesignSystem/AetherSectionHeader.swift`
- New files: `AetherModifiers.swift`, `AetherGlyph.swift`, `AetherTabHeader.swift` (same DesignSystem dir; the latter two may live in `/Users/vasek/Git/Aether/Aether/Sources/` if they reference app-level views)
- App views: `/Users/vasek/Git/Aether/Aether/Sources/{HomeView,LibraryBrowseView,LibraryView,UnifiedLibraryGridView,DiscoverView,SearchView,SettingsView,DetailView,RootTabView,AetherWordmark,PlayerView,PlexSignInView,JellyfinSignInView,StorageView}.swift`
- Library aggregation: `/Users/vasek/Git/Aether/AetherCore/Sources/AetherCore/Library/UnifiedLibrary.swift`
- Version/build: `/Users/vasek/Git/Aether/project.yml` (`MARKETING_VERSION` → 0.6.0), `/Users/vasek/Git/Aether/CHANGELOG.md`
- Docs: `/Users/vasek/Git/Aether/docs/ux/DESIGN_PRINCIPLES.md`

Note: the proposals reference `/tmp/aether-wt-ux/...` paths; the live repo root is `/Users/vasek/Git/Aether/` — paths above are corrected to the real tree, which I verified matches the proposals' described code (violet `#8B5CF6` accent, flat `#09090B` background, 3px progress bar, stroke-border card focus, version 0.5.9).