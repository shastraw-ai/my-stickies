# my-stickies

A macOS sticky-note app where every note is a checklist. Notes float above other
windows, nest to arbitrary depth, and live in one JSON file you own.

Native Swift + AppKit/SwiftUI. macOS 13+. No dependencies, no Xcode required.

## Build

```sh
./build.sh              # -> build/my-stickies.app
./build.sh --install    # also copies it to /Applications
```

Then open it from `/Applications` (or `open build/my-stickies.app`).

## Using it

Each note is a window with a title and a checklist. Type in a row and use:

| Key | Does |
| --- | --- |
| `⏎` | New row below, same level |
| `⇥` | Nest under the row above |
| `⇧⇥` | Move back out one level |
| `↑` / `↓` | Move between rows |
| `⌫` on an empty row | Delete the row |
| `⌘N` | New note |
| `⌘W` | Close the note (keeps it — reopen from the Notes menu) |
| `⌘0` | Show every note again |

Click a checkbox to strike a row through. Checking a parent checks everything under
it; a parent checks itself once all of its children are done. Rows with children get a
chevron — collapse one and it shows a `2/5` progress count instead.

The `✕` on hover deletes a single row (and anything nested under it). The trash button
in the header deletes the whole note, after a confirmation.

## Color, font, and transparency

Every appearance setting is **per-note** and saved with the note. Three ways to reach
them, whichever you find first:

- The **palette button** in the note header — color swatches, font, size slider, and a
  transparency slider in one popover.
- **Right-click anywhere on a note** — Color, Transparency, and Font submenus.
- The **Format menu** in the menu bar, which also has shortcuts:

| Key | Does |
| --- | --- |
| `⌘+` / `⌘-` | Bigger / smaller text |
| `⌥⌘+` / `⌥⌘-` | More opaque / more transparent, in 5% steps |
| `⌘T` | Float this note above other windows |

Transparency runs from 100% down to 20%. It applies to the paper only — the text stays
fully opaque so a see-through note is still readable.

Closing a note's window hides it rather than deleting it — everything is still in the
Notes menu, and `⌘0` brings them all back. Clicking the Dock icon does the same.

## Where your notes live

```
~/Library/Application Support/my-stickies/notes.json
```

Plain JSON, saved half a second after you stop typing and again on quit.
*File → Reveal notes.json in Finder* jumps straight to it.

Set `MY_STICKIES_NOTES=/path/to/other.json` to point the app at a different file — useful
for a separate work/personal set, or for keeping notes in a synced folder.

If the file is ever unreadable, it's renamed to `notes.corrupt-<timestamp>.json` rather
than overwritten, and the app starts fresh.

## Development

```sh
swift build -c release
./.build/release/my-stickies --self-test    # outline logic checks
./tools/make-icon.sh                        # regenerate Resources/AppIcon.icns
```

`swift test` is unavailable here: XCTest ships with Xcode, not the Command Line Tools.
The equivalent assertions live in `Sources/my_stickies/SelfTest.swift` and run through
the `--self-test` flag instead.

`MY_STICKIES_SNAPSHOT=/some/dir` dumps a PNG of each note window 1.5s after launch, for
checking rendering without screen-recording permission.

### Layout

| File | Holds |
| --- | --- |
| `Models.swift` | `Item`, `Note`, palettes, and every outline operation |
| `Store.swift` | Load/save, debounced autosave, new-note placement |
| `NoteWindow.swift` | The floating `NSPanel` and the panel↔store sync |
| `NoteView.swift` | SwiftUI note UI: header, rows, appearance popover |
| `OutlineTextField.swift` | `NSTextField` wrapper for ⇥/⏎/⌫ handling and strikethrough |
| `SelfTest.swift` | Assertions for the outline logic |
| `main.swift` | App delegate and menu bar |

Hierarchy is stored as a **flat array plus a `depth` field**, not a nested tree. Indent,
outdent, delete-with-children, and collapse all become index arithmetic over a
contiguous range — see `descendantRange(of:)` in `Models.swift`.
