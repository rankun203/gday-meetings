---
title: UI design
date: 2026-09-26
status: active
scope: swift-app-ui
---

# UI design: Liquid Glass by default

Liquid Glass is the design standard for all future UI work in the Swift macOS client. Apply it when adding or revising screens and controls. This is a design policy, not a claim that every existing view has already been migrated.

## Appearance and hierarchy

- Use Apple's native Liquid Glass presentation for navigation and controls where supported. Keep meeting text, notes, transcripts, and waveform content on quiet, readable surfaces. Do not put glass behind every card or stack translucent layers unnecessarily.
- Voice Memos informs the navigation, list, detail, and playback hierarchy. Put the native segmented meeting-content selector in the window toolbar, where macOS 26 supplies its capsule group and neutral selected state. Inline tab views retain a legacy bezel on the supported system and do not provide this appearance. Use native sidebar selection and Gday's accent color. Retain a visible selected state when the window is inactive.
- Meeting sheets retain a standard inline segmented selector. This preserves their existing modal workflow; a nested navigation toolbar does not render in these sheets. Do not imitate window-toolbar glass inside the sheet.
- Meeting content tabs contain Transcript, Notes, and Summary. **Meeting Actions → Data Privacy…** opens the selected meeting's event history in a native sheet with **Done** and Escape dismissal. Opening or closing privacy history preserves the content tab and playback state. Settings retains its separate Data Privacy tab.
- Prefer standard SwiftUI/AppKit controls, SF Symbols, semantic colors, system typography, and system spacing. Use supported customization only when the native component cannot express the required interaction or visual hierarchy.
- Keep labels direct and concise: “Play,” “Recording transcript,” and meaningful source names. Avoid decorative explanatory text that repeats what the controls already communicate.
- Make recording actions easy to find and distinguish recording, saving, playing, and paused states through symbols and accessible labels as well as color.
- Give icon buttons a full-area hit shape, visible hover/pressed feedback, and a tooltip. Use at least 44×44 pt for player controls (including menu triggers and track mute buttons); keep symbols smaller inside the target. Apple's macOS accessibility table lists 28×28 pt default and 20×20 pt minimum, while general Buttons guidance recommends 44×44 pt hit regions. The minimum is not our target for frequently used controls. Hover feedback must not resize or move controls.

## Interaction and stable layout

The compact play/pause button beside the meeting title shows an accent-tinted circle and outline on hover, with a stronger pressed tint and a pointing-hand cursor. Draw this feedback above the glass material so it remains visible. Keep the button and title stationary during hover.

- Use one main Meetings window. **Show App**, recording setup, and reopening the app reveal that window instead of creating another. A closed main window can be reopened without restarting the app.
- Use native split navigation for the library sidebar and let the system coordinate its toolbar and column transition. Keep sidebar content available during expansion; do not add a second row-hiding animation. Rapid reversal and Reduce Motion must leave search and destination selection usable.
- Retain the system sidebar-toggle animation. Profile content reflow before replacing its timing curve; diagnostic programmatic visibility changes do not establish the native toggle's frame pacing.
- Open with the sidebar collapsed and the meeting list visible. List titles and scoped actions belong in the native column toolbar rather than a second heading row. Keep the circular recording control immediately before the upper-right search field. Selected meeting content retains its own title, tabs, and reading layout.
- **Add Meeting** belongs to the Meetings list column. Its menu offers **New Meeting Recording…**, **Import Audio or Video…**, then **New Meeting Notes**. Recording opens the existing setup sheet and is unavailable when a new recording cannot start. Keep archive import, library migration, and **Open Meetings Folder** in File. New notes open in Notes; adding a meeting never appends audio to a selected meeting.
- **New Recording…** opens recording setup from the toolbar, File, Recording, and empty states. During capture the toolbar becomes **Show Recording**, which navigates without stopping capture. The persistent recording strip retains **Stop & Save** while browsing elsewhere. Starting and saving have distinct disabled labels.
- Without a meeting selection, show **G’day** with “No meeting is selected.” and **New Recording…**. An empty library shows **No Meetings** in the list and **Create a Meeting** in detail, with recording, media import, and notes actions stacked vertically. Keep meeting content tabs hidden until a meeting is selected. Native toolbar layout and overflow handle available width; preserve the 900-point window minimum until a smaller layout is validated.
- Preserve native list spacing. Do not add compensating scroll insets or offsets to hide a layout issue; reproduce the cause and verify navigation, playback changes, and window activation.
- Keep playback updates local to the transport. Menus, text editing, selection, and the main content layout must remain stable while time advances.
- Center waveform and primary playback controls together, with time labels below. Every track shares one playback/scrubbing timeline.
- Two-finger waveform panning seeks without transferring keyboard focus. Keep the focus indicator when the waveform already has keyboard focus; Tab navigation and arrow-key seeking remain available.
- Muting a playback track also hides its attributed transcript passages for the player’s selected meeting, including while paused. Unmuting restores them. Keep other meetings and passages with unknown source metadata visible. If every passage is hidden, explain that unmuting a track restores its transcript. This is a display filter; saved text, history, and exports stay complete.
- Support keyboard navigation, visible focus, Space for playback outside text editing, and VoiceOver labels and selection state. Respect Reduce Motion, Reduce Transparency, and increased contrast; do not override system accessibility preferences to preserve an effect.

