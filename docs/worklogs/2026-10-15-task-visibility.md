---
title: Apply excluded tags to task visibility
date: 2026-10-15
status: complete
scope: macos-tasks
---

# Problem

Tasks listed meeting jobs without applying excluded tags. Their counts and attention banner could expose jobs that were hidden elsewhere. The attention banner also placed unrelated background activity beside its alert count, suggesting that activity caused the alert.

# Implemented solution

- Apply excluded meeting tags before task history pagination and counting, using the existing shared library index relationships. Hydrated meeting metadata overrides an older indexed relationship.
- Use the same visibility rule for preview jobs, activity, attention counts, focused-task navigation, and selected details. Refresh the list when tag exclusions or meeting index relationships change.
- Keep global voice-library preparation jobs visible; these can cover multiple meetings and are not owned by one meeting.
- Keep the existing Tasks layout and controls. The attention banner now contains its count and review action; routine activity appears only in the activity banner.
- Preserve global maintenance scan activity, including scan-only batches with no excluded tags. A real library-wide scan remains visible with exclusions; excluded meeting jobs alone do not produce activity.
- Update the tag exclusion helper and client guide to include meeting tasks, using the current **Exclude from Main Lists** control name.
- Preserve stored tasks and execution state. Visibility does not acknowledge alerts, cancel jobs, or delete history.

# Reasoning

Filtering after loading a page would leave gaps, incorrect totals, and premature end-of-history indicators. Applying a shared predicate before paging avoids those problems without hydrating the full library. The existing Meetings exclusion behavior has no Show Excluded control, so Tasks follows that behavior. Global preparation jobs remain visible because hiding a mixed-meeting job would conceal work for visible meetings.

# Technical debt

None. The filter uses existing index tables and needs no schema migration. Filtered aggregate counts and meeting visibility use a revision-keyed presentation cache when exclusions are present; the existing cached totals remain the fast path when there are none. Cache invalidation includes task scope revisions/counts, meeting-index revision, excluded tags, and hydrated tag relationships. The normal hydration target is 24 meetings (active or unsaved meetings remain protected), and the retained task window is 100 plus active pins. SQL overrides therefore track hydrated metadata, not the full library.

# Validation

Before UI wiring changes, inspected and captured Tasks in the isolated synthetic preview. The captured empty state retains the existing scope menu, list, detail pane, and recording footer. The user's supplied populated screenshot identifies the visibility defect. No installed application or real library was accessed.

Added synthetic regression coverage for cold indexed meetings, filtering before forward and backward pagination, complete totals, unchanged journal history, unsaved relationship overrides, preview attention visibility, persisted running/queued task visibility, and global maintenance scan activity. Combined release regression run passed: 61 tests in 7 suites. Final isolated release build, scoped formatting, and diff checks passed. Two existing missing Command Line Tools linker-search-path warnings remain; no deprecated API warnings appeared.

Captured the changed Tasks screen with synthetic tasks: excluding a fixture tag reduced the list from 14 to 8 tasks and attention from 4 to 3. Other meeting tasks and global voice preparation jobs remained visible. The attention bar showed only the count and review action. The final tag editor exposes the complete revised explanation to accessibility; the screenshot shows wrapped text but crops the popover at the window boundary, limiting full visual inspection. The installed recording application and main library were not changed.
