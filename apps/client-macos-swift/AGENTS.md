---
title: Swift macOS client instructions
date: 2026-09-26
status: active
scope: swift-app
---

# Swift macOS client

Repository-root instructions still apply.

## Documentation

Read the relevant documents before changing the app:

- [README.md](README.md): app overview, prerequisites, building, installing, and running.
- [Audio design](docs/AUDIO_DESIGN.md): capture architecture, permissions, encoding, and audio lifecycle.
- [UI design](docs/UI_DESIGN.md): Liquid Glass defaults, accessibility, interaction, and layout rules.
- [UI Preview](docs/UI_PREVIEW.md): isolated UI validation, synthetic fixtures, and preview versus full-app behavior.
- [Performance testing](docs/PERFORMANCE_TESTING.md): repeatable one-hour recording, Notes, Summary, navigation, provider readiness, and resource measurement checklist.
- [File transfer](../../docs/protocols/file-transfer.md): temporary audio uploads for URL-based workers.
- [Service provider protocols](../../docs/protocols/README.md): connection checks and shared capability rules.
- [Transcription](../../docs/protocols/transcription.md), [Speaker Labels](../../docs/protocols/diarization.md), [Summaries](../../docs/protocols/summarization.md), [Search](../../docs/protocols/search.md), and [Playback](../../docs/protocols/playback.md): capability contracts and adapter limits.
- [Audio dependencies](ThirdParty/README.md): pinned offline source builds, licenses, and dependency upgrades.
- [Transcript JSONL migration](scripts/migrations/README.md): explicit backed-up conversion of legacy saved arrays.
- [Library migration validation](../../docs/worklogs/2026-10-03-transcript-library-migration.md): preservation checks and migration limits.
- [Large-library storage design](../../docs/design/2026-09-27-large-library-storage.md): file authority, disposable indexing, folder discovery, and scale validation.
- [Meeting list scrolling](../../docs/worklogs/2026-09-27-meeting-scroll-prefetch.md): viewport anchoring, anticipatory paging, and full-app validation.
- [New recording list reveal](../../docs/worklogs/2026-09-29-recording-list-reveal.md): recording creation events, viewport anchoring, and synthetic insertion validation.
- [File library implementation](../../docs/worklogs/2026-09-27-file-library-index.md): indexed paging, document transactions, and retained scalability limits.
- [Expandable sections](../../docs/worklogs/2026-09-28-disclosure-rows.md): shared full-row disclosure interaction and validation.
- [Transcript playback highlight](../../docs/worklogs/2026-09-28-transcript-playback-highlight.md): playback clock, seeking, hover, and speaker badge feedback.
- [Conditional task status bar](../../docs/worklogs/2026-09-28-conditional-task-bar.md): visibility, layout, and validation.
- [Task attention](../../docs/worklogs/2026-10-01-task-attention.md): visible review controls and failed-task ordering.
- [Transcription job recovery](../../docs/worklogs/2026-10-01-transcription-job-recovery.md): connection-check errors and saved-job recovery.
- [Recording bar hover](../../docs/worklogs/2026-10-01-recording-bar-hover.md): shared title hit area and hover feedback.
- [Resource audit](../../docs/worklogs/2026-09-28-resource-audit.md): sampled resource usage and shared playback clock.
- [Associated meeting pages](../../docs/worklogs/2026-09-28-associated-meeting-pages.md): bounded navigation through person and tag meetings.
- [Markdown reading](../../docs/worklogs/2026-09-28-markdown-reading.md): selection, citations, task markers, and compact previews.
- [Markdown marker colors](../../docs/worklogs/2026-09-28-markdown-marker-color.md): appearance-aware list bullets and numbers.
- [Transcript layout lifecycle](../../docs/worklogs/2026-09-28-transcript-layout-lifecycle.md): stable initial placement and whole-surface scrolling.
- [Meeting Trash keyboard actions](../../docs/worklogs/2026-09-28-meeting-trash-keyboard.md): Delete confirmation and recoverable deletion.
- [Finder shortcuts](../../docs/worklogs/2026-09-28-finder-shortcuts.md): meeting and audio file reveal actions.
- [New Recording shortcut](../../docs/worklogs/2026-09-28-recording-shortcut.md): Command-N opens recording setup.
- [Data folder selection](../../docs/worklogs/2026-09-28-data-folder-selection.md): verified library copies, restart-based switching, and local indexes.
- [Language picker width](../../docs/worklogs/2026-09-28-language-picker-width.md): complete selected labels and concise speaker guidance.
- [Transcript history versions](../../docs/worklogs/2026-09-28-transcript-history-versions.md): stable generation identities and provider labels.
- [Meeting title header](../../docs/worklogs/2026-09-28-meeting-title-header.md): compact playback control and deliberate title editing.
- [Meeting header folder](../../docs/worklogs/2026-09-28-meeting-header-folder.md): Command-click opens the displayed meeting's folder.
- [Provider capability defaults](../../docs/worklogs/2026-09-28-provider-capability-defaults.md): enabled capabilities and live transcription selection.
- [General settings and provider health](../../docs/worklogs/2026-10-02-general-settings.md): stage behavior, shared scrolling, capability readiness, and initial provider selection.
- [General appearance preference](../../docs/worklogs/2026-10-02-appearance-settings.md): persisted System, Light, and Dark appearance across app windows.
- [Speaker association health](../../docs/worklogs/2026-10-02-speaker-association-health.md): Nemotron capability migration and automatic local model verification.
- [Provider icons](../../docs/worklogs/2026-10-02-provider-header-icon.md): shared symbols in provider rows, headers, and the Add menu.
- [Transcript result presentation](../../docs/worklogs/2026-09-28-transcript-result-presentation.md): reset the viewport when a provider result replaces a transcript version.
- [Transcript whitespace](../../docs/worklogs/2026-09-28-transcript-whitespace.md): normalize incoming provider text before persistence.
- [Compact speaker assignments](../../docs/worklogs/2026-10-03-compact-speaker-assignments.md): one row per speaker with its current assignment and person menu.
- [Transcript source badges](../../docs/worklogs/2026-10-02-transcript-source-badges.md): source-only labels, person assignment guards, and checkpoint recovery.
- [Shared live transcript editing](../../docs/worklogs/2026-10-01-live-transcript-unification.md): shared native rows, provisional text, manual edits, person assignment, and explicit live following.
- [Continuous transcript paragraphs](../../docs/worklogs/2026-10-02-live-transcript-paragraphs.md): recognition chunk grouping, captured edit ranges, saved adoption, and partial text styling.
- [Compact live journal](../../docs/worklogs/2026-10-02-compact-live-journal.md): CSV transactions, dictionary references, guide migration, and Meetings branding.
- [Saved transcript rows](../../docs/worklogs/2026-10-03-saved-transcript-segments.md): append-only timed rows, atomic recent checkpoints, and separate event recovery.
- [Canonical transcript JSONL](../../docs/worklogs/2026-10-03-canonical-transcript-jsonl.md): one segment store for live capture, display, edits, provider results, and interrupted-recording recovery.
- [Live speaker continuity](../../docs/worklogs/2026-10-02-live-speaker-continuity.md): carried speaker labels, immutable history, recovery journals, and bounded live updates.
- [Long recording performance](../../docs/worklogs/2026-10-02-live-recording-performance.md): incremental attribution, bounded delivery, checkpoint persistence, and device-change continuity.
- [Performance evaluation plan](../../docs/worklogs/2026-10-02-performance-evaluation-plan.md): recording history scaling, summary-generation CPU, Instruments workloads, and acceptance criteria.
- [Recording endurance](../../docs/worklogs/2026-10-02-recording-endurance.md): dual-source recording phases, periodic Instruments captures, resource growth, and measurement limits.
- [Local speaker providers](../../docs/worklogs/2026-10-01-local-speaker-providers.md): independent speaker capabilities, model installation controls, live attribution, and saved-audio labeling.
- [Single main window](../../docs/worklogs/2026-09-28-single-main-window.md): Show App and window reuse.
- [Window activation](../../docs/worklogs/2026-10-01-window-activation.md): restore a usable window on app activation and Dock reopening.
- [Dock reopening](../../docs/worklogs/2026-09-28-dock-reopen.md): restore Meetings after all windows close.
- [Follow logs](../../docs/worklogs/2026-09-28-follow-logs.md): Help menu access to Console.
- [Tag exclusion](../../docs/worklogs/2026-09-28-tag-exclusion.md): excluded meeting and person lists, person tags, and recovery controls.
- [Summary task isolation](../../docs/worklogs/2026-09-28-summary-task-isolation.md): independent summary lifetime, incomplete responses, and paused playback route changes.
- [Summary images](../../docs/worklogs/2026-09-28-summary-images.md): image capability settings, attachments, source links, and retention.
- [Meeting data events](../../docs/worklogs/2026-09-29-meeting-data-events.md): provider receipts, per-meeting history, persistence, and validation.
- [Data event groups](../../docs/worklogs/2026-10-01-data-event-groups.md): stable destination IDs, file references, and grouped history.
- [Meeting folder dates](../../docs/worklogs/2026-10-01-meeting-folder-dates.md): dated folder labels, unchanged identities, and compatibility.
- [Agents page](../../docs/worklogs/2026-09-29-agents-page.md): saved library instructions, launch commands, and fenced-code presentation.
- [Repository worklogs](../../docs/worklogs/): implementation decisions, validation results, technical debt, and outstanding issues; consult recent Swift entries for ongoing work.
- [Streaming Opus recording](../../docs/worklogs/2026-10-01-streaming-opus.md): speech encoding, DTX, bounded capture writes, and validation.
- [Recording menu icon](../../docs/worklogs/2026-10-01-recording-menu-icon.md): square stop symbol while recording.
- [Koala menu icon](../../docs/worklogs/2026-10-02-koala-menu-icon.md): distinctive template artwork and recording-state square.
- [Recording source mute](../../docs/worklogs/2026-09-29-recording-source-mute.md): independent source controls, saved and live silence, and validation.
- [Recording meter animation](../../docs/worklogs/2026-10-02-meter-animation.md): layer interpolation, unchanged meter publication rate, accessibility, and measured performance limits.
- [Notes controls layout](../../docs/worklogs/2026-09-29-notes-controls-layout.md): recording header alignment, fixed source icon slots, and floating Markdown copy controls.