## Meeting title header

- Place the compact play/pause control immediately before the title, vertically centered in one row.
- Show the title as one line of plain text with tail truncation. For a stored multiline title, show its first line followed by an ellipsis; retain the complete saved title and expose it to accessibility and help.
- Double-click the title to edit. Enter commits, Escape cancels, and leaving the field commits. Keep edits in a local draft until completion rather than saving each keystroke. Provide **Edit Title** through the context menu and accessibility action.
- Command-click the title to open that meeting's folder in Finder. Provide **Open Meeting Folder** through the context menu and accessibility action. Keep ordinary clicks and the title layout unchanged.
- Normal reading must not expand header height for long titles. Show date and duration below the title; place language, tags, and archive details in **Details**. An incomplete archive must remain visible as an issue indicator on that control.

## Meeting list

At the end of each collection list, show its total for the current filters as a nonselectable scrolling footer. This includes Meetings, People, Tags, associated meetings, Tasks, voice groups and examples, service providers, privacy groups, and labeling history. Paginated lists show the indexed total only at the actual end; do not show the loaded page's row count as the total. Capped history uses “Entries Shown.” Search shows its count once in the header; it does not repeat the count in a footer. Privacy counts groups, because one event can belong to several groups. Refresh derived counts off the main actor when the index or filters change. Preserve existing empty states; document readers, transcripts, menus, and pickers do not need collection totals.

General settings includes “Display summary title on meetings,” enabled by default. When enabled, meeting rows show only the summary's first line, with leading `#` characters and whitespace removed, on one truncating line. When disabled or the first line is blank, omit that line and its extra row space. Keep the saved summary unchanged and preserve list selection and viewport when toggling.

## Meeting keyboard and Finder actions

- **New Recording…** in the File menu uses Command-N and opens the recording setup sheet. Cancel leaves the library unchanged; the command must not create empty meeting notes.
- Delete or Forward Delete while the meeting list owns keyboard focus opens **Move “title” to Trash?**. Return activates **Move to Trash**, and Escape activates **Cancel**. Describe recovery accurately; recording and active-task protections still apply.
- **Reveal in Finder** in a meeting’s context menu selects its storage folder. A normal click on the player’s meeting title locates it in the app; Command-click reveals its folder in Finder. Command-click on an expanded track name reveals that audio file. Keep the normal click behavior and expose the reveal action through accessibility and help.

## Task status bar

Show the bottom task status bar only while work is queued, running, or needs attention, including other background activity such as imports and archives. Completed, cancelled, and dismissed tasks do not keep the bar visible. Keep **Tasks** in the sidebar for history and management even when the bar is hidden.

Use a brief opacity transition when the bar appears or disappears, respecting Reduce Motion. Preserve the identities and scroll positions of the meeting list and transcript; only the bottom status row changes. Keep the player independent of task visibility.

## Transcript playback feedback

