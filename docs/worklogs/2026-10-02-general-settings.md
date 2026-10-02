---
title: General settings and provider health
date: 2026-10-02
status: complete
scope: swift-settings-and-recording
---

# Problem

Defaults mixed provider configuration, display preferences, and automatic behavior. The long form obscured whether live transcription and speaker processing were enabled and ready. Local model state initially reported missing before checking the installed files.

# Implemented solution

General replaces Defaults with Record, Recording, and After Recording behavior on the left and capability provider choices on the right. Both columns share one scrolling layer. Switches align to the right, with status immediately after each feature label. Provider-owned health supplies readiness and short explanations; repair controls remain in Service Providers. The provider sidebar is 300 points wide. Settings tabs use system-controlled spacing.

Speaker labeling and association have independent persisted preferences for each stage. Initial healthy provider setup fills a never-configured capability and enables its features, while explicit off and None choices survive subsequent checks. Recording controls are Transcribe and Label Speakers. Disabling labeling stops its heavy processing even when association remains desired. After-recording Community-1 labeling can retain speaker results without a transcript; manual person assignments are preserved.

Health checks inspect selected providers, or all candidates concurrently when a dropdown opens. Configuration guards discard stale results, including checks of upload dependencies and sequential capability checks. Local health inspects file metadata and preparation receipts without loading models. Ten synthetic scenarios exercise the settings presentation without network checks or inference.

# Reasoning

The inspected existing Settings screen places transcription below the recording setup group, with speaker controls farther down. Independent switches express desired behavior; readiness expresses whether its dependencies are available. Provider choices retain unhealthy selections and link to their provider settings. Speaker Labeling and Speaker Association name separate operations consistently across the app.

Validation uses a separate checkout and synthetic data. The running installed app has an active recording and must not be restarted or replaced.

# Technical debt

- Existing serialized speaker-recognition keys remain for compatibility; UI wording separates labeling and association. Renaming persisted keys needs an explicit schema migration.
- Older settings omitted nil provider selections, so migration cannot distinguish an old explicit None from a never-configured capability. New initialized-capability and explicit-off fields preserve future intent. Legacy serialized false values are conservatively preserved; this can leave an old feature off after initial setup. A future migration could improve this only with additional historical evidence.
- Lightweight local health cannot detect same-size file corruption or prove inference will succeed. Runtime acquisition still verifies and prepares models; retain full validation when changing installation storage.
- Remote labeling does not guarantee compatible voice samples. General conservatively requires Community-1 recorded labeling or retained live association samples for after-recording association. Independent sample extraction would remove this dependency; until then, the warning describes the required setup.

# Validation

Before implementation, captured and inspected the existing Defaults screen and its accessibility tree, plus the original combined recording controls. After implementation, inspected all ten General scenarios: ready, off, no selection, missing files, checking, disabled alternative, capability-specific health, server unavailable, independent stages, and unsupported language/dependencies. Verified the unhealthy dropdown alternative is disabled and a warning opens the affected provider. Keyboard scenario selection, accessible switch names, shared scrolling, inline status, right-aligned switches, dark appearance, wider sidebar, and native tab spacing were inspected in the isolated preview.

The final sequential suite passed 632 tests in 109 suites (64.727 seconds), including the review regressions. Formatting, lint, and diff whitespace checks passed. The isolated release build succeeded in 130.63 seconds through `make build-macos-preview`, which runs `make build-macos`; plist and code-signature checks passed. Source and test snapshots matched the working tree. The final preview showed Record, Recording, and After Recording, and confirmed Transcribe can be off while Label Speakers is on. A later user review identified tab movement caused by inserting AppKit spacers after SwiftUI toolbar creation. The spacing bridge was removed to restore stable native layout; the final follow-up build validates this removal. The baseline parallel suite already had timing failures in summary/managed-task tests, so validation uses sequential mode. The active installed recording was never restarted or replaced.

Validation does not establish live inference accuracy, real provider outage recovery, or end-to-end recording finalization. Preview health is synthetic; concurrency, migration, saved intent, and stale responses are covered separately by automated tests. Existing Command Line Tools linker warnings report absent Developer library/framework search directories; no deprecated API warnings were observed. No push or CI matrix run was requested.
