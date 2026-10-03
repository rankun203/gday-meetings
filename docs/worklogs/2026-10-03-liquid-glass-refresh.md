---
title: Liquid Glass appearance refresh proposal
date: 2026-10-03
updated: 2026-10-04
status: proposed
scope: swift-app-design
---

# Liquid Glass appearance refresh

## Problem and evidence

The current layout makes navigation, meeting selection, reading, and playback available together. Preserve that work. The supplied screenshots show a visually heavy sidebar, strong column boundaries, broad control backgrounds, and a full-width player attached to the window edge. A clicked content tab retains a rectangular focus outline. These details make the chrome compete with meeting content.

Reviewed the seven user-supplied screenshots: current app, App Store, Apple Music navigation and player, Infuse, and the tab focus state. They are visual evidence only; no private screenshot or meeting content is included in the repository. Smooth Apple Music scrolling is a user observation, not a benchmark or proof of its implementation. No running-app performance measurements were made for this proposal.

The existing [UI design guide](../../apps/client-macos-swift/docs/UI_DESIGN.md) already calls for Liquid Glass. This proposal makes that direction concrete while preserving the main navigation and meeting layout. Source inspection confirms native table-backed meeting and transcript lists, a custom library shell, existing glass content tabs, and a macOS 14.2 deployment target.

## Proposed design

Use glass for navigation and persistent controls; keep reading surfaces quiet and opaque. Preserve all five destinations, the meeting list, the detail pane, the toolbar actions, and the player. Do not convert meetings to cards or an album grid.

| Area | Proposed appearance and behavior |
| --- | --- |
| Sidebar | An inset rounded navigation surface with a restrained native material. Place the library search input at the top, above Meetings, following the supplied App Store reference. Search retains its meeting/transcript scope across destinations; it does not silently become a People or Tasks filter. Use a soft neutral selected background and accent icon/text. Retain existing symbols, labels, collapse behavior, and accessible selected state. Size the field to the sidebar without widening it unnecessarily. Avoid adding a decorative outline when the native material already defines the edge. |
| Window toolbar | Keep the existing logo, title, sidebar toggle, recording, import, folder, and overflow actions. Remove the expanded search field from the toolbar. When the sidebar is collapsed, expose a search button that reveals it and focuses its search field; the existing search shortcut does the same. Preserve the query, results, and selection through collapse/expansion. Group related native controls with consistent spacing. Keep recording red and easy to find. Preserve active/inactive dimming and stable positions during sidebar transitions. |
| Meeting list | Keep dense reusable rows on an opaque surface. Use a quiet selection tint and lighter separators only where needed. Preserve date/duration, playback indicators, and the existing optional one-line summary title without leading heading markers. Do not increase row height for decoration. |
| Meeting detail | Preserve header, language, tags, and content order. Keep the title play button compact. Replace harsh boundaries with spacing or semantic separators. Use system typography; do not reduce transcript contrast to make the interface softer. |
| Content tabs | Retain Transcript, Notes, Summary, and Data Privacy in one compact rounded control. Selected fill communicates the active tab; a separate focus indicator appears for keyboard navigation. Avoid stacking a new glass surface over existing glass. |
| Processing controls | Keep re-transcription and transcript history adjacent to the transcript. Use native control sizing and hierarchy so these secondary actions do not dominate the page. Preserve provider names and explanatory source/status text when needed. |
| Player | Float one wide rounded material surface approximately 12 points inside the window edges. Span the window, including beneath the sidebar, to preserve waveform width. Retain title, playback state, skip controls, waveform, elapsed/remaining time, speed, and track selector. Keep at least the existing waveform width minus the small outer insets at the same window size. |
| Expanded tracks | Expand above the transport within the same player region. Keep microphone and system tracks aligned to one timeline, with existing mute and file actions. Recompute content clearance so the player never hides the last readable row or a focused control. |

The player belongs to the window shell and persists across Meetings, People, Tags, Tasks, and Agents. Navigation must not recreate the playback session or reset position. Clicking the playing title still locates its meeting. Task status remains independent and must not move transport controls on each update.

At narrow widths, truncate the player title first and move secondary actions into an accessible menu before reducing waveform space. Preserve all actions and existing minimum window usability. Exact breakpoints and native material shapes must be verified in Preview; the concept is not a pixel specification.

## Search in the sidebar

The search input stays at the top of the sidebar. Typing edits a draft query; it does not filter or replace the current screen. Pressing Return submits a nonblank trimmed query and opens a dedicated **Search Results** page in the main content area, replacing the meeting list and detail region while retaining the sidebar and persistent player. Do not create a second window or add a permanent sidebar destination for every search.