- Keep provider names inside the Transcribe or Re-transcribe menu. Label the history controls **Labelings** and **Transcripts** with distinct symbols and descriptive help. Native transcript scrollbars follow the system preference, including always-visible scrollers when requested.
- Highlight every transcript segment whose interval contains the current playback position, including overlapping sources and waveform seeking or scrubbing. Include the start and exclude the end; show no highlight during gaps. Keep the position highlights when paused; remove them when another meeting owns playback.
- Use an accent-tinted row for the playback position and a quieter neutral background for pointer hover. Clicking a row must not leave a persistent selection background that looks like the playback position.
- Use compact rounded speaker chips with a stable color for each person (or speaker label when unassigned). Fit the chip to its name inside the speaker column. Unassigned speakers have a dotted outline; automatically matched people count as assigned. Keep names readable and expose assignment state without relying on color alone. Badge colors do not indicate playback.
- Opening a meeting or returning to Transcript positions the viewport immediately after layout settles. Width changes preserve the visible passage without animating individual row heights. Only subsequent playback following animates the complete scroll surface.
- Follow the active segment smoothly, targeting about 30% of the transcript viewport height when the segment changes. Pause following for four seconds after manual scrolling, and while editing or assigning a speaker. A deliberate waveform seek brings the active passage into view. Cancel a follow animation immediately when manual scrolling starts; Reduce Motion uses immediate positioning.
- Keep playback transitions subtle and avoid changing text metrics or row heights. Update the old and new playback rows directly without rebuilding the transcript or remeasuring its text on each clock tick.

## Expandable sections

Use **Recording Options** as the reference for every labeled expandable section, including **Speakers**, **Recording Settings**, and preview sections.

- The chevron, complete label, and remaining header width form one button. Clicking anywhere in that row expands or collapses the section; do not require a precise click on the chevron.
- Show a subtle rounded background across the entire header on hover and a stronger pressed state. Feedback must not change spacing, size, or text alignment. Use semantic colors in light and dark appearances and preserve increased-contrast feedback.
- Keep the chevron and label leading-aligned. Use at least a 28-point header height; allow long labels to wrap. Expanded content appears below the header and keeps its own independent controls.
- Use `AppDisclosureStyle` for `DisclosureGroup`. A specialized header, such as Recording Settings with its folded summary, must retain the same full-row button and `ActionButtonStyle` feedback.
- Preserve native keyboard activation and focus, expose the label plus Expanded or Collapsed accessibility value, and respect disabled state and Reduce Motion. Never nest another action inside the disclosure header.

## Data folder changes

Settings → Data shows the current data folder, **Change Folder…**, and **Show in Finder**. Choosing an empty folder offers a verified copy that keeps the original; choosing an existing library offers opening it after restart. Never silently merge libraries or open an empty folder as though current data moved. Show progress and cancellation in the same section. After success, show the pending path and restart instructions with a way to cancel the pending selection. Suspend editing while copying or awaiting restart, and prevent starting a change during recording or background writes. An unavailable selected folder must remain recoverable through Settings without silently replacing it with a new library.

A custom folder retains authoritative files; its disposable index stays local to the Mac. Show that index path in Data settings. For iCloud Drive, explain that files must remain downloaded and the library should be used on one Mac at a time.

## API and compatibility policy

- Use the latest stable public APIs supported by the app's toolchain and target OS. Check Apple documentation and SDK availability before adoption; a newer SDK does not make an API available on an older running system.
- Preserve the deployment target declared in `Package.swift` (currently macOS 26). Use availability checks for APIs introduced after that minimum. Retain hardware, language, and accessibility checks independently of OS availability. Do not imitate glass with private APIs or require a developer account for local builds.
- There is no single public “Apple Music style.” Prefer native behavior; document any necessary custom control and its keyboard/accessibility obligations. A newer tab-picker API must not be presented as a way to change the appearance on an OS that cannot run it.
- Follow the repository's deprecation policy. Record necessary compatibility fallbacks and a concrete future removal condition in the implementation worklog.

## Validation for UI changes

Use `make start-macos-preview` for independent UI checks with an isolated library and synthetic fixtures. Preview avoids Keychain prompts, real capture, and hardware playback. It supports real provider checks and deliberately started service jobs with test credentials; opening or saving settings does not upload content. Verify the changed interaction in Light, Dark, and System appearance; small and large windows; active and inactive window states; and keyboard navigation. For navigation or player changes, also check sidebar transitions, persistent playback, menus, and multi-track scrubbing as applicable. Include accessibility preference checks when introducing custom material or animation.

Report passed, failed, and untested checks accurately. Preserve existing recordings and coordinate separately before testing real audio. See [UI Preview](UI_PREVIEW.md) and [audio design](AUDIO_DESIGN.md).

## Apple references

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), and [segmented controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls)
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

## Markdown reading

