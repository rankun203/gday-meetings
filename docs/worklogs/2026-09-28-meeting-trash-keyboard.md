---
title: Move a meeting to Trash with the keyboard
date: 2026-09-28
status: validated
scope: swift-meeting-list
---

# Move a meeting to Trash with the keyboard

## Problem

Delete did not act on the selected meeting. The existing confirmation claimed permanent deletion even though the store used the macOS Trash.

## Implemented solution

Plain Delete or Forward Delete in the focused meeting list opens a native confirmation. **Move to Trash** is the Return default; **Cancel** responds to Escape. The context menu uses the same action wording. Text editing in other controls is unaffected because the handler belongs to the native meeting table.

The operation retains the store's recording and background-work protections and uses the existing `FileManager.trashItem` path. A rejected or failed deletion keeps the meeting selected. The dialog states that the meeting and its files can be restored in Finder.

## Reasoning

Keyboard and menu requests share the same confirmation and storage operation. A confirmation prevents accidental deletion while the default button supports the user's requested Delete–Return sequence. The existing selected-meeting Preview screenshot was inspected before implementing the gesture.

## Validation

Root agent will verify Escape cancellation and Return confirmation using isolated synthetic Preview meetings, followed by a consolidated build and lint.

The rebuilt Preview passed the final Delete–Return check on September 28: the synthetic meeting disappeared from the list, selection cleared, and no missing-metadata error appeared. Earlier Escape cancellation also passed. Real meetings were not used for deletion validation.

## Technical debt

None introduced. Restoring the folder from Trash uses the existing file-monitor discovery path; this change does not add an in-app undo stack.

## Validation follow-up

Preview confirmed Delete opens the dialog, Escape cancels, and Return moves the synthetic meeting to Trash. That check exposed a post-deletion error banner: the confirmation's success check called the disk-loading `meeting(id:)` accessor after the folder was removed. Deletion now returns an explicit success result, and the UI uses that result to clear selection without rereading the deleted folder. The existing background-job protection regression now checks both rejected and successful deletion results and confirms that successful removal does not create a meeting-page error.
