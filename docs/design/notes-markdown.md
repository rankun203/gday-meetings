---
title: Markdown notes with images and timeline links
date: 2026-09-26
status: accepted
scope: swift-app-notes
---

# Markdown notes with images and timeline links

This design covers the Notes tab in the Swift macOS client. The direction and the decisions in [Decisions](#decisions) are accepted. Phase 1 is implemented and undergoing validation; image support remains planned. [Open follow-ups](#open-follow-ups) lists the remaining items.

## Goals

1. Paste or drag images into notes, and read them inline.
2. Store notes as Markdown.
3. Link each note to a time on the recording timeline. Command-click on a word plays from that time, as clicking a transcript time does.
4. Keep editing native, offline, and buildable with Command Line Tools only.

## Current state

- Notes use an AppKit TextKit 2 editor. Markdown syntax stays visible; valid timeline markers appear in the gutter.
- `notes.md` in each meeting folder is the saved source. `Meeting.notes` remains in memory for search, provider context, and export. Typing uses a half-second debounce; focus changes, closing notes, recording stop, and quit flush pending edits.
- Library format version 3 moves notes out of `library.json`, following version 2's speaker identity migration. An older library is backed up before migration. A failed notes save keeps the app open at quit.
- Search removes markers, summaries and Markdown export use readable time prefixes, and JSON export and server archive retain Markdown markers.
- Images remain Markdown text in phase 1. No image URL is fetched. The existing server accepts flat `.json`, `.md`, and `.txt` artifacts and has no image attachment type.
- The app targets macOS 14.2 and adds no package dependency. Playback links use the existing meeting player, and recording times use `MeetingStore.recordingDuration` until exact audio-epoch alignment is added.

## Decisions

- Build an in-house editor on AppKit `NSTextView` with TextKit 2. Skip the MarkdownEngine trial.
- Add no Swift package. The dependency policy stays unchanged.
- Record one time per line. Phrase-level times remain an optional refinement.
- Playback from a note starts 3 seconds before the note's time, clamped at 0. This is fixed, not a setting.
- **Play From Line** uses Command-Return.
- Time markers use the form `<!-- gday:t=12:34.5 -->`.
- Pasted and dropped images keep their original file in `assets/`. Resizing writes a smaller display copy next to it.
- A one-way notes migration is acceptable before version 1.0.0 if it keeps a backup. Library format versioning is in place (see [Migration](#migration)).
- Archiving notes that contain images is not blocked. The text is archived with a warning until the server phase adds image support.

## Recommendation

Build a focused native editor: an AppKit `NSTextView` using TextKit 2, wrapped for SwiftUI, with Markdown as the saved format. Show Markdown syntax in place with light styling (Bear-style live preview). Show images and time links as native objects in the editor, and write them back as plain Markdown when saving. Add no third-party dependency.

### Why this approach

- `NSTextView` provides input methods, spelling, dictation, undo, Find, Services, Writing Tools, and VoiceOver support. Apple's WWDC26 TextKit session recommends starting from the framework text view and adding behavior, rather than building a custom text view ([WWDC26 session 370](https://developer.apple.com/videos/play/wwdc2026/370)).
- A tailored editor makes the gutter, Command-click, and time tracking straightforward. With an existing editor package, these features would require a fork.
- Styling never changes the saved text. A styling mistake is cosmetic and cannot lose data, so a small in-house styler is enough for meeting notes.
- It keeps the build offline with no new dependency process.

### Editor model

The editor keeps an in-memory attributed string. It converts to and from Markdown only at load and save.

| Saved Markdown | In the editor |
| --- | --- |
| Ordinary Markdown text | The same text. Syntax characters such as `**` and `#` stay visible but dimmed. Headings, emphasis, code, quotes, lists, and links are styled. |
| Time marker `<!-- gday:t=12:34.5 -->` | Removed from the text. Stored as a custom attribute on the characters it covers. Shown in the time gutter. |
| Image line: `![Whiteboard](assets/whiteboard.png)`, or the resized form described in [Images](#images) | One attachment character showing the image. The alt text, paths, and width are kept in attributes. |

- Fonts are applied in `NSTextStorageDelegate.textStorage(_:didProcessEditing:range:changeInLength:)`, limited to edited paragraphs, so styling never registers undo steps. Colors can use TextKit 2 rendering attributes.
- Do not read `NSTextView.layoutManager`. Reading it permanently switches the view to TextKit 1 compatibility mode ([NSTextView](https://developer.apple.com/documentation/appkit/nstextview)).
- Formatting commands in the **Format** menu: **Bold** (Command-B), **Italic** (Command-I), **Link…** (Command-K). They add or remove Markdown syntax. Return continues lists and task lists. Tab and Shift-Tab indent list items. Clicking a task checkbox toggles `[ ]` and `[x]`.
- External-URL images stay as Markdown text and are never fetched. This keeps notes offline and private.

### Storage

Store notes in the meeting folder:

```text
<library>/<meeting-id>/
  notes.md                  Markdown notes with time markers
  assets/                   images referenced by notes.md
    whiteboard.png          original, as pasted or dropped
    diagram.png             original
    diagram-480w.jpg        resized display copy of diagram.png
  …                         existing audio and archive files
```

- `notes.md` is the saved copy of the notes. `Meeting.notes` stays as an in-memory property so search, summaries, and export keep working. It is no longer saved to `library.json` after migration.
- The folder name `assets/` matches the [TextBundle](http://textbundle.org/spec) layout, so a TextBundle export is a copy plus `info.json`.
- Write with a short debounce (about 0.5 seconds) and immediately when the editor loses focus, the meeting changes, recording stops, or the app quits. Use atomic writes with `0600` permissions, matching `library.json`. Create the meeting folder on first write.
- **External edits:** when the editor opens a meeting, reload `notes.md` if its modification date changed. The optional refinements phase adds a file watch. If the file changes while there are unsaved edits, keep the app's version and save the external copy as `notes (changed on disk).md`.

### Migration

- At library load, for each meeting whose `notes` is non-empty and whose folder lacks `notes.md`, write `notes.md` and then clear the field. This is a layout change: increase `MeetingLibrary.currentVersion` to 3 and add the step to `MeetingLibrary.migrations`.
- **Library format policy** (implemented in `Core/LibraryFormat.swift`; see the contract comment on `MeetingLibrary`):
  - Any change to the library layout, including where notes are stored, increases the `library.json` version.
  - A build opens its own version and older ones. Before migrating an older library, it copies `library.json` to `library-v<N>-backup.json`. A step that changes files outside `library.json`, such as writing `notes.md`, must also keep those files recoverable or leave the old data readable.
  - A build that finds a newer version shows “This library was saved by a newer version of Gday Meetings.” and asks the person to install the latest version. The library stays read-only: no save path writes `library.json` or `settings.json`.
  - A save always writes the current version, so it cannot lower the version.
- **Before 1.0.0:** one-way migrations are acceptable because there is a single user. An older build then refuses the migrated library instead of showing empty notes.

### Time markers

A time marker is a Markdown HTML comment:

~~~markdown
## Budget <!-- gday:t=3:05 -->

- Hiring freeze until Q3 <!-- gday:t=3:41.5 -->
- Revisit vendor contract <!-- gday:t=5:12 -->

![Whiteboard](assets/whiteboard.png) <!-- gday:t=7:02 -->

<a href="assets/diagram.png"><img src="assets/diagram-480w.jpg" width="480" alt="Architecture diagram"></a> <!-- gday:t=8:15 -->

<!-- gday:t=9:30 -->
```sql
select * from budgets
```
~~~

**Syntax and placement**

- Format: `<!-- gday:t=[h:]mm:ss[.f] -->`. The `gday:` prefix keeps user comments untouched. The time is seconds on the meeting's shared playback timeline.
- A marker times the text before it on the same line, back to the previous marker or the start of the line. Markers always follow text, never start a line. Inside a list item, a line that starts with `<!--` would begin an HTML block and break the list.
- An image line, in either form, is timed like any other line: the marker follows the image on the same line. The resized form starts with `<a …>` followed by more content, so CommonMark treats it as inline HTML in a paragraph, not an HTML block, and the marker stays inline.
- A fenced code block or table gets one marker on its own line before the block, because a comment inside it would become content.
- HTML comments are raw HTML in [CommonMark](https://spec.commonmark.org/0.31.2/#raw-html). Renderers that pass HTML through or sanitize it do not display comments, so other apps show clean notes. Verify GitHub, Obsidian, and VS Code preview during Phase 1 (notes with times).

**Granularity:** one time per line. A line is a paragraph, heading, list item, or image. Command-click on any word plays from its line's time. The format allows several markers per line, so phrase-level times in the optional refinements phase need no format change.

**Where the time comes from.** When a line first gets text, the editor asks a clock for the current time:

| Situation | Time recorded |
| --- | --- |
| This meeting is recording | Elapsed time on the recording's audio clock (host time minus `AudioCapture` epoch). Fall back to `MeetingStore.recordingDuration` until capture exposes it. |
| This meeting is loaded in the player, playing or paused | The player position (`playback.progress.time`). This matches [Notability](https://support.gingerlabs.com/hc/en-us/articles/206060617-Recording-and-Playing-Audio), which times notes added during playback. |
| No recording and no playback of this meeting | No time. The line has no marker and no gutter label. |

**How times survive editing**

- Typing within a timed line keeps its time. Fixing a typo later does not retime the line.
- Pressing Return in the middle of a line gives both halves the original time. A new empty line gets its time when its first character is typed, not when Return is pressed.
- Cut and paste within the same meeting keeps times, using a private pasteboard type that carries the meeting ID and Markdown with markers. Paste from anywhere else gets the current time. Markers from another meeting are removed.
- Copy also writes plain Markdown without markers, so pasting into other apps gives clean text.
- If an external editor deletes or damages a marker, that line becomes untimed, or the marker shows as ordinary text. Notes are never lost.
- **Set Time to Playback Position** in the context menu retimes the selected lines. This covers notes written with no recording or playback.

### Command-click and the time gutter

- A fixed-width gutter (about 44 pt, always reserved so text never shifts) shows each timed line's time on its first visual line: caption size, monospaced digits, secondary color. It matches the transcript's time buttons: a link style with hover feedback and the tooltip "Play from this point". Lines without a time show nothing.
- Clicking a gutter time or Command-clicking text calls `playback.play(meeting:files:at:)` with the line's time minus 3 seconds, clamped at 0. People usually write a note a few seconds after hearing it. The gutter shows the saved time, not the earlier start.
- Holding Command over timed text shows the pointing-hand cursor and highlights that line's gutter time.
- Command-click normally adds a discontiguous selection in `NSTextView`. Inside notes it plays instead. Command-drag keeps the system behavior.
- While recording, playback is blocked (`isPlaybackBlocked`). Gutter times are disabled and Command-click does nothing, as with transcript times.
- **Keyboard:** **Play From Line** (Command-Return) plays from the line containing the insertion point. It appears in the context menu and the playback menu.
- **VoiceOver:** each visible gutter time is a button labeled, for example, "Play from 12 minutes 34 seconds". The text view offers the custom action **Play From Line**. Image attachments are labeled with their alt text.
- Implementation on macOS 14: overlay the gutter in the scroll view's document view. Position labels from `NSTextLayoutManager.enumerateTextLayoutFragments` after viewport layout, and reuse label views for visible lines only. The TextKit APIs from WWDC26 for line numbers and rendering surfaces are for the 2027 releases. They could replace this overlay later behind an availability check.

### Images

**Input**

- Paste image data or image files, and drag image files into the editor. The editor registers image drag types, so drops on the text view go to notes. Audio files dropped on it are passed to the existing `AudioFileDrop` import. Dropping images outside the editor is unchanged.
- **Image file** (on the pasteboard or dropped): copy it into `assets/` with its original bytes and format. Normalize the name from the original: lowercase, spaces to hyphens, and remove characters other than letters, digits, hyphens, underscores, and the extension dot. Use `image` if nothing remains. When the pasteboard has both a file and image data, use the file.
- **Image data without a file** (for example, a screenshot copied to the clipboard): save it as PNG named `pasted-image-YYYYMMDD-HHMMSS.png` in local time. Keep the source's DPI metadata so its display size is preserved.
- **Name collisions:** if the name is taken, add `-2`, `-3`, and so on before the extension. If the existing file has identical bytes, reuse it instead of adding a copy.
- The original is always kept in `assets/`, at any size and in any format ImageIO can read. HEIC and TIFF originals may not display in browsers or other Markdown apps.

**Default size**

- Display size in points is pixel size ÷ scale. The scale comes from the image's DPI metadata through ImageIO (`kCGImagePropertyDPIWidth` ÷ 72) or `NSImage` point size. A 144 DPI Retina screenshot shows at 2×, so it is not zoomed in. With no DPI metadata, use 1×.
- The maximum display width is the editor's text width. Wider images shrink to fit, keeping the aspect ratio, and re-fit when the window resizes.
- Decode a downsampled image for display with ImageIO (`CGImageSourceCreateThumbnailAtIndex`) and cache it, so large photos stay responsive.
- Other apps ignore DPI metadata for `![…](…)`, so an unresized Retina screenshot shows at its pixel width there, limited by the page width.

**Resizing**

- Drag an image's corner handle in the editor, or edit the `width` attribute in the Markdown. Width is in points, and the maximum is still the editor's text width.
- A resized image is saved in this form:

  ```html
  <a href="assets/diagram.png"><img src="assets/diagram-480w.jpg" width="480" alt="Architecture diagram"></a>
  ```

  GitHub, Obsidian, and VS Code preview render inline HTML `<a>` and `<img>` with a `width` attribute. The link opens the full-size original. An unresized image stays plain `![alt](assets/name.png)`. Resizing back to the natural size returns to the plain form.
- **Display copy:** when the width is set, the editor writes `<base>-<width>w.<ext>` next to the original. `<base>` is the original's name without extension. The copy has 2× the display width in pixels so it stays sharp on Retina displays. It is never larger than the original: if 2× the width is at least the original's pixel width, no copy is made and `src` points to the original.
- **Format of the copy:** PNG if the image has transparency. Otherwise encode both PNG and JPEG (quality 0.85) and keep the smaller file; PNG usually wins for flat screenshot content, and JPEG for photos. Both formats display in every Markdown app and browser. HEIC is smaller but displays poorly outside Apple apps. ImageIO on macOS 26.6 reads WebP but does not list it as a writable type (`CGImageDestinationCopyTypeIdentifiers`), so WebP is not an option.
- When the `width` attribute is edited by hand, the editor redraws the image at that width immediately. It writes the new display copy and updates `src` on the next save.
- A copy name that is taken by a different original gets a collision suffix. An existing copy of the same original at the same width is replaced.

**Reading, deletion, and other apps**

- Double-click opens the original in Quick Look. The context menu offers **Edit Description…** (alt text), **Show in Finder**, and **Copy Image**.
- Removing an image from notes leaves its files so undo works. When the meeting's notes close, and at launch, move files in `assets/` that `notes.md` no longer references (as a Markdown image path, `src`, or `href`) to the Trash. This also removes display copies left over from earlier sizes. Deleting a meeting already moves its folder to the Trash.
- Relative paths display in Obsidian, VS Code, Typora, and GitHub when the meeting folder is opened. External-URL images are left untouched.

### Editing and reading

Use one live-preview editor for both, with no separate edit and read modes. Dimmed syntax stays visible. Hiding syntax away from the insertion point makes text reflow as the insertion point moves, which conflicts with the stable-layout rule in [UI design](../../apps/client-macos-swift/docs/UI_DESIGN.md). Images, times, headings, and lists already read well in this editor.

A reading view that hides syntax can be added in the optional refinements phase if needed. Because it is not editable, it has no reflow problem. It could reuse the same styler with syntax characters hidden.

### Effects on other features

| Feature | Change |
| --- | --- |
| Library search | Search notes text with markers removed. |
| Summaries and chat | Send notes with markers written as `[12:34]` prefixes so answers can cite times. Do not send images. |
| Markdown export | Remove markers, or write them as `[12:34]` prefixes. Copy referenced images to a folder beside the exported file and rewrite the paths. Offer TextBundle export when notes contain images. |
| JSON export and import | Include `notes` text with markers. Images are not included; see [Open follow-ups](#open-follow-ups). |
| Legacy import | Write imported notes to `notes.md`. |
| Server archive | Send `notes.md` with markers. Archiving is never blocked by images. Until Phase 3 (export and server archive of images) adds a server attachment type, show "Images in notes aren't archived yet." and archive the text only. |
| UI Preview | Add a synthetic `notes.md` with times, a plain image, and a resized image to the fixtures. |

## Alternatives considered

| Option | Result | Main reason |
| --- | --- | --- |
| Native `NSTextView` with an in-house styler | Chosen | Native behavior, full control over times and gutter, no dependency. |
| Vendor [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) (MarkdownEngine) | Not adopted | Apache-2.0, macOS 14, live styling, image embeds, and image paste. But it is about 19,000 lines, pre-1.0, and has no hooks for a time gutter or Command-click, so adopting it means maintaining a fork. Its manifest declares remote dependencies. |
| Vendor [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm) for parsing | Deferred | Apache-2.0, spec-correct GFM parsing with source ranges. Needs `swift-cmark` source too and a change to the dependency policy. Consider it only if styling edge cases become a problem, such as nested lists or tables. |
| [STTextView](https://github.com/krzyzanowskim/STTextView) | Rejected | GPL-3.0 or commercial license, while this repository is MIT. It targets code editing. |
| SwiftUI `TextEditor` with `AttributedString` | Rejected | Requires macOS 26 ([WWDC25 session 280](https://developer.apple.com/videos/play/wwdc2025/280)); the app supports macOS 14.2. It edits rich text, not Markdown, and SwiftUI text does not embed attachments ([analysis](https://fatbobman.com/en/posts/a-deep-dive-into-swiftui-rich-text-layout)). |
| Foundation `AttributedString(markdown:)` | Rejected for editing | Parses Markdown one way. It has no source ranges and no way to write back to Markdown. SwiftUI does not render its images or block structure ([example](https://blog.eidinger.info/3-surprises-when-using-markdown-in-swiftui)). Usable for a read-only summary view. |
| [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) or [Textual](https://github.com/gonzalezreal/textual) | Rejected | Display only, not editing. MarkdownUI is in maintenance mode; Textual is early (0.x). |
| `WKWebView` with CodeMirror 6, Milkdown, or TipTap | Rejected | Strong editors: [MarkEdit](https://github.com/MarkEdit-app/MarkEdit/wiki/Why-MarkEdit) shows CodeMirror 6 can feel good on macOS. But bundling them needs Node and npm, or a checked-in minified bundle, which breaks the source-only, Command Line Tools build policy. It also needs a JavaScript bridge for times, playback, images (`WKURLSchemeHandler`), focus, and the Space key; a web content process per open editor; and extra work to match native menus, Services, and Writing Tools. |

Other findings:

- TextKit 2 still has bugs in viewport layout, the extra line fragment, and attachments. Some are regressions between macOS versions ([TextKit 2: the promised land](https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land), [STTextView bug list](https://github.com/krzyzanowskim/STTextView)). Meeting notes are short, which limits exposure. Test on macOS 14, 15, and 26.
- [Downright](https://github.com/ezzy1630/Downright) (MIT, macOS 14) uses one `NSTextView` with raw Markdown as the saved text and decorations over source ranges. It supports the same basic approach. Its code is a useful reference, not a dependency.

## Phased plan

Each phase ends with `make format-macos`, `make lint-macos`, `make test-macos`, and a worklog. UI checks use UI Preview in Light, Dark, and System appearance at small and large window sizes, following [UI design](../../apps/client-macos-swift/docs/UI_DESIGN.md).

### Phase 1: Markdown notes with times

Implemented; final UI and compatibility validation is tracked in the [worklog](../worklogs/2026-09-26-markdown-notes.md).

- `notes.md` storage, migration, debounced atomic save, and change detection when a meeting opens.
- `NSTextView` editor with live styling, Format menu commands, and list continuation.
- Time markers: parse, serialize, the recording and playback clocks, the time gutter, Command-click with the 3-second lead, **Play From Line**, and VoiceOver actions.
- Search, summaries, export, and archive read notes with markers removed or converted.
- **Tests:** marker round trip (parse then serialize returns the same bytes for valid files; unrelated comments are untouched); time inheritance on typing, splitting lines, and paste; migration from `library.json`; save on quit; clock choice for recording, playback, and neither; lead time clamped at 0.
- **Preview:** timed and untimed lines, Command-click and gutter clicks seek the silent player, keyboard-only use, VoiceOver labels, and no layout shift during playback.
- **Estimate:** about 5–7 days.

### Phase 2: Images in notes

- Paste and drag of image files and image data, name normalization and collisions, Retina-aware default size, fit to editor width, downsampled display, Quick Look, and the image context menu.
- Resizing by drag and by the `width` attribute, display copies, and cleanup of unreferenced files.
- Drop routing between the notes editor and `AudioFileDrop`.
- **Tests:** round trip of both image forms with a trailing marker; name normalization and `-2` suffixes; reuse of identical files; screenshot data saved as PNG with DPI kept; 72 and 144 DPI display sizes; display copy width, 2× pixels, no upscaling, and format choice; cleanup keeps files referenced by `src` or `href` and files needed for undo; path validation (no `..` or absolute paths).
- **Preview:** a large synthetic image, a 144 DPI screenshot, window resizing, drag resizing, dark appearance, and selection and deletion of image lines.
- **Estimate:** about 4–6 days.

### Phase 3: Export and server archive of images

- Markdown export with an assets folder, TextBundle export, JSON export behavior for images, and server attachments for images (server change and archive hash).
- **Tests:** exported bundles open in another Markdown app; archive hash changes when an image changes.
- **Estimate:** about 3–5 days, including the server.

### Phase 4: Optional refinements

- Phrase-level times: text appended to a line after a pause (for example 15 seconds) gets a new marker.
- A file watch for `notes.md`, a syntax-hiding reading view, and tables.
- Adopt the 2027 TextKit gutter APIs behind an availability check.

## Risks

- **TextKit 2 bugs:** layout glitches with attachments or long lines. Mitigation: short notes, no custom layout fragments in Phase 1 (notes with times), testing on three macOS versions.
- **Marker loss in other editors:** some editors may reformat or strip comments. The result is untimed lines, not lost notes.
- **Recording clock:** exact alignment needs a read-only elapsed-time accessor on `AudioCapture`. That code is currently being changed by other work, so coordinate before adding the accessor.
- **Styler edge cases:** nested lists and tables may be styled wrong. The saved text is still correct; swift-markdown is the upgrade path.
- **Command-click conflict:** notes lose Command-click discontiguous selection. Command-drag and Option-drag selection are unaffected.
- **Hand-edited image HTML:** other editors may reformat the `<a><img></a>` form. The editor parses only this form; anything else stays as visible text, and the files remain in `assets/` until no longer referenced.

## Open follow-ups

1. **JSON export and images:** decide in Phase 3 (export and server archive of images) whether JSON export embeds images or refers to an exported assets folder.
2. **Renderer check:** confirm in Phase 1 (notes with times) and Phase 2 (images in notes) that GitHub, Obsidian, and VS Code preview hide the markers and render the resized image form.
