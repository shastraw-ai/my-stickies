# my-stickies

macOS-only sticky notes with nested checkboxes. Swift + AppKit/SwiftUI, no deps.

## Commands
- `./build.sh [--install]` — build `build/my-stickies.app`, optionally to /Applications
- `./.build/release/my-stickies --self-test` — outline logic assertions
- `./tools/make-icon.sh` — regenerate `Resources/AppIcon.icns`

Everything is named `my-stickies`. The one exception is the SwiftPM *target*
(`my_stickies`, in `Package.swift`) — Swift module names can't contain hyphens. The
product, binary, and bundle are all `my-stickies`; don't reintroduce a second name.

## Rules
- No `swift test`: XCTest needs Xcode, this machine has Command Line Tools only.
  New model-logic tests go in `SelfTest.swift`, reachable via `--self-test`.
- Hierarchy is a flat `[Item]` + `depth`, never a nested tree. Subtree ops go
  through `descendantRange(of:)`; don't hand-roll depth scans.
- Checklist rows must use `OutlineTextField`, not SwiftUI `TextField` — SwiftUI
  eats `⇥` for focus traversal and drops strikethrough in the field editor.
- Mac-only by design. Don't add cross-platform abstractions.
- Focus moves between rows via `WrappingTextField.takeFocus` / `focusWhenPlaced`,
  never `DispatchQueue.main.async`. A new row isn't in a window during its first
  `updateNSView`, and an async hop lets the next keystroke land in the old row.
  `onStrayInput` is the backstop; don't remove it.
- Appearance (color/font/size/opacity) must stay reachable from all three of: header
  popover, right-click menu, Format menu. Users don't find a single entry point.
- Deleting a note moves it to `trash_notes.json` and is never confirmed; only
  permanent deletion (purge, empty trash) confirms. Don't add an alert to
  `moveToTrash`.
- New `Note` fields must be Optional or the synthesized decoder throws on existing
  files. Non-optional-with-default does NOT decode a missing key. Expose a
  non-optional computed accessor (see `turnsSolidInUse`) and cover it in
  `legacyDecoding()`.

## Files
- `notes.json` — active notes; `trash_notes.json` — deleted, beside it always.

## Env vars
- `MY_STICKIES_NOTES` — alternate notes.json path
- `MY_STICKIES_SNAPSHOT` — dump each window to PNG 1.5s after launch (dev aid)