Keep this index complete: whenever app documentation is added, moved, or renamed, update its link here in the same change. Every document under `docs/` must have a direct link from this file.

## Swift formatting

Release build coverage and toolchain limits are recorded in
[macOS release CI](../../docs/worklogs/2026-09-30-macos-release-ci.md).

- Run `make format-macos` after Swift edits and `make lint-macos` before committing. Follow the checked-in `.swift-format`; do not hand-format against it. Keep broad formatting changes separate from behavioral changes. See README.md for toolchain and scope details.

## UI design default

- **Liquid Glass is the default design direction for this app.** Read and follow [UI_DESIGN.md](docs/UI_DESIGN.md) before creating or changing UI, including UI Preview, Settings, sheets, navigation, and playback controls.
- Prefer current public SwiftUI/AppKit controls and Apple's Human Interface Guidelines. Use Apple Music's capsule tabs and soft sidebar selection as visual references, not private APIs or a promise of identical system-app rendering.
- Preserve the declared minimum macOS version with availability-checked native fallbacks. Do not raise the minimum OS version or introduce deprecated APIs just to obtain a visual effect.
- Validate changed UI in isolated UI Preview, including appearance, keyboard access, and layout stability. Preview supports real online provider checks and deliberately started jobs; keep Keychain access, real capture, and hardware playback disabled so automated testing does not require system prompts. Use synthetic content by default, and never upload it merely by opening or saving settings. Document any untested behavior or compatibility compromise; building successfully does not establish visual correctness.