Show the submitted query, result count when known, and reusable result rows with meeting title, date, and relevant matching excerpts. Transcript matches include a timestamp. Keep draft and submitted queries separate: editing the field must not relabel old results as results for the new draft. A subsequent Return submits the new query, cancels or supersedes old work, and resets the results viewport. Clearing the draft alone does not discard the currently displayed results. Submitting an empty query performs no search.

Opening a result reveals its meeting and relevant content; a transcript result positions the matching passage without starting playback. Provide **Back to Search Results**, restoring the submitted query, selection, and viewport. Choosing a sidebar destination returns to normal navigation without stopping playback. Preserve the search session while navigating; a new submitted search replaces it.

Show **Searching…**, an empty-result message containing the submitted query, and a recoverable error with **Try Again** as distinct states. Page results from the index; do not load every transcript or scan files on the main thread. Keep keyboard focus predictable on submission, announce completion to VoiceOver, and support keyboard traversal/activation of results. Ensure the collapsed-sidebar search button and existing search shortcut reveal and focus the same field without submitting a query.

Validate Return submission from every destination, rapid successive searches with out-of-order completion, empty input, no matches, errors, result opening/back navigation, paging, and uninterrupted playback. Search results must meet the same large-library scrolling requirements as the meeting list. This is a proposed interaction change in addition to the appearance refresh; the generated meeting-screen concept does not demonstrate the results page.

## Pointer selection and keyboard focus

Clicking a tab selects it and leaves the selected fill, without a persistent keyboard focus border. Tab or Shift-Tab navigation restores a visible focus indicator; keyboard activation must work according to the chosen native control's semantics. Moving from keyboard navigation to a pointer click should remove the keyboard-only decoration without disrupting selection or editing.

Prefer native input-sensitive focus behavior. Reproduce the current custom button behavior before choosing an implementation. Do not apply unconditional `focusEffectDisabled`, remove keyboard focusability, clear the entire window's first responder, or install a global keyboard monitor merely to hide the ring. If local input tracking is necessary, scope it to the tab control and verify Full Keyboard Access and VoiceOver. Selection and accessibility focus must remain available regardless of the decorative ring.

## Smoothness is a release requirement

Retain native reusable table cells, stable identities, paging, and bounded prefetch. Do not replace the lists solely to achieve a visual style. Keep decoding, storage reads, summary extraction, and expensive text measurement off the scrolling path. Cache measurements by content and width, with bounded invalidation. Keep playback updates limited to the waveform and affected transcript rows.

Avoid glass, blur, shadows, or animated materials on individual meeting/transcript rows. Use a small number of stationary chrome surfaces. Group related custom glass effects with the supported native container where appropriate. Measure render cost before and after; an attractive still image does not establish smoothness.

Proposed acceptance targets, to be measured rather than claimed:

- Compare the same release build configuration, Mac, display refresh rate, window size, and scripted interactions before and after. Record cold and warm runs separately.
- Use synthetic libraries of 1,000 and 10,000 meetings and a long transcript with 10,000 segments, including overlapping sources. Exercise People, Tags, Tasks, Notes, and Summary with representative large fixtures too.
- Capture repeated 30-second scroll runs while idle, playing, and receiving synthetic live transcript updates. Target 95th-percentile frame time within the display budget (16.7 ms at 60 Hz; 8.3 ms at 120 Hz where supported), and investigate every UI stall exceeding 100 ms. Report missed-frame and hitch measurements, not average FPS alone.
- Require no regression in scroll hitch rate, first usable content, or navigation response against baseline. After repeated navigation/scroll cycles, retained memory must settle rather than grow with every visit. Record CPU, memory, and render traces alongside perceived responsiveness.
- Preserve viewport and selection during paging, tab switches, sidebar collapse, and player expansion. Check scrolling while scrubbing and while both audio sources highlight. Do not gain speed by dropping transcript updates or hiding content.

Use the existing [performance testing guide](../../apps/client-macos-swift/docs/PERFORMANCE_TESTING.md). Test actual playback separately from synthetic Preview before claiming end-to-end playback performance.

## Accessibility and compatibility

Respect light/dark/system appearance, inactive windows, Reduce Transparency, Reduce Motion, Increase Contrast, Full Keyboard Access, and VoiceOver. Use semantic colors and an opaque fallback when required. Recording, selected navigation, mute state, and overlapping playback must be distinguishable without color alone. Keep the established player hit targets and readable text sizes.

Keep macOS 14.2 support. Use current public native APIs with availability checks; older systems receive ordinary native materials and controls, not a custom simulation of Liquid Glass. Verify the shipping SDK and runtime availability during implementation. Do not change window architecture just to copy the App Store's traffic-light placement; preserve the current stable toolbar unless a native prototype proves equivalent behavior.

