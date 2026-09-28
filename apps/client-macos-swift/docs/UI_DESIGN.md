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
- Apple Music is the reference for capsule-shaped tabs and a soft rounded sidebar selection with accent-colored text/icons. Use Gday's accent color and consistent selection treatment. Retain a visible selected state when the window is inactive.
- Prefer standard SwiftUI/AppKit controls, SF Symbols, semantic colors, system typography, and system spacing. Use supported customization only when the native component cannot express the required interaction or visual hierarchy.
- Keep labels direct and concise: “Play,” “Recording transcript,” and meaningful source names. Avoid decorative explanatory text that repeats what the controls already communicate.
- Make recording actions easy to find and distinguish recording, saving, playing, and paused states through symbols and accessible labels as well as color.
- Give icon buttons a full-area hit shape, visible hover/pressed feedback, and a tooltip. Use at least 44×44 pt for player controls (including menu triggers and track mute buttons); keep symbols smaller inside the target. Apple's macOS accessibility table lists 28×28 pt default and 20×20 pt minimum, while general Buttons guidance recommends 44×44 pt hit regions. The minimum is not our target for frequently used controls. Hover feedback must not resize or move controls.

## Interaction and stable layout

The compact play/pause button beside the meeting title shows an accent-tinted circle and outline on hover, with a stronger pressed tint and a pointing-hand cursor. Draw this feedback above the glass material so it remains visible. Keep the button and title stationary during hover.

- Use one main Meetings window. **Show App**, recording setup, and reopening the app reveal that window instead of creating another. A closed main window can be reopened without restarting the app.
- Keep the window toolbar independent of sidebar expansion. Its title and toggle must remain stationary; reveal sidebar rows after expansion completes and preserve the sidebar background throughout.
- Preserve native list spacing. Do not add compensating scroll insets or offsets to hide a layout issue; reproduce the cause and verify navigation, playback changes, and window activation.
- Keep playback updates local to the transport. Menus, text editing, selection, and the main content layout must remain stable while time advances.
- Center waveform and primary playback controls together, with time labels below. Every track shares one playback/scrubbing timeline.
- Support keyboard navigation, visible focus, Space for playback outside text editing, and VoiceOver labels and selection state. Respect Reduce Motion, Reduce Transparency, and increased contrast; do not override system accessibility preferences to preserve an effect.

## Meeting title header

- Place the compact play/pause control immediately before the title, vertically centered in one row.
- Show the title as one line of plain text with tail truncation. For a stored multiline title, show its first line followed by an ellipsis; retain the complete saved title and expose it to accessibility and help.
- Double-click the title to edit. Enter commits, Escape cancels, and leaving the field commits. Keep edits in a local draft until completion rather than saving each keystroke. Provide **Edit Title** through the context menu and accessibility action.
- Normal reading must not expand header height for long titles. Date, language, and tags remain below the title row.

## Meeting keyboard and Finder actions

- **New Recording…** in the File menu uses Command-N and opens the recording setup sheet. Cancel leaves the library unchanged; the command must not create empty meeting notes.
- Delete or Forward Delete while the meeting list owns keyboard focus opens **Move “title” to Trash?**. Return activates **Move to Trash**, and Escape activates **Cancel**. Describe recovery accurately; recording and active-task protections still apply.
- **Reveal in Finder** in a meeting’s context menu selects its storage folder. A normal click on the player’s meeting title locates it in the app; Command-click reveals its folder in Finder. Command-click on an expanded track name reveals that audio file. Keep the normal click behavior and expose the reveal action through accessibility and help.

## Task status bar

Show the bottom task status bar only while work is queued, running, or needs attention, including other background activity such as imports and archives. Completed, cancelled, and dismissed tasks do not keep the bar visible. Keep **Tasks** in the sidebar for history and management even when the bar is hidden.

Use a brief opacity transition when the bar appears or disappears, respecting Reduce Motion. Preserve the identities and scroll positions of the meeting list and transcript; only the bottom status row changes. Keep the player independent of task visibility.

## Transcript playback feedback

- Highlight the transcript segment at the current playback position, including after waveform seeking or scrubbing. Keep the position highlight when paused; remove it when another meeting owns playback.
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
- Preserve the deployment target declared in `Package.swift` (currently macOS 14.2). Use availability checks and native older-system appearances where Liquid Glass APIs are unavailable. Do not imitate glass with private APIs or require a developer account for local builds.
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

Summary and Notes reading mode share one selectable document. Dragging or keyboard selection must cross paragraphs, lists, and table cells; do not split reading content into independently selectable labels. Use the Rust reader's GitHub Markdown hierarchy as the reference: restrained headings, comfortable line height, compact list spacing, light table borders, and quiet code backgrounds. Preserve native semantic colors in light and dark appearances.

Unordered lists use a 15-point bullet glyph beside 14-point body text, with an 18-point text inset. Align wrapped lines with the text, keeping the dot close to its item.

Render checked and unchecked task markers at the same 14-point size with a 22-point marker column. The complete wrapped task row is clickable and shows subtle rounded hover feedback with a pointing-hand cursor. A drag must select text instead of toggling; citation links and double-click selection take precedence. Completion persists into its Markdown source. Keep source text in reading mode otherwise read-only. Timestamps such as **[12:39]**, **[81:32]**, and **[1:21:32]** are playback links; a range uses its starting timestamp. Links have visible color and pointing-hand hover feedback. Inline code remains literal. Meeting tasks are presented through Markdown checkboxes in Summary. Do not add a separate To-Dos tab or panel.

Parse only when content or reading configuration changes. Playback progress and scrolling must not rebuild the Markdown document. Single-line meeting summary previews use one line of space; whitespace-only lines do not reserve height.

Render generated bold CJK labels such as `**结论：**正文` as a bold label followed by a space and the body. Preserve the saved source and full-source copy. Keep escaped markers and inline code literal.

## Provider capabilities

New service providers start with all capabilities that their app adapter supports enabled. Saving an edited provider preserves capabilities the user turned off. Do not display capabilities without an implementation.

This Mac uses the same Capabilities section pattern, with a Live Transcription toggle. Its speech model downloads appear in a separate Speech Models section. Defaults presents a Provider picker for Live Transcription, with None and enabled eligible providers; This Mac is the only supported live provider today. A saved disabled provider appears as Provider Unavailable until enabled or replaced. Show Live Transcript is a separate recording preference.

## Reading-mode copy and task geometry

Copy selected reading text as Markdown, using source positions rather than a text search. Preserve complete source for a fully selected block. For partial blocks, retain only selected words with balanced inline formatting and the relevant heading, list, task, or code syntax. A selected part of a timestamp copies its complete original citation. Selected table cells form a valid Markdown table; unselected cells remain blank. Do not add words from unselected headings or cells. Normal editing clipboard behavior is unchanged.

Task hover backgrounds use equal padding around the first through last line's typographic bounds. Center the checkbox on the first line's text, excluding additional paragraph leading; do not shift text to fit a background.

Checkbox toggles update only the task’s checked state, marker, strikethrough, and copy metadata. Preserve displayed characters, paragraph layout, selection, and viewport. Hover responds to pointer entry, movement, and cursor updates; layout-only bounds notifications must not clear it.

Notes has a compact native segmented Edit/Read icon control aligned to the right on its own action row, above the document card. Keep both modes visible and expose their names to accessibility and help. Flush pending edits before switching.
