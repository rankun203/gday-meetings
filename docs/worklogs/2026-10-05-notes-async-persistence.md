---
title: Keep notes persistence off the main actor
date: 2026-10-05
status: implemented
scope: swift-notes-persistence
---

## Problem

Typing was debounced, but notes flushes still read files, generated previews, wrote conflict copies, saved notes, and cleaned attachments synchronously on the main actor. Navigation, exports, archiving, and quitting could wait on that work while the interface stopped responding.

## Implemented solution

`NotesFileWorker` serializes filesystem work on an actor. `NotesStorage` keeps immediate draft and saved mirrors on the main actor, tracks draft revisions and latest read requests, and joins concurrent flushes for the same meeting. A successful old write cannot remove a newer draft. Explicit flush drains the latest revision; errors preserve pending text.

Loading and external reloads reject results superseded by editing or newer reads. Watcher setup opens its descriptor off the main actor. Accepted external baseline changes increment the revision used by library reload validation. Notes view callbacks start asynchronous flushes; read/edit transitions accept only the latest request. Export and archive await notes durability. Export file generation uses the same notes worker so attachment reads cannot overlap preview cleanup. Deletion reserves the meeting against new edits, drains its pending draft, and only discards its mirrors after a successful move to Trash.

## Reasoning

Editor state needs immediate consistency; filesystem persistence can follow while typing. Export, archive, deletion, library switching, and quit are explicit durability boundaries and must await completion or report failure. Conflict copies, image preview maintenance, private file permissions, and receipt reporting stay in the serialized write operation rather than being dropped for speed.

## Technical debt

None introduced. The existing synchronous folder-path helper remains available to callers that need a URL; notes persistence resolves folders inside its worker. Wider canonical persistence and library reload changes are handled in the parent task.

## Validation

Added deterministic blocked-worker tests for main-actor responsiveness, latest-edit preservation, stale-read rejection, write failure retry, and deletion reservation. Existing conflict, watcher, notes export, and quit tests now use explicit asynchronous boundaries. Notes tests passed in the combined 217-test regression run; unrelated task lifecycle fixture corrections passed their targeted rerun. The slow-worker fixture now uses its caller's bounded wait and unconditional release instead of a competing five-second timer that could expire while unrelated main-actor tests were running.

Captured the Notes editor and Edit Notes/Read Notes control before the migration. The `40e64af-async-review` release passed in 162.70 seconds without compiler warnings and passed platform/signature checks. After-build synthetic UI validation confirmed an edit survives immediate navigation away and back, and appears in both Edit Notes and Read Notes. The installed app was preserved.
