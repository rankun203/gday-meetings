---
title: Merge duplicate people
date: 2026-10-04
status: complete
scope: swift-people-library
---

## Problem

People offered Add and Delete but no way to combine duplicate contacts. Deleting an entry removed its assignments instead of transferring them.

## Design and evidence

Inspected the supplied People screenshot and captured the running installed app with Computer Use before editing. The latter had Review Voices open over People; it was left untouched. The list offers single selection, search, and per-row deletion.

Add **Merge Person…** beside the People actions and in each row’s context menu. A native sheet identifies the source, lists other people with email and meeting count, and previews the retained name, email, and combined notes. **Cancel** discards the selection. **Merge People** explicitly commits; it has no Return shortcut. Explain removal and the loss of voice-review undo history before committing. Select the retained person and clear the list filter after success.

## Implemented solution

- `PersonMerge` combines contact information, tags, and stored voice samples. Conflicting names and email addresses remain in Notes.
- `MeetingStore` combines person chats and remaps loaded meeting assignments. The existing rollback journal includes voice records, person files, chats, and unloaded meeting metadata/content in one transaction.
- Unloaded meetings are scanned in index pages, including hidden voice-review origins. Transcripts and audio are not loaded. Only changed metadata/content files are rewritten.
- Voice assignments, suggestions, rejection references, and decisions transfer to the retained ID. Confirmation wins over conflicting rejection of the same retained person. Voice-review undo is cleared so it cannot restore a removed contact.
- Merge requires a writable library with recording, background processing, and indexing finished.

## Reasoning

Names do not establish identity, so matching names never trigger an automatic merge. Keeping one selected stable ID avoids changing every reference to both people. A transaction prevents partial deletion if any affected document cannot be saved. Scanning indexed content also finds original identities hidden behind reviewed speaker projections, which current person relationship indexes do not contain.

## Technical debt

Merge scans all indexed meeting metadata/content synchronously, with one unloaded meeting payload at a time; it does not read transcripts. This retains the store’s synchronous save model and rollback journal. Very large libraries can pause the UI during a merge. Move library transactions to a serialized background writer with progress before claiming large-library merge responsiveness; do not split the merge into independently committed pages. No schema migration or identity alias table was added.

## Validation

- The first sandboxed build could not invoke SwiftPM’s sandbox; the authorized retry passed `make build-macos`, including plist and signature checks. Process inspection confirmed only the installed `/Applications` app was running, so rebuilding the development bundle did not affect it.
- The full parallel suite failed with 16 issues in timing-sensitive recording, streaming, and task tests. A serial rerun passed all 816 tests across 139 suites in 80.814 seconds. The merge suite covers restart persistence, more than one index page, rollback, loaded and unloaded meetings, metadata-only meetings, review conflicts, and contact conflicts. Additional assertions check stored voice samples and hidden review origins.
- Formatting, lint, and diff whitespace checks passed. Release linking reports the existing missing Command Line Tools `Developer/usr/lib` and `Developer/Library/Frameworks` search paths. No deprecation warnings appeared. Repair or update the developer-tool installation to resolve those paths; no warning is suppressed.
- The five final focused merge tests passed in 0.852 seconds. A first version of the additional projection fixture was normalized by voice reconciliation before the merge; installing that fixture after reconciliation verifies the intended stored-origin case.
- The first Preview check exposed truncation after choosing a destination. The final sheet gives contact details a scrolling area and keeps explanations and actions outside it. The final release rebuild passed in 166.17 seconds, including plist and signature checks. Launched the exact `.build/preview/Gday Meetings UI Preview.app` bundle with ordinary synthetic fixtures; captured and inspected selected-state screenshots in light and dark appearance. Both show the complete retained details, explanation, warning, and buttons. Restored Preview’s original Light preference afterward.
- Verified the People action, row context menu, disabled commit before selection, keyboard list selection, and Escape cancellation. No UI merge was committed; automated tests verify the commit and rollback paths. Small-window, inactive-window, System appearance, VoiceOver, and older-macOS checks were not performed. Large-library responsiveness is not established.
- Validation uses macOS 26.6.2 and Apple Swift 6.4 on arm64, starting from revision `ccde75f` plus this task’s working-tree changes. The installed app and real library remain unchanged. The user subsequently requested a commit and push to `master`; check the hosted macOS matrix after publication.