Hold Option on **Generate Summary** or **Regenerate Summary** to show the **with Notes…** action. It opens a native sheet with a **User Instructions** editor for that request, such as selecting the summary language. Cancel submits nothing. Instructions travel with the queued task and its retries; ordinary generation starts without them. Keep meeting notes and provider preferences unchanged.

Summary and Notes reading mode share one selectable document. Dragging or keyboard selection must cross paragraphs, lists, and table cells; do not split reading content into independently selectable labels. Use the Rust reader's GitHub Markdown hierarchy as the reference: restrained headings, comfortable line height, compact list spacing, light table borders, and quiet code backgrounds. Preserve native semantic colors in light and dark appearances.

Unordered lists use a 15-point bullet glyph beside 14-point body text, with an 18-point text inset. Align wrapped lines with the text, keeping the dot close to its item.

Render checked and unchecked task markers at the same 14-point size with a 22-point marker column. The complete wrapped task row is clickable and shows subtle rounded hover feedback with a pointing-hand cursor. A drag must select text instead of toggling; citation links and double-click selection take precedence. Completion persists into its Markdown source. Keep source text in reading mode otherwise read-only. Timestamps such as **[12:39]**, **[81:32]**, and **[1:21:32]** are playback links; a range uses its starting timestamp. Links have visible color and pointing-hand hover feedback. Inline code remains literal. Meeting tasks are presented through Markdown checkboxes in Summary. Do not add a separate To-Dos tab or panel.

Parse only when content or reading configuration changes. Playback progress and scrolling must not rebuild the Markdown document. Single-line meeting summary previews use one line of space; whitespace-only lines do not reserve height.

Render generated bold CJK labels such as `**结论：**正文` as a bold label followed by a space and the body. Preserve the saved source and full-source copy. Keep escaped markers and inline code literal.

## People and passages in library search

Search Results has a compact match count and ranking-details control. Search uses the provider selected in General; the results page has no mode override. Show unambiguous People matches in one row of compact transcript-style chips with overflow. Matched phrases and the speaker preference are available in help. Put uncertain names under **Possible Matches**, explaining that they do not affect ranking. Selecting a chip opens the person and reveals them even when a previous People filter hid them. Duplicate names remain separate candidates.

Embed the complete query once, retaining names and relationships. Name matching runs locally, off the main actor, with exact, reversed, pinyin, initials, prefix, and spelling evidence. Only unambiguous People matches contribute a soft speaker bonus, using confirmed speaker associations in the returned window. No person-based filtering or query rewriting occurs. The full query and content embeddings keep mentions searchable.

Keep each passage individually ranked, then group matches by meeting in first-match order. Show one reusable native row per meeting, with its original highest rank and Play in a left rail. The header counts matches, including those grouped into the same row. Use the available search page width. At result-row widths of at least 580 points (about 324 points for roughly ten English words in the passage), place the title, summary, source, and date in a left column and align the timeline and excerpt with its top in a wider right column. At narrower widths, stack the passage below the meeting details. Show optional scores below the content. Recalculate row heights when the window width changes. Size rows to their visible content; omit space for absent summaries, timelines, excerpts, and scores. Keep source badges fitted to their text with balanced padding, and trim excerpt boundaries for display. Keep timeline widths consistent across short and long passages. The recording timeline shows all matched intervals, with the active match in solid accent color and other matches at half opacity. Select the highest-ranked match initially. Hover provides a match hint; clicking an interval changes the excerpt, source, score, and playback target, and starts available audio without leaving search. Use the timeline directly to switch timed matches; do not add a match dropdown. Keep match choices through pagination and back navigation, and reset them for a new search. Meeting-title matches highlight the entire recording and omit duplicate title text. Missing duration or endpoint metadata must not produce an invented range. A single click, Return, or Play opens the full meeting view at the matching content and starts playback at the passage timestamp, or zero for a meeting-title match. Opening remains available during recording or when audio is unavailable, but playback does not start. Arrow keys select results without opening them. Activating a result clears its selection and releases search-row focus before opening the meeting. Show Ranking Details controls scores, not ordinal rank. The toolbar's Back to Search Results action and Command-[ restore the retained query and viewport without highlighting the activated result. Avoid a separate People scroll panel, duplicate query heading, redundant count footer, or persistent opening instructions.

## Provider capabilities