Apple references reviewed October 3, 2026:

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass): native components and system appearance preferences.
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views): custom effects and grouping for rendering performance.
- [Focus effect control](https://developer.apple.com/documentation/swiftui/view/focuseffectdisabled(_:)): controls focus decoration; it is not by itself an input-modality solution.

## Delivery sequence and validation

1. Capture the current isolated Preview in active/inactive, light/dark, pointer/keyboard states, plus scrolling baselines. Fix tab focus behavior as a small independently validated change.
2. Implement the sidebar search field and dedicated results flow, then prototype sidebar, toolbar, and dividers using native materials. Compare density, navigation, search, menus, window resizing, and sidebar transitions with the baseline.
3. Restyle the persistent player and expanded tracks. Verify every destination, seeking, keyboard controls, task status changes, small windows, and content clearance.
4. Run the accessibility and performance matrix, release build, relevant tests, formatting, and macOS CI. Keep or revise each effect based on the evidence.

Each implementation step needs before/after screenshots and accurate limits in its worklog. This proposal does not authorize performance claims based on visual review alone.

## Implemented solution and results

Created the proposal, shared theme standard, source inventory, and screenshot audit. Removed the generated concept section, image and unused generation prompt at the user’s request; the written specification and real-app captures are the design references. The Swift app’s AGENTS.md now requires the standard across all screens and components. No application code or released behavior changed in this task. A fresh isolated release build was used for the audit; validation and limits are recorded below.

## Reasoning

Concentrating the refresh on chrome preserves the established reading workflow and dense lists. The broad floating player adopts the visual separation of a modern media transport while retaining the app's waveform advantage. Native materials and existing table reuse reduce the risk of introducing an expensive custom rendering system.

## Technical debt

No implementation shortcuts or schema debt introduced. Existing appearance duplication and the pointer focus issue remain until migration; this documentation task establishes their shared replacement contracts rather than adding another component layer. Their consequence is continued visual inconsistency in the current app. Remediation is the staged theme adoption above, beginning with input-modality focus. The planned older-system fallback remains a supported-platform requirement. Preview provenance is still manual; add a visible build revision/time and a production-component gallery during the Preview follow-up so stale builds and missing states are easier to identify.

## App-wide theme decision and audit expansion

The refresh is an app-wide theme and set of UI practices, not a one-screen redesign. The durable [shared theme](../../apps/client-macos-swift/docs/UI_THEME.md) is now referenced by the Swift app's `AGENTS.md` and applies to all current and future screens, nested components, dialogs, menus, warnings, and AppKit bridges. The component matrix below extends the shell proposal to the full app.

### Recommendation after research

Use native controls plus semantic values, scoped style protocols, reusable visual modifiers, and composed components. Use a components folder for meaningful repeated structures/behavior, not a new wrapper for every standard control. Use `ButtonStyle` for button appearance, `DisclosureGroupStyle` for disclosure behavior/presentation, and ordinary native toggle/picker styles wherever they fit. Use a modifier for an independent presentation policy such as material fallback. Use a real component when a unit combines layout, accessibility, state, or multiple controls. Keep domain models out of the theme.

A small typed environment value is appropriate for configurable subtree policy; immutable constants are sufficient for fixed spacing or app-specific metrics. Existing system environment values should drive appearance and accessibility. A global observable theme object and bindings for every style are unnecessary here and risk broad invalidation. AppKit tables, text views, and waveform renderers need the same semantic palette and explicit appearance refresh; SwiftUI modifiers alone cannot theme their internal drawing.

This recommendation follows Apple's documented [contextual styles](https://developer.apple.com/documentation/swiftui/view-styles), [standard button interaction with custom appearance](https://developer.apple.com/documentation/swiftui/buttonstyle), [reusable modifiers](https://developer.apple.com/documentation/swiftui/view/modifier(_:)), and [typed environment configuration](https://developer.apple.com/documentation/swiftui/environmentvalues). Apple does not mandate a components-folder architecture. The folder layout in the theme guide is a project choice. Use [Instruments](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance) to verify update costs and [native glass grouping](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) only where needed.

### Inventory method

The [source inventory](../design/2026-10-03-ui-source-inventory.md) indexes all 55 UI Swift files plus the application entry point, including literal control/text expressions and snapshot hashes. It includes in-progress voice review work from the working tree. It is a mechanical completeness aid, not a claim that every dynamic label or conditional state was visible. The matrix below defines current versus target design for the complete set of component families. Runtime screenshot coverage is recorded separately. User content is never used as a design fixture.

### Current and target component matrix

| Component and source owner | Current design | Required shared design and variants |
| --- | --- | --- |
| Window shell, `LibraryView` | Custom horizontal layout; fixed sidebar; resizable meeting/detail split; unified toolbar; bottom player/status. | Retain architecture and stable widths/identity; inset navigation material, subtle separators, persistent wide player. Cover expanded/collapsed, resized, active/inactive, every destination. |
| Toolbar logo/title/sidebar button | Template logo and semantic active/inactive title; icon toggle and action groups. | Preserve logo and dimming. Common title/action sizing and native grouping, no custom duplicate title bars. |
| Global search | Toolbar text field filters meetings. | Sidebar input with Return submission to a dedicated results page; draft/submitted distinction, loading/empty/error/results, back restoration, collapsed-sidebar entry. |
| Meeting list, `NativeMeetingList` | Reused AppKit table cells, title/date/duration, optional one-line summary, archive/playback indicators. | Preserve density/paging and optional summary behavior; semantic selection/hover, no row glass. Include empty/loading/page error, playing/paused/archive variants. |
| Meeting title, `MeetingTitleView` | Single truncated title; native inline edit; play circle; date, duration, language, tags. | Shared title/body/metadata roles; compact play; stable editing geometry; full accessible value. Preserve double-click, Return/Escape, Finder action. |
| Content navigation, `MeetingContentTabs` | Custom buttons in capsule glass, quaternary selected fill; action explicitly assigns focus. | Shared tab component with pointer/keyboard distinction; capsule selected state, hover/disabled/inactive states, arrow/Tab access. Do not globally disable focus. |
| Notes edit/read picker | Small native segmented icon picker. | Keep native segment behavior; consistent selection and icon help; align with content action row. Edit/read are modes, not extra document tabs. |
| Transcript shell, `MeetingTranscriptView` | Provider-dependent action, history menu, provenance/warning text, speaker labeling actions. | Quiet secondary action row, shared status/recovery messages; preserve single/multiple/missing-provider and pending/resume/replace/discard states. |
| Transcript rows, `NativeTranscriptView`, `TranscriptRow` | Timestamp, speaker chip, wrapping text; reusable native rows; inline editor; overlapping blue highlights and neutral hover. | Shared timestamp/body/palette tokens, native selection/editing; maintain overlap and gap correctness. Cover pending/final words, unknown speaker, manual/automatic attribution, hover, editing, paused and playing. |
| Speaker chips/picker, `TranscriptSpeakerPicker` | Color-coded assigned/dotted unassigned chips; popover search, assignment scope checkbox, create/remove actions. | Common chip metrics and scoped search; readable assignment state beyond color; full keyboard/VoiceOver use. No hidden persistent selection masquerading as playback. |
| Tags and speaker disclosures, `MeetingAssociationsView`, `PersonTagsView` | Rounded removable tags, add menu, toggle choices, creation sheet; speakers disclosure and assignment menu. | Shared chip, disclosure, menu and sheet contracts; adequate removal targets; empty/multiple/long-name variants. |
| Markdown editor, `MarkdownNotesEditor`, `NotesImagePresentation` | Native text view, styled Markdown, timed gutter, images/resize UI, formatting/menu actions, undo and selection. | Shared document palette/typography; opaque surface; theme changes preserve caret, IME, undo, scrolling, image aspect ratio, and source text. Include empty, long, read-only, image, code/list/task/link/table variants. |
| Markdown viewer, `NativeMarkdownReadingView` | One selectable native document with headings, lists, tables, code/copy, task toggles, links, images and optional timestamps. | Same document roles as editor, continuous selection, accessible inline controls, bounded layout updates. Use for Notes, Summary and Agents rather than separate visual renderers. |
| Summary workspace, `MeetingDetailView` | Generate/regenerate action with selectable Markdown, streaming status and empty/error states. | Shared content header and feedback; readable streaming output without rebuilding all chrome; maintain selection/viewport. |
| Meeting privacy, `MeetingDataPrivacyView` | Storage/file rows, paths, reveal buttons, processing destinations/status. | Shared information rows with readable technical details; actions align consistently; distinguish missing, local, remote, incomplete without color alone. |
| Archive indicators, `MeetingArchiveStatusView` | Compact list icon and detail status with optional archive action. | Reuse semantic status icon/text/help; keep action separate from state; cover absent, complete, incomplete, unavailable, working/error. |
| Player, `MeetingPlayerBar` | Full-width attached bar; title, transport, waveform, times, speed, tracks, close; expandable tracks. | Single wide floating material region with clearance; keep large waveform, 44-point targets, persistent navigation state, compact/expanded and narrow variants. |
| Waveform, `WaveformTimeline`, native surfaces | Custom seek/scroll surface, native drawing, playhead and elapsed/remaining labels. | Shared accent/unplayed/disabled colors, stable timeline and keyboard focus; no per-bar glass or global clock invalidation. Loading/unavailable/blocked states remain explicit. |
| People list, `DirectoryViews` | New-person input and add icon, selectable list, delete, Show Excluded checkbox, Review Voices action. | Shared directory header/input/list/actions; scope exclusion clearly; preserve native keyboard selection and empty state. |
| Person details, `ContextDetailView` | Name/email/multiline notes, tags, recognition exclusion, voice samples, associated meetings and question composer. | Common form rows, section headings, status, paging and chat composer; preserve compact editable/contact semantics. |
| Tags directory/details | New-tag field, inline editable names, delete confirmation, associated meetings and questions. | Same directory/list/form patterns as People; no second set of list selection colors. |
| Voice review, `VoiceLibraryView` (in-progress source) | Sheet with Review/Unnamed/Named/All segments, group list, evidence cards, selection/actions, Undo/Done, preparation disclosure. | Shared segmented/list/empty/status and sheet styles; readable evidence, explicit selection scope, persistent excerpt control. Keep review meaning separate from visual selection. |
| Voice samples and assignment | Person sample rows; excerpt play/open, confirmation/rejection, combine/separate/exclude; person search/create sheet. | Shared row transport and status; unavailable-range explanation; same person picker conventions. Confirmed/suggested/rejected/excluded states must remain distinct. |
| Voice preparation | Provider picker, prepare/discover actions, progress, pause/resume/retry and failure text. | Common job/progress/recovery controls; no theme-driven inference/download. Include missing provider/model/audio and recording-blocked states. |
| Tasks, `TaskQueueView` | Large title, summary, Needs Attention/Other Tasks/Other Activity sections, progress/error text and action rows. | Shared screen heading, job rows, status and action hierarchy; allow long failures/action wrapping. Running/queued/expired/failed/completed/cancelled variants. |
| Task status strip | Conditional bottom status with counts, review/navigation buttons. | Quiet common status region separate from player; avoid shifting transport on progress ticks. Hidden when no relevant work. |
| Agents, `AgentsView` | Full-width native Markdown viewer, loading/error/retry. | Same document typography/reader as other screens; consistent margins and status component. No bespoke HTML or second Markdown renderer. |
| Settings tabs, `SettingsView` | Native General/Service Providers/Data/Data Privacy tabs; grouped form; fixed initial window size. | Retain native settings navigation, common form rhythm, scrolling and keyboard behavior; no glass behind every group. |
| General settings | Two columns in one scroll region; Record/Recording/After Recording/General sections, switches, readiness, capability menus, language, appearance and summary-title preference. | Shared labeled setting row, native switches/pickers, multiline help/status alignment. Cover on/off, ready/missing/checking/unhealthy/inconclusive and dependent disabled options. |
| Service provider directory | Provider list, add menu/removal, detail forms and save/check actions. | Same directory/form/action hierarchy as other screens; preserve selected draft state and connection feedback. |
| Remote provider form | Name/enable, endpoint, secure API key, model combo, image input, upload provider, capability toggles, summary prompt, save/check. | Shared labeled field/help/validation and section patterns; secure input remains native. Provider-specific fields compose common rows, not duplicate visual primitives. |
| Website provider | URL, sign-in/out and account/status, language loading. | Native account actions and status; no simulated account screen; browser flow remains external. |
| This Mac provider | Local transcription switch, readiness explanation, speech model rows, installed/unavailable/download/progress. | Shared capability/status/model rows with consistent explanatory text. Do not restyle native download actions into decorative badges. |
| Local speaker providers | Name/enable/capabilities, preset, buffering/help, model readiness, save, download/verify/remove/manual installation. | Shared model card, status/progress and disclosure; preserve download/cancel/retry/in-use distinctions and readable paths. |
| Data settings | Folder/path/reveal/change, migration status/cancel/restart, index counts/rebuild/errors. | Shared information/settings/status rows; selectable paths, clear deferred-change state, native folder/confirmation panels. |
| Global privacy | Data categories, storage and destinations, notes, export logs. | Same information rows as meeting privacy; consistent heading/caption/action hierarchy and empty destinations. |
| Recording setup | Sheet with title/language, source switches/device menu, format/processing options, readiness/errors, Cancel/Start. | Shared field/source row/disclosure/action contracts; recording primary action stays prominent; pending/permission/error/disabled variants remain clear. |
| Active recording workspace | Title, timer, source meters, notes, live transcript, settings disclosure, Stop & Save and recording strip. | Common recording surface and source control pattern, red state plus text/symbol; quiet document surfaces. Keep meter ticks local. |
| Live transcript/header | Transcribe/Label Speakers switches, provider/lag/warnings, Follow Live, interim/final/editable passages. | Same transcript renderer and status patterns; interim state legible without excessive motion. Shared issue details/recovery; preserve follow/manual-scroll behavior. |
| Model combo, `ModelComboBox` | AppKit editable combo with available/custom model choices. | Preserve native text entry and choices; share input metrics/colors with SwiftUI form fields; loading/empty/error variants. |
| Buttons (text/icon/destructive/default/cancel) | Native plus `ActionButtonStyle` and playback-specific hover/glass; varied local frames. | Native semantics plus scoped styles; standardize named roles/targets, no one-size-fits-all global style. All normal/hover/pressed/disabled/focused/inactive variants. |
| Labels, titles, help, warnings | System fonts with local title/headline/caption choices; some red/orange inline text and selectable errors. | Semantic typography and shared feedback; preserve exact meaning/provider/destination context; never rely on color alone. Review surrounding wording, not only button labels. |
| Inputs and selections | Single/multiline text, secure fields, search, popup menus, segmented pickers, switches, checkboxes. | Native editing and accessibility; consistent label/help placement and disabled/invalid state. Style selection controls by semantics, not a blanket glass wrapper. |
| Disclosures and sections | Shared `AppDisclosureStyle` plus specialized recording settings. | One full-row hit target and shared rhythm/chevron/state; specialized content composes the same header contract. |
| Alerts/confirmations | Native errors/permission retry/trash/provider removal/tag/person deletion/transcript replacement and pending discard. | Keep native presentation, roles, Return/Escape and precise consequence/recovery wording; no custom theme modal. |
| Import/export/open/save panels | Native Finder panels plus text-export format accessory; image save name prompt. | Keep system UI; align custom accessories with native labels/control sizes. Do not recreate file browsing. |
| Menu bar/commands/context menus | Native application menus, playback/format commands, meeting actions and system tray entry. | Consistent names, SF Symbols, shortcuts, enabled states; OS owns appearance. Keep context actions discoverable through keyboard/accessibility. |
| Empty/loading/error/permission states | Local placeholders, progress indicators, inline errors, native alerts and retry/setup actions. | One semantic feedback vocabulary, task-specific message and action; no promotional filler, layout jumping, or spinner without context. |
| Preview-only controls | Banner, appearance/scenario selector, synthetic meter disclosure and fixture actions. | Clearly separate testing chrome from product UI; actual screen/component types must be identical. A future gallery composes production components only. |

### Migration guardrails

The audit and theme are documentation work, not a completed app restyle. Adopt shared values/styles first, then migrate one component family at a time and verify all consumers. Search results is a new screen and must be designed with the same list/status contracts. Do not commit unrelated in-progress source changes as part of this documentation task. Existing renderer/layout duplication should be assessed during each migration rather than hidden by creating an additional wrapper layer.


### Screenshot audit and build provenance

Captured and inspected the following **34 screenshots** on October 3–4, 2026. They cover every primary navigation destination, all four meeting tabs, all four Settings tabs, all seven provider families, recording setup and the active recording workspace, plus important nested views. These are current production view types with synthetic data, not generated concepts or a separate implementation of the UI.

The audit used a fresh source snapshot taken when `master` was at `5cf3ba3`, including then-current uncommitted voice-library work. The source inventory records the reviewed file hashes. Another task committed voice-library work and continued editing while this audit ran; these screenshots are a fixed build snapshot, not a claim to include changes made after the snapshot. New voice-detail/recovery components added subsequently must be audited against the same theme in their owning worklog.

- Build: `make build-macos-preview` in `/private/tmp/gday-theme-audit`; its script calls the production release build and copies that app into the Preview bundle. Build completed in 198.78 seconds; Info.plist validation and signing succeeded.
- Executed bundle: `/private/tmp/gday-theme-audit/apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app`. The development bundle and real library were not used for the captures.
- Runtime: macOS 26.6.2 (25G83), arm64; Apple Swift 6.4 (`swiftlang-6.4.0.34.1`). Build completed late October 3; the audit continued after midnight October 4.
- Executable SHA-256 after fixture bundle signing: `cee7f32d706cb7117ae49ab4b28d0ec2f02f67bb7dc88cff63aa6c7aeee54d6c`.
- Fixtures: `GdayUIPreview=true` throughout. Captures 31–34 also use supported `GdaySyntheticLiveRecording=true` and `GdaySyntheticTasks=true` bundle flags. Only the isolated bundle’s fixture metadata/signature changed; no product source was edited. Synthetic recording does not capture hardware audio.
- Captures 01–29 use Light appearance; 30–34 use Dark. The preview banner is test chrome. Some dark recording captures show the inactive-window variant, including dimmed branding. Window sizes and fixture content differ from the user’s screenshots, so this is a component baseline rather than a pixel comparison against private content.

Why Preview can look old: `scripts/preview-macos.sh` copies the **same built app**, changes its bundle identity, and enables `UIPreview`. `PreviewContainer` adds the banner, appearance selector and synthetic visualization. The product screens are shared. Two Preview instances were already running at audit start, including an older isolated validation copy. A running copy does not refresh when a different bundle is rebuilt. This establishes a stale-bundle risk, but does not prove which copy the user previously saw. Different fixtures, appearance, provider readiness and window sizes also alter the visible layout. Always rebuild and launch the exact bundle path; keep fixture UI separate from product UI and never maintain lookalike preview widgets.

### Screenshot index

The captures are retained locally under `docs/design/assets/2026-10-03-ui-audit/`, which is ignored by Git. The table preserves their filenames and evidence notes for review; images are not repository deliverables. The component matrix above specifies the corresponding target.

| Capture | Current elements and state |
| --- | --- |
| 01 · Meeting transcript · `01-meeting-transcript.png` | Three-column shell, toolbar search, header/title/language, tags, content tabs, provider setup/history, timestamp/speaker/text rows, archive warning, paused transport. |
| 02 · Notes editor · `02-notes-editor.png` | Native Markdown source, timed gutter, embedded image, edit/read segment; clicked Notes tab retains a rectangular focus ring. |
| 03 · Notes reader · `03-notes-reader.png` | Selectable reading document, headings, timestamp links, bullets/tasks and image; missing visible list text needs separate reproduction. |
| 04 · Summary · `04-summary.png` | Heading hierarchy, paragraph/list/task/table content, mixed-language text, timestamp links and summary actions; clicked tab focus ring. |
| 05 · Meeting privacy · `05-meeting-privacy.png` | File-event information, disclosures, paths, local/remote destination text and reveal actions. |
| 06 · People · `06-people.png` | Directory input/add/list, editable name/email/notes, tags, voice examples, exclusion checkbox, associated meetings and question input. |
| 07 · Voice review · `07-voice-review.png` | Sheet title, Review/Unnamed/Named/All segments, group selection, evidence cards, selection actions, Undo and Done. |
| 08 · Voice preparation · `08-voice-preparation.png` | Expanded preparation disclosure, provider picker, disabled prepare/discover actions and explanatory text. |
| 09 · Voice assignment · `09-voice-assignment.png` | Nested sheet with person search, selection rows, create/assign controls and Cancel. |
| 10 · Tags · `10-tags.png` | Directory, editable tag, exclusion checkbox, associated meeting list and scoped question composer. |
| 11 · Tasks empty · `11-tasks-empty.png` | Screen heading and empty-state explanation; persistent paused player. |
| 12 · Agents · `12-agents.png` | Production Markdown reader, code blocks and Copy Code buttons; synthetic library guide. |
| 13 · General top · `13-general-top.png` | Grouped two-column form, recording sources/format/processing, automation switches/readiness, capability selectors. |
| 14 · General bottom · `14-general-bottom.png` | After Recording switches and readiness; language, Appearance and Display Summary Title on Meetings preferences. |
| 15 · This Mac provider · `15-this-mac-provider.png` | Local transcription capability, readiness, installed/unavailable language-model states and download controls. |
| 16 · RunPod provider · `16-runpod-provider.png` | Name/enabled state, endpoint, secure credential field, upload provider and inline validation. |
| 17 · RunPod bottom · `17-runpod-bottom.png` | Capability switches, language state, Save and Check Connection actions. |
| 18 · Filedrop provider · `18-filedrop-provider.png` | Connection fields, endpoint validation, enable/save/check and file-transfer capability. |
| 19 · LLM provider · `19-llm-provider.png` | Endpoint/credential/model combo, image-input options and summary prompt section. |
| 20 · LLM bottom · `20-llm-bottom.png` | Multiline prompt editor, Restore Default state, capability switches, Save and Check Connection. |
| 21 · Website provider · `21-website-provider.png` | HTTPS URL validation, disabled browser sign-in, capabilities, languages/load and save/check actions. |
| 22 · Nemotron provider · `22-nemotron-provider.png` | Enable/capabilities, missing-model readiness warnings, preset and latency/channel explanations. |
| 23 · Nemotron installation · `23-nemotron-installation.png` | Model size/download/open/refresh, expanded manual-installation disclosure, file link and disabled Save. |
| 24 · Community-1 provider · `24-community-provider.png` | Recorded labeling/association capabilities, missing-model warnings and preset/download controls. |
| 25 · Data settings · `25-data-settings.png` | Synthetic folder path, Change Folder/Show in Finder, index size/rebuild and library counts. |
| 26 · Privacy settings · `26-privacy-settings.png` | Data-category icons, descriptions, storage rows and separators. |
| 27 · Privacy bottom · `27-privacy-settings-bottom.png` | Voice/credential/settings/log categories, log explanation and Export Logs action. |
| 28 · Recording setup · `28-recording-setup.png` | Sheet title/help, title input, language/info, source switches/device selector, expanded format options and Cancel/Start. |
| 29 · Expanded player and speakers · `29-expanded-player-speakers.png` | Speaker assignment menus; wide master waveform, source waveforms/mute buttons, speed and track menus. |
| 30 · Dark meeting · `30-dark-meeting.png` | Dark counterparts of transcript, tags, tabs, speaker assignment and expanded transport; semantic colors and selection. |
| 31 · Active recording · `31-active-recording.png` | Synthetic timer/Stop & Save, source meters/mute, collapsed settings, live switches/follow, interim/final transcript and task strip. |
| 32 · Recording settings · `32-recording-settings.png` | Expanded language, processing switch, tags and recording header; reduced transcript viewport. |
| 33 · Tasks populated · `33-tasks-populated.png` | Attention/expired/failure and queued cards, descriptions, warnings, Restart/Retry/Open/Dismiss/Run Next; persistent recording strip. |
| 34 · Tasks progress and completed · `34-tasks-progress-completed.png` | Running progress/spinners, Stop Waiting explanation, completed state, dismiss actions and bottom recording/task strips. |

### Findings and limits

- **Focus:** pointer-selected Notes and Summary retain a rectangular blue outline in captures 02–04. Source assigns the focused tab in the button action. The proposed shared tab contract must separate keyboard focus from pointer selection while preserving Full Keyboard Access and VoiceOver. This task documents the issue; it does not fix it.
- **Reading correctness:** capture 03 shows list markers without their expected visible text, while accessibility exposed the text. Reproduce against the same synthetic document and inspect native layout/invalidation before migration. Do not mask this with color changes or claim the Markdown renderer passed visual validation.
- **Visual consistency:** dense tables, large task cards, grouped Settings forms and nested voice sheets use different local spacing, headings and feedback treatments. Keep their appropriate native structures, but align semantic typography, message hierarchy and shared composed rows. The theme is not a mandate to turn all content into cards.
- **Preview coverage:** every primary screen is represented, but not every conditional state. Signed-in accounts, network response/error variants, model downloads/removal, import/export and folder-migration dialogs, permission prompts, destructive confirmations, every context menu/popover, and every voice-review filter were not all captured. Their source controls are indexed and their required variants appear in the matrix. No provider job or model download was started for this audit. A production-component gallery and fixture matrix must cover these states during implementation.
- **Validation limits:** this is not a full light/dark, window-size, keyboard, VoiceOver, increased-contrast, Reduce Motion/Transparency, or macOS 14.2 matrix. No scroll/hitch benchmark was run; the performance targets remain acceptance criteria, not achieved results. The sidebar Search Results page is proposed and has no current screenshot.
- **Build warnings:** release build succeeded with copied-cache stale-path warnings and missing Command Line Tools linker search paths (`Developer/usr/lib` and `Developer/Library/Frameworks`). No API deprecation diagnostic was found in this build log. The initial copied module cache was not relocatable; clearing the isolated module caches allowed the build. Use a clean isolated cache for repeatable follow-up validation and resolve the local toolchain search paths. This build is not described as warning-free.

### Documentation validation

Reviewed the shared theme, surrounding AGENTS wording, component matrix, source inventory and screenshot captions against the writing guide. Checked synthetic content, front matter, local references and the scoped diff. Only written documentation belongs in Git; synthetic screenshot binaries remain local. Release compilation establishes that the audit app built; it does not validate the proposed redesign. No Swift implementation tests were added for this documentation change.


### Screenshot storage correction

The initial audit commit included 34 PNGs (about 7.9 MB). Removed them from the tracked tree at the user’s request, retained the local files, and ignored audit capture folders. The written inventory, observations and provenance remain. Earlier published history still contains the binaries; this correction does not rewrite shared history. Future UI validation captures should stay in ignored local storage unless the user explicitly requests that assets be committed.
