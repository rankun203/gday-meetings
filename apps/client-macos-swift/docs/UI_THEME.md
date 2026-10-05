---
title: Shared UI theme and component practices
date: 2026-10-03
updated: 2026-10-05
status: active
scope: all-swift-app-ui
---

# Shared UI theme and component practices

This is the common design and implementation standard for **every screen and component** in the macOS app, including settings, sheets, popovers, menus, empty/error states, recording, playback, and AppKit-backed views. It governs new work and migration of existing UI. It does not claim that existing screens already conform. The [UI design guide](UI_DESIGN.md) defines feature interactions; the [refresh worklog](../../../docs/worklogs/2026-10-03-liquid-glass-refresh.md) records the inventory, evidence, and migration plan. Screenshots document the current implementation; they do not override these written requirements.

## Architecture decision

Use a small shared design system with **native controls, semantic values, scoped styles, and composed components**. These are complementary tools. Do not build a parallel widget toolkit or make a wrapper around every `Text`, `Button`, and `Toggle`. A folder provides organization; consistency comes from shared contracts and review.

| Layer | Responsibility | Examples and boundaries |
| --- | --- | --- |
| Semantic values | Name app-specific visual intent, shared across SwiftUI and AppKit. | Accent, playback highlight, warning, reading surface, muted metadata, control spacing, player hit target. Use system colors/fonts first; do not duplicate every system metric. |
| Native style protocols | Customize one control family while retaining its standard interaction. | `ButtonStyle`, `ToggleStyle`, `LabelStyle`, `DisclosureGroupStyle`. Prefer built-in styles and `controlSize` unless requirements justify a custom style. |
| View modifiers | Reuse an orthogonal visual policy. | Navigation material with availability/accessibility fallback, section spacing, hover treatment. Do not hide model writes or navigation in an appearance modifier. |
| Composed components | Reuse layout plus meaning, accessibility, or interaction. | Status message with recovery action, source meter, language picker, speaker chip/picker, transport, labeled setting row. Accept values/bindings/actions; do not fetch a global store simply to draw. |
| Feature views | Own screen state and task-specific composition. | Meeting detail, providers, task queue, voice review. Keep domain operations and persistence outside the theme. |
| Native bridges | Keep performant native renderers and share resolved visual values. | Transcript table, meeting table, Markdown text view/editor, waveform. Update colors/metrics on appearance changes; do not recreate document/table identity on each tick. |

The implementation keeps the existing flat `UI/` layout. Do not move feature files merely to adopt the theme. Shared contracts are:

- `AppTheme.swift`: `AppTheme` holds fixed spacing, radius, transport target, and semantic reading-background values.
- `WorkspaceListHeader(title:subtitle:actions:)`: a stationary list heading with optional count and scoped actions. It draws supplied values on the reading surface and does not load data.
- `AppChromeSurface(shape:)`: stationary navigation and transport material. Uses native Liquid Glass on macOS 26, native regular material on earlier supported systems, and an opaque control background for Reduce Transparency or Increase Contrast. Increased contrast adds an outline. Never apply it to scrolling rows.
- `AppContentSurface()`: an opaque semantic reading background for related content, with an outline only when contrast is increased. It adds no padding; the owning layout chooses the shared inset.
- `SettingsComponents.swift`: `AppInlineMessage(text:systemImage:tint:)` combines wrapping, selectable primary text with a status symbol; tint affects the symbol. `ProviderHealthSummary(title:health:)` combines a capability, its readiness, and any explanation. These views draw supplied values and perform no service operations.
- Existing `ActionButtonStyle`, `AppDisclosureStyle`, and native controls continue to own their interaction families. Do not introduce competing controls to obtain an appearance change.

Use immutable static values for fixed conventions. Read `colorScheme`, contrast, enabled state, Reduce Motion, Reduce Transparency, and active-window state from the environment. Add a small typed environment value only for configuration that genuinely varies by subtree (for example, a supported density mode). Do not introduce an observable global theme singleton or broadcast playback time through it. Use bindings for editable state, not to bind every view to fixed styling constants. Current SwiftUI supports custom environment entries with `@Entry`; confirm toolchain and minimum-runtime compatibility when adopting it.

