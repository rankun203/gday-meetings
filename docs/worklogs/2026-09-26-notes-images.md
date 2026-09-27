---
title: Images in Markdown notes
date: 2026-09-26
status: implemented
scope: swift-app-notes-images
---

## Problem

Pasting image data produced the system alert sound; dragging an image inserted a file path. Phase 1 supported text only. The supplied screenshots and an isolated Preview Notes screenshot were inspected before editor changes.

## Design and implementation

Keep Markdown source and its UTF-16 offsets intact. Native image decorations below standalone image syntax reserve space through TextKit 2 paragraph styling. This keeps the existing timeline and native undo model, while showing images inline with notes.

Paste and drop copy originals into private meeting-local assets. Clipboard image data becomes PNG with DPI retained. Resizing writes linked HTML and one stable preview per original, without upscaling. A private ownership index is recoverable from exported linked image references. Multiple widths share the largest requested preview; repeated resizes atomically replace the same path. Undo, redo, save, export, and new archive snapshots regenerate a missing or outdated preview from the original. Only managed obsolete previews are removed after a successful notes save. A shared parser and path resolver serve rendering, exports, archives, and cleanup; external URLs are never fetched. Unsupported source remains editable.

## Reasoning

Replacing source with an attachment character would require a second offset-mapping model for every editing and timeline operation. Decorations preserve text behavior. Asset cleanup waits until a successfully saved editor closes, after undo history is discarded, or until the next launch. Ambiguous or malformed source references keep files conservatively.

## Technical debt

The focused parser renders standalone Markdown images and the accepted linked image HTML form. Other HTML stays visible as source. The first PNG/JPEG format choice remains fixed for a preview’s lifetime to keep its path stable; later sizes may be slightly larger than a fresh minimum-size format choice. This avoids rewriting historical undo references. Conservative cleanup may retain an unused asset if its filename still appears in prose or code; remove that reference to make it eligible for cleanup. Other Markdown renderers may display DPI-only image sizes differently, as documented in the design. Image import is bounded to 100 megapixels to keep clipboard conversion and thumbnail work within a practical memory limit; this narrows the design’s original unlimited-size wording. Larger images need resizing before import.

Library format version 4 records the image and phrase-timing layout. The version 3 upgrade preserves notes bytes and backs up metadata; older clients use their newer-version read-only guard.

## User-requested preview lifecycle

The user requested the original plus one processed preview, superseding retention of historical display copies. Resizing never removes an original or an unrelated asset. Existing orphan cleanup after image deletion and discarded undo still moves unreferenced originals to Trash. Imported notes do not need the private preview index: reserved preview filenames and original/src links rebuild it safely. Generation failures leave prior usable bytes and notes intact. Exact UUID preview names and indexed-original checks prevent a corrupt preview mapping from targeting another original. Multiple imported preview references are normalized to one source path, and only obsolete managed copies are removed after the rewritten notes save. Original file modification time and size trigger regeneration during save, export, or archive even when its pixel dimensions are unchanged. Asset-only changes are not polled in the background.

## Native editor corrections

The first isolated app crashed after a full replacement with 30 lines and a final image, followed by scrolling. The preserved September 27 00:28 report identifies `NSConcreteTextStorage attributedSubstringFromRange: Out of bounds` during TextKit 2 viewport layout. A second candidate still failed with an internal `NSRLEArray` exception. Image spacing and typography now update in a deferred content editing transaction, outside view layout and text-storage processing callbacks. Final save and error delivery run after SwiftUI dismantles the view, retaining the meeting-specific editor until that work completes.

The hosted regression did not reproduce those aborts. It did prove a separate 72-point final-image gap: the image anchor included the terminal empty text line. Excluding that line corrected the anchor from 604 to 532 points. On September 27 at 11:29, the approved Fresh app, containing the earlier 01:02 crash-fix candidate, passed the actual previous crash sequence: replacing notes with 30 lines, a final plain image and trailing newline, then scrolling to the bottom. Screenshots show the image immediately below its markup and the app remained responsive. A packaging mistake copied the obsolete pre-rename app output; binary UUID `886B803A-A33F-3823-89FA-7CA1EBE0B3A5` confirms this was not the latest continuity build. The actual crash check therefore validates the earlier typography and placement fixes only. The current source has automated validation, with its remaining visual checks still outstanding.

Morning screenshots showed previews flashing while typing below them. The complete notes string had invalidated every image view. The editor now retains surviving views and bitmaps, rebases their ranges after native edits, and updates only managed image spacing. Deferred typography styles changed paragraphs and reuses compiled expressions. Identical replacement clears completed edit bookkeeping; duplicate-image deletion preserves the surviving view. No measured CPU improvement is claimed.

Native Paste now advertises bitmap types and enables the command for an image-only clipboard. Image actions preserve selection and viewport; drag deltas use the stable text view. The corner has a 24-point hit target, a system diagonal cursor on macOS 15 or later, and a symbol cursor on macOS 14. At the user’s request, the permanent blue square was removed; the drag outline and accessible width action remain.

## Validation

- All 308 Swift tests across 63 suites pass (8.244 seconds). Formatting, lint, and diff checks pass. The signed production build succeeds (38.54 seconds).
- Core tests cover parser round trips, URL rewriting, traversal and dangling symlinks, original bytes, DPI, dimensions/transparency, collisions, cross-meeting copies, conflict-backup retention, repeated resizing, multi-width sharing, preview regeneration, imported references, and corrupt ownership indexes.
- Native tests check image identity, attachment and visibility on each following-text keystroke before and after deferred layout; preceding edits, identical replacement, repeated images, Return spacing, deletion/undo, and timestamp/caret preservation. The hosted test covers state binding and the real workspace with persistence, watcher/debounce callbacks and accessibility reads.
- Actual UI checks passed the long-paste/scroll crash sequence and terminal placement. The width sheet changed the final image to 180 points while preserving the bottom viewport. Earlier UI checks verified invalid-width validation and resize undo/redo.
- Remaining UI checks: uninterrupted per-keystroke visual continuity, partial-markup deletion/undo on the final app, bitmap Copy Image→Paste, and hover/drag after the square removal. Concurrent user interaction produced repeated tool state-change guards, so these actions were paused rather than overwriting the active fixture. Unit coverage is not described as visual acceptance.

The synthetic fixture uses locally generated images and temporary meeting folders. User image originals remain untouched. Existing Command Line Tools linker search-path warnings remain; no deprecated API warning was introduced. Export and archive validation is recorded in the phase 3 worklog.
