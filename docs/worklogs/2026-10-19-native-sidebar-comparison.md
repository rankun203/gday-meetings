---
title: Native three-column sidebar comparison
date: 2026-10-19
status: in-progress
scope: macos-layout-experiment
---

# Problem

User testing rejected both full-app candidates: replacing the inner split and bounding the outer workspace each retained sidebar animation shuddering and transient toolbar overflow. An intermittent incomplete transition can also leave window resizing broken.

# User Intention

Compare independent native three-column baselines before changing production layout, preserving smooth sidebar transitions and resizing. The user subsequently requested committing all remaining source and documentation with generated files ignored.

# Implemented solution

Preparing independent standalone native three-column reference apps in `experiments/native-sidebar-comparison/`: Astra implements the Codex candidate; Claude Code uses Opus 5.5. Each uses synthetic content, a scene-root `NavigationSplitView`, native column width preferences, and the system sidebar toggle. Neither opens a meeting library.

# Reasoning

Establish the behavior of the standard native structure before adding the production toolbar, transport, or nested layout. The user validates animation directly. No computer-use validation, forced-layout timer, or production data access is part of this comparison. Supplied screenshots provide the before-state evidence.

# Technical debt

None. These are isolated reference applications, not production replacements. Prior candidate changes remain separate and are not merged.

# Notes

Both optimized builds and signature checks passed. The user tested Astra's sidebar reveal and resizing during the transition and reported "Smooth throughout." This establishes a working native three-column baseline on the user's machine. Claude's independent baseline is ready and awaiting user validation. The intended behavior is continuous detail reflow as the sidebar reveals, without clipping, a final snap, or loss of resize responsiveness.

Repository packaging review added ignore rules for standalone experiment compiler caches. Existing rules already exclude app bundles, private inputs, and `tmp/`. Shell syntax, strict Swift formatting, fresh optimized builds of both comparison apps, and signature verification passed before commit.