People voice review follows the [voice library design](../../../docs/design/2026-10-03-people-voice-library.md). Reviewed audio examples retain their recording and exact source range independently of provider embeddings. Keep automatic suggestions distinct from human confirmation, make exclusions and identity corrections reversible, and use the persistent player for bounded excerpts. Grouping examples does not confirm their identities. Provider preparation must not upload audio merely by opening People or choosing a provider.

The People list supports native multiple selection. The **People Actions** menu contains **Review Voices…** and **Merge Selected People…**; enable merging when at least two people are selected. Show the selected count and a **Merge…** button below the search field for that selection. The merge sheet lists only those people and asks which one to keep, previewing their combined details before **Merge People** commits. Preserve meeting assignments, tags, notes, chats, and voice samples; retain conflicting names and email addresses in Notes. Update all selected identities, voice-review references, and hidden original assignments in one file transaction. Explain that merging removes the other selected people and clears voice-review undo history. Require recording, processing, and indexing to finish first. Cancel preserves the selection. After success, reveal and select the retained person, including when their tags exclude them from the ordinary list.

New service providers start with all capabilities that their app adapter supports enabled. Saving an edited provider preserves capabilities the user turned off. Do not display capabilities without an implementation.

General uses two columns inside one scroll view. Record, Recording, and After Recording switches on the left express desired behavior. Capability provider choices stay visible on the right. Neither column has an independent scroll area. Ready, Not Ready, Checking…, and Couldn’t Check describe provider health separately from the feature’s on/off preference. Use text and symbols as well as color.

Each provider supplies its own capability health and explanation. General lists every added provider that supports the capability, disables unhealthy choices with a short reason, and keeps an unhealthy saved choice visible. Opening a dropdown checks its candidates concurrently and updates each result as it arrives. Otherwise General checks selected providers. Warnings link directly to the selected provider’s settings; downloads, verification, and repairs remain there.

A newly configured healthy provider fills a capability that has never had a provider and enables its related features. Explicit selections, clearing a provider, and turning features off are retained. Health refreshes and provider recovery do not reset those choices. Speaker Labeling distinguishes voices; Speaker Association matches voices with the People Library. Their preferences are independent across Recording and After Recording. The active recording’s Transcribe and Label Speakers switches override processing for that recording only.

Speaker Association is an app behavior with no provider capability or provider picker. **Automatically Associate People** controls it under Recording and After Recording. Matching uses compatible typed embeddings, regardless of their producing provider. It does not require a model download for embeddings already saved in the library. One **Speaker Labeling** provider owns the **Nemotron** and **Community-1** model sections. Live labeling requires both models; recorded labeling requires only Community-1. Community-1 has one installation, shared in-memory graphs, and one removal lifecycle for recorded labeling and voice extraction. Provider health and setup never enable association automatically.

## Reading-mode copy and task geometry

Copy selected reading text as Markdown, using source positions rather than a text search. Preserve complete source for a fully selected block. For partial blocks, retain only selected words with balanced inline formatting and the relevant heading, list, task, or code syntax. A selected part of a timestamp copies its complete original citation. Selected table cells form a valid Markdown table; unselected cells remain blank. Do not add words from unselected headings or cells. Normal editing clipboard behavior is unchanged.

Task hover backgrounds use equal padding around the first through last line's typographic bounds. Center the checkbox on the first line's text, excluding additional paragraph leading; do not shift text to fit a background.

Checkbox toggles update only the task’s checked state, marker, strikethrough, and copy metadata. Preserve displayed characters, paragraph layout, selection, and viewport. Hover responds to pointer entry, movement, and cursor updates; layout-only bounds notifications must not clear it.

Notes has a compact native segmented Edit/Read icon control aligned to the right on its own action row, above the document card. Keep both modes visible and expose their names to accessibility and help. Flush pending edits before switching.

## Local Search setup

Local Search uses the same managed model controls as other local providers. Show model selection, download size, progress, verification, cancellation, removal, and manual installation in **Search Model**. Use Core ML models. Readiness checks installed model files without running inference. A selected model has its own index; model changes and new meeting content schedule background indexing. Show progress and **Rebuild** in Data, alongside the separate **Library Index**.

Local Search is the default search provider. The provider selected in General controls search and model preparation. Obsolete saved Text or Fusion mode settings do not override that choice. When search is activated without an installed model, explain that search requires an additional download and link to the selected provider's settings. General controls automatic background loading of the model and index. When it is off, load them when search is activated. Show loading progress within the search field.