Apply styles at the narrowest useful container. A global borderless button style can accidentally change alert, toolbar, menu, and form behavior. Avoid `AnyView`-based component registries, stringly typed style names, and arrays of theme closures where concrete views/styles suffice. Prefer a semantic enum over many boolean appearance arguments.

## Visual language

- Use native Liquid Glass for navigation and persistent control surfaces on supported systems. Keep transcripts, lists, Markdown, and forms on quiet readable surfaces. No per-row glass or decorative blur behind text.
- The library uses native split navigation. Let the system render its sidebar and toolbar; do not wrap the sidebar in an additional floating glass card or force an opaque toolbar background. List creation actions belong to the list header; selected-item actions belong to the detail header. Playback keeps a readable waveform surface and a separate transport capsule.
- Use semantic system colors. Accent expresses selection/action; recording uses its established red signal; warning/error/success include a symbol and text. Speaker colors identify people, not playback state.
- Use system text roles: title for the screen or meeting, headline for sections, body for content/control labels, callout/caption for secondary metadata. Keep timestamps monospaced-digit. Never shrink an actionable warning into faint caption text.
- Use a small shared spacing scale (4, 8, 12, 16, 24 points as starting conventions), then respect native control metrics. Do not force all controls into one height. Native compact form controls remain compact; frequent transport targets remain at least 44 by 44 points.
- Use capsules for compact navigation/transport groupings where appropriate, rounded rectangles for larger surfaces, and ordinary native borders for text input. Avoid universal rounded cards and double borders.
- Use hierarchy before decoration: one prominent primary action per local task; secondary actions stay quiet; destructive actions use a destructive role and the correct confirmation behavior.
- Hover, pressed, disabled, selected, focused, and inactive are separate states. Hover never changes layout. Pointer selection must not leave a keyboard-only focus ring. Keyboard and assistive navigation retain visible focus and accessible selection.
- Honor light, dark, and system appearance in every window and native bridge. Respect reduced transparency/motion and increased contrast. Use supported older-system material/control fallbacks while macOS 14.2 remains supported.

## Control contracts

| Family | Standard |
| --- | --- |
| Text and titles | Plain, concise UI wording per the repository writing guide. Preserve title editing, full-value accessibility/help, and truncation rules. No view-specific arbitrary font palettes. |
| Buttons | Native `Button` with label, role, help for icon-only actions, and disabled semantics. Use style protocols for repeated appearance; keep standard keyboard activation. Small icons sit within adequate hit targets. |
| Text inputs | Persistent accessible label, clear purpose, native editing/selection/undo. Placeholder is supplementary. Inline validation describes recovery. Secure fields stay secure. Multiline fields expand within sensible bounds. |
| Search | Library search at top of sidebar. Draft input plus Return opens a dedicated Search Results page; query/results state survives opening/back navigation. See the refresh worklog for the full flow. Local person/model filters remain scoped and labeled as such. |
| Pickers and menus | Native menu/popup/combo controls for many choices; segmented controls for a small stable set. Preserve editable model entry where supported. Avoid creating a custom dropdown just for glass. |
| Switches and checkboxes | Switch for ongoing settings; checkbox for selection or local boolean options. Keep native behavior. Align label, explanatory text, readiness, and control consistently. Disabled explanation remains discoverable. |
| Tabs and segmented controls | Shared selection/focus/hover treatment; no permanent ring from clicking. Preserve arrow/Tab navigation and selected accessibility state. App settings retain their native tab conventions. |
| Chips | Compact tag/speaker/status labels; text plus semantic state. Removal has an accessible action and adequate target. Do not treat all chips as buttons. |
| Disclosure | One full-width header hit region; shared chevron, hover, spacing, expanded value, and reduced-motion behavior. No nested actions inside the header button. |
| Feedback | Shared status pattern for information, warning, error, success, progress, and unavailable states. Include concrete text, optional details, and a specific recovery action. Use native alerts for blocking decisions; no custom glass alert replacements. |
| Lists/tables | Reuse cells, stable IDs, bounded paging, stable viewport, semantic selection. Keep appearance changes independent of data loading. Empty/loading/error states occupy the relevant region. |
| Transcript | Preserve timestamps, source/person chips, editing, speaker assignment, multiple simultaneous playback highlights, live state, and follow behavior. Keep hover separate from playback. |
| Markdown viewer | One selectable native document; consistent heading/list/table/code/link/task/image typography; shared palette with editor; readable opaque background. Keep code copy and task toggles accessible. |
| Markdown editor | Preserve native editing, IME, undo, selection, timed gutter, image resize, read/edit switching, and persistence. Formatting controls use shared styles; theme changes never rewrite document content or reset caret. |
| Player/waveform | One persistent broad transport with shared source timeline, precise scrubbing, speed/track/mute controls, and content clearance. Expanded tracks use the same tokens. Keep ticks isolated from screen-wide updates. |
| Sheets/popovers/panels | Native presentation and focus management, explicit titles, sensible default/cancel actions. Use standard Finder import/export panels. No custom modal framework for appearance alone. |

