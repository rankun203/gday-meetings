---
title: Choose a data folder
date: 2026-09-28
status: validating
scope: swift-app
---

# Problem

Settings showed the library path but could not choose another folder, including an iCloud Drive location. A live swap would risk two stores watching the same data and writes reaching the wrong library. A synced SQLite WAL is also unsuitable as the shared authority.

# Design

The parent agent captured the existing Data settings: current path, Show in Finder, index size/rebuild, and counts. Add **Change Folder…** beside the existing folder action. A folder chooser inspects the destination before confirmation:

- An empty folder offers **Copy Library**. Copying preserves the original library, verifies copied files, and selects the new location only after success.
- An existing folder containing `meetings/` offers **Use Library** after restart. It is not merged with the current library.
- An unrelated nonempty folder or a folder inside/containing the current library is rejected.

Display copy progress, Cancel, and any error in Data settings. After success, show the pending path, **Cancel Change**, and **Quit Gday Meetings**, with instructions to reopen. Editing pauses during copying and while a restart is pending. Cancellation restores the current library; a completed copy remains on disk if the pending selection is cancelled.

# Implemented solution

`LibraryFolderPreference` stores a bookmark and display path in app preferences outside the library. Explicit Preview, benchmark, and test roots keep pending choices in memory, never in regular app preferences. Startup resolves the bookmark without mounting a volume or showing UI. A missing location or malformed preference fails read-only instead of silently creating a new library elsewhere. Explicit test/benchmark data roots still override the preference.

`LibraryFolderChoice` stages a copy beside the destination, copies each file in cancellable 1 MiB chunks, and checks source/copy directory entries and SHA-256 file contents. Streamed whole-library content/path digests before and after copying also detect changes to earlier files or root entries; the completed staging digest must match. It excludes the disposable index, index event cursor, and root cache/staging folders. A POSIX empty-directory removal refuses a destination populated by another process; publishing never recursively deletes a destination. Failure and cancellation do not change the selected location and clean up the app-owned staging directory. Files in the original folder remain untouched.

`MeetingStore` flushes notes, blocks writes and new jobs, and waits for the library monitor queue to stop before copying on a utility task. Recording and active jobs prevent starting the change. The existing store remains the sole current store until quit; there is no runtime replacement. Quitting during a copy cancels it and waits for cleanup.

For a selected custom folder, `index.db`, its WAL/SHM, and the FSEvents cursor live under the Mac's local `Caches/com.gdaymeetings.macos/libraries/<path-hash>/`. `LibraryIndex` and the monitor receive this separate directory while authoritative file paths still point to the chosen library. Data settings displays the local index path. Default libraries retain their existing index location.

Data Privacy wording now distinguishes authoritative files (**Saved in Data Folder**) from this Mac's Keychain and logs. Its introduction explains cloud synchronization separately from configured service-provider requests. The provider-routing boolean is named `sendsToProvider`, so tests and code do not equate absence of provider requests with a guarantee that synced files never leave the Mac. The parent agent captured the previous privacy screen before these text-only changes. README documents the copy/restart workflow, local index, and cloud synchronization limits.

# Reasoning

Restarting makes ownership explicit and avoids rebinding editors, playback, monitors, and pending operations to another store. Copy-and-keep-original is recoverable; automatic destructive relocation is unnecessary. Local disposable indexing avoids cloud synchronization of a live database while keeping JSON, Markdown, and audio accessible to agents.

# Validation

Tests cover verified copy/source retention/index exclusion, occupied and nested destination rejection, bookmark persistence and unavailable-folder failure, and separate local index placement. All five focused tests pass, including source changes during copying, cancellation cleanup, failure preserving the pending preference, and explicit-root preference isolation. The parent agent is checking the consolidated build and post-change UI. No regular user library has been moved or selected during implementation.

Preview validation: the native chooser selected an empty temporary folder, and Copy Library completed with the expected restart notice. The copied folder contains meeting files, assets, people, and tags, with no index database. The original Preview library remained present. The screenshot confirms the new path, disabled mutation controls, and Cancel Change action. UI automation then timed out during duplicate-window testing, so the final Cancel Change interaction remains unverified. Preview preferences are isolated from the regular app.

# Technical debt

- Cloud-drive synchronization is not a multiwriter transaction protocol. The UI instructs keeping the folder downloaded and opening it on one Mac at a time. Conflicts caused by simultaneous apps or external writers are not automatically merged. A future cross-device design needs explicit ownership/conflict handling before concurrent use can be supported.
- Full content/path verification detects changes through the final verification pass, but cannot make arbitrary external processes honor an atomic snapshot; an external write immediately after that pass can still occur. Stop external edits and let cloud synchronization finish before copying; the app's own writers are suspended. A filesystem snapshot or generation-based manifest would be needed for a fully concurrent copy.
- A cancelled pending selection keeps a successfully copied library on disk. This is intentional to avoid deleting user-visible data; the user may remove the unused copy in Finder.
- The local index cache is keyed by resolved path. Moving a selected folder can leave its old disposable cache behind. Cache pruning is deferred; authoritative data is unaffected.
