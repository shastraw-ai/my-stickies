# my-stickies

macOS-only sticky notes with nested checkboxes. Swift + AppKit/SwiftUI, no deps.

## Commands
- `./build.sh [--install]` — build `build/my-stickies.app`, optionally to /Applications
- `./.build/release/Stickies --self-test` — outline logic assertions
- `./tools/make-icon.sh` — regenerate `Resources/AppIcon.icns`

The app bundle is `my-stickies.app`; the SwiftPM product and Swift module stay
`Stickies` (hyphens aren't valid in module names). `build.sh` maps one to the other.

## Rules
- No `swift test`: XCTest needs Xcode, this machine has Command Line Tools only.
  New model-logic tests go in `SelfTest.swift`, reachable via `--self-test`.
- Hierarchy is a flat `[Item]` + `depth`, never a nested tree. Subtree ops go
  through `descendantRange(of:)`; don't hand-roll depth scans.
- Checklist rows must use `OutlineTextField`, not SwiftUI `TextField` — SwiftUI
  eats `⇥` for focus traversal and drops strikethrough in the field editor.
- Mac-only by design. Don't add cross-platform abstractions.

## Env vars
- `STICKIES_NOTES` — alternate notes.json path
- `STICKIES_SNAPSHOT` — dump each window to PNG 1.5s after launch (dev aid)
