---
title: Swift macOS client instructions
date: 2026-10-03
status: active
scope: swift-app
---

# Swift macOS client

Repository-root instructions still apply.

## Core references

Read the references relevant to the change:

- [README.md](README.md): prerequisites, build commands, run modes, installation, and release validation.
- [UI design](docs/UI_DESIGN.md): Liquid Glass defaults, accessibility, interaction, and layout rules.
- [Shared UI theme](docs/UI_THEME.md): mandatory visual and component practices for every screen, control, state, and native bridge; reuse native styles and shared components rather than creating competing appearances.
- [UI Preview](docs/UI_PREVIEW.md): isolated UI validation, synthetic fixtures, and preview limits.
- [Audio design](docs/AUDIO_DESIGN.md): capture architecture, permissions, encoding, and audio lifecycle.
- [Library storage design](../../docs/design/2026-09-27-large-library-storage.md): authoritative files, disposable indexing, paging, and storage contracts.
- [Service provider protocols](../../docs/protocols/README.md): shared capability rules and links to individual contracts.
- [Performance testing](docs/PERFORMANCE_TESTING.md): recording endurance, resource measurements, and interaction checks.
- [Audio dependencies](ThirdParty/README.md): pinned source builds, licenses, and dependency upgrades.

Keep this list focused on durable architecture and workflow references. Search `docs/worklogs/` for task-specific history when needed; do not add each worklog to this file. Update the relevant core guide when a change establishes a lasting contract.

## Swift formatting

Run `make format-macos` after Swift edits and `make lint-macos` before committing. Follow the checked-in `.swift-format`. Keep broad formatting changes separate from behavioral changes.

## UI implementation and validation

- Follow the UI design and shared theme guides before changing any screen or component, including settings, dialogs, menus, warnings, editors, and AppKit-backed views. Existing screens must converge on the same standard; Preview must use production components with synthetic data. Prefer current public SwiftUI/AppKit controls and Apple's Human Interface Guidelines.
- Preserve the declared minimum macOS version with availability-checked native fallbacks. Do not raise it or introduce deprecated APIs for a visual effect.
- Validate changed UI in isolated Preview, including appearance, keyboard access, and layout stability. Keep Keychain access, real capture, and hardware playback disabled; use synthetic content.
- Preview supports online provider checks and deliberately started jobs. Opening or saving settings must not upload content. Record untested behavior and compatibility limits in the task worklog; a successful build does not establish visual correctness.