## Reuse and review

Before adding a new visual element, find the existing family and reuse it. Add a component only when it shares meaningful layout/behavior or establishes a deliberate cross-screen contract. A single native control plus a modifier does not automatically need a named wrapper. A one-off screen may compose native controls directly using the shared contracts.

Every shared component must cover normal, hover, pressed, disabled, selected where applicable, keyboard focus, inactive window, light/dark, increased contrast, and relevant loading/error states. A component gallery should instantiate the actual production types with synthetic bindings/actions. It must not redraw lookalikes. Whole-screen Preview must also instantiate production screens; fixtures change data and external services, not the widget implementation.

Keep UI audit screenshots under the repository’s ignored `tmp/` directory or a system temporary directory; commit written findings and provenance, not binary captures, unless explicitly requested. Record source revision/working-tree snapshot, bundle path, build time, OS/toolchain, and fixture flags when reviewing screenshots. A previously launched app does not update when a different bundle is built. Launch by exact path when multiple Preview copies exist. Rebuild from the intended source before calling it “latest.”

Review shared components in isolation and in their actual screen context. Validate accessibility and performance, not only screenshots. Changes to shared styles require checking every consumer family, including native bridges. Preserve tests for interaction contracts; do not add tests that merely assert a padding constant.

## Research basis

Apple documents the primitives below; the layered folder arrangement and adoption rules above are this project's recommendation, not an Apple-mandated architecture.

- [View styles](https://developer.apple.com/documentation/swiftui/view-styles): built-in/contextual styles and scoped propagation.
- [ButtonStyle](https://developer.apple.com/documentation/swiftui/buttonstyle): custom appearance with standard interaction; avoid primitive interaction replacement when unnecessary.
- [Reusable modifiers](https://developer.apple.com/documentation/swiftui/view/modifier(_:)): collect repeated view configuration.
- [EnvironmentValues](https://developer.apple.com/documentation/swiftui/environmentvalues) and [Entry](https://developer.apple.com/documentation/swiftui/entry()): typed subtree configuration.
- [Applying Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views): native/custom materials and grouping related effects.
- [SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance): measure expensive/frequent updates and their dependencies.

Reviewed October 3, 2026. Verify API availability against the shipping SDK before implementation.

## Implementation verification

Reviewed Apple's current documentation on October 4, 2026: [`glassEffect(_:in:)`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) requires macOS 26 and anchors the material to the view bounds. [`scrollContentBackground(_:)`](https://developer.apple.com/documentation/swiftui/view/scrollcontentbackground(_:)) can hide the native list background, allowing one stationary provider-directory surface. [`ViewThatFits`](https://developer.apple.com/documentation/swiftui/viewthatfits) selects the first layout whose ideal size fits the requested axes; task actions use horizontal and then vertical layouts. The latter two APIs support macOS 13 and therefore the app's macOS 14.2 minimum. Documentation was read from Apple's linked Markdown representations.

API availability and source review do not establish visual or accessibility correctness. Validate the production components in Preview, including long status text, action wrapping, keyboard selection, both appearances, and material accessibility fallbacks. Record build, screenshot, runtime, and performance results in the refresh worklog rather than inferring them from these contracts.
