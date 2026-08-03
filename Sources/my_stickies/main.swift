import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    private var windows: WindowManager!
    private var notesMenu: NSMenu!
    private var formatMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        windows = WindowManager(store: store)
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)

        // Dev aid: MY_STICKIES_SNAPSHOT=/path/to/dir dumps each note window to a PNG.
        if let dir = ProcessInfo.processInfo.environment["MY_STICKIES_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Self.snapshotWindows(into: dir) }
        }
    }

    private static func snapshotWindows(into dir: String) {
        for (i, window) in NSApp.windows.enumerated() {
            guard let view = window.contentView, view.bounds.width > 1 else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("window\(i).png"))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.showAll()
        return true
    }

    // MARK: Actions

    @objc func newNote(_ sender: Any?) {
        let id = store.addNote()
        windows.focus(id)
    }

    @objc func saveNotes(_ sender: Any?) {
        store.saveNow()
    }

    @objc func showAllNotes(_ sender: Any?) {
        windows.showAll()
    }

    @objc func revealNotesFile(_ sender: Any?) {
        store.saveNow()
        NSWorkspace.shared.activateFileViewerSelecting([Store.fileURL])
    }

    @objc func toggleFloatOnTop(_ sender: Any?) {
        guard let id = windows.keyNoteID else { return }
        store.update(id) { $0.alwaysOnTop.toggle() }
    }

    /// Applies a change to the note whose window is frontmost.
    private func updateKeyNote(_ body: (inout Note) -> Void) {
        guard let id = windows.keyNoteID else { NSSound.beep(); return }
        store.update(id, body)
    }

    @objc func setColor(_ sender: NSMenuItem) {
        updateKeyNote { $0.colorIndex = sender.tag }
    }

    @objc func setFontStyle(_ sender: NSMenuItem) {
        let styles = FontStyle.allCases
        guard styles.indices.contains(sender.tag) else { return }
        updateKeyNote { $0.fontStyle = styles[sender.tag] }
    }

    @objc func setOpacity(_ sender: NSMenuItem) {
        updateKeyNote { $0.paperOpacity = Double(sender.tag) / 100 }
    }

    @objc func biggerText(_ sender: Any?) { updateKeyNote { $0.fontSize = min($0.fontSize + 1, 26) } }
    @objc func smallerText(_ sender: Any?) { updateKeyNote { $0.fontSize = max($0.fontSize - 1, 10) } }
    @objc func moreOpaque(_ sender: Any?) { updateKeyNote { $0.paperOpacity = min($0.paperOpacity + 0.05, 1.0) } }
    @objc func lessOpaque(_ sender: Any?) { updateKeyNote { $0.paperOpacity = max($0.paperOpacity - 0.05, 0.2) } }

    @objc func openNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        windows.focus(id)
    }

    @objc func restoreNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let restored = store.restoreFromTrash(id) else { return }
        store.saveNow()
        windows.focus(restored)
    }

    @objc func purgeNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let note = store.trash.first(where: { $0.id == id }) else { return }
        guard confirm(message: "Permanently delete “\(note.menuTitle)”?",
                      detail: "This can't be undone.",
                      button: "Delete Permanently") else { return }
        store.purgeFromTrash(id)
        store.saveNow()
    }

    @objc func emptyTrash(_ sender: Any?) {
        let count = store.trash.count
        guard count > 0 else { return }
        guard confirm(message: "Permanently delete \(count) note\(count == 1 ? "" : "s")?",
                      detail: "Emptying the trash can't be undone.",
                      button: "Empty Trash") else { return }
        store.emptyTrash()
        store.saveNow()
    }

    /// Destructive confirmations. Moving a note to the trash isn't one — that's undoable.
    private func confirm(message: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Rebuilt on open so the checkmarks track whichever note is frontmost.
    private func rebuildFormatMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let note = windows.keyNoteID.flatMap { store.note($0) }

        let colors = NSMenu()
        for palette in StickyPalette.all {
            let item = NSMenuItem(title: palette.name, action: #selector(setColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = palette.id
            item.state = note?.colorIndex == palette.id ? .on : .off
            colors.addItem(item)
        }
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)

        let opacities = NSMenu()
        for value in Note.opacityPresets {
            let percent = Int(value * 100)
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = note.map { abs($0.paperOpacity - value) < 0.01 } == true ? .on : .off
            opacities.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "Transparency", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacities
        menu.addItem(opacityItem)

        let fonts = NSMenu()
        for (index, style) in FontStyle.allCases.enumerated() {
            let item = NSMenuItem(title: style.label, action: #selector(setFontStyle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = note?.fontStyle == style ? .on : .off
            fonts.addItem(item)
        }
        let fontItem = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        fontItem.submenu = fonts
        menu.addItem(fontItem)

        menu.addItem(.separator())
        add(to: menu, "Bigger Text", #selector(biggerText(_:)), "+", [.command])
        add(to: menu, "Smaller Text", #selector(smallerText(_:)), "-", [.command])
        menu.addItem(.separator())
        add(to: menu, "More Opaque", #selector(moreOpaque(_:)), "+", [.command, .option])
        add(to: menu, "More Transparent", #selector(lessOpaque(_:)), "-", [.command, .option])
        menu.addItem(.separator())

        let float = NSMenuItem(title: "Float Above Other Windows",
                               action: #selector(toggleFloatOnTop(_:)), keyEquivalent: "t")
        float.target = self
        float.state = note?.alwaysOnTop == true ? .on : .off
        menu.addItem(float)
    }

    private func add(to menu: NSMenu, _ title: String, _ action: Selector,
                     _ key: String, _ modifiers: NSEvent.ModifierFlags) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        menu.addItem(item)
    }

    // MARK: Menu

    private func buildMenu() {
        // AppKit injects Dictation and Emoji & Symbols into any menu titled "Edit",
        // and does it more than once — leaving visible duplicates. The system-wide
        // shortcuts for both still work without the menu entries.
        UserDefaults.standard.register(defaults: [
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
        ])

        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let name = Store.appName
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Note", action: #selector(newNote(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Close Note", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save Now", action: #selector(saveNotes(_:)), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Reveal notes.json in Finder", action: #selector(revealNotesFile(_:)), keyEquivalent: "")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let formatItem = NSMenuItem()
        formatMenu = NSMenu(title: "Format")
        formatMenu.delegate = self
        formatItem.submenu = formatMenu
        main.addItem(formatItem)

        let notesItem = NSMenuItem()
        notesMenu = NSMenu(title: "Notes")
        notesMenu.delegate = self
        notesItem.submenu = notesMenu
        main.addItem(notesItem)

        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === formatMenu { rebuildFormatMenu(menu) }
        if menu === notesMenu { rebuildNotesMenu(menu) }
    }

    /// Rebuilt on open so both lists reflect what's actually on screen and in the trash.
    private func rebuildNotesMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(title: "Open Note", action: nil, keyEquivalent: "")
        open.submenu = openNoteSubmenu()
        menu.addItem(open)

        let trash = NSMenuItem(title: "Trash", action: nil, keyEquivalent: "")
        trash.submenu = trashSubmenu()
        menu.addItem(trash)

        menu.addItem(.separator())
        add(to: menu, "Show All Notes", #selector(showAllNotes(_:)), "0", [.command])
    }

    private func openNoteSubmenu() -> NSMenu {
        let submenu = NSMenu()
        guard !store.notes.isEmpty else { return submenu.withDisabled("No Notes") }

        for note in store.notes {
            let item = NSMenuItem(title: note.menuTitle, action: #selector(openNote(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = note.id
            item.state = note.isHidden ? .off : .on   // ✓ means already on screen
            submenu.addItem(item)
        }
        return submenu
    }

    private func trashSubmenu() -> NSMenu {
        let submenu = NSMenu()
        guard !store.trash.isEmpty else { return submenu.withDisabled("Trash is Empty") }

        for note in store.trash {
            let item = NSMenuItem(title: note.menuTitle, action: nil, keyEquivalent: "")
            let actions = NSMenu()

            if let deleted = note.deletedAt {
                actions.addItem(NSMenuItem.disabled("Deleted \(Self.dateFormatter.string(from: deleted))"))
                actions.addItem(.separator())
            }
            let restore = NSMenuItem(title: "Put Back", action: #selector(restoreNote(_:)), keyEquivalent: "")
            restore.target = self
            restore.representedObject = note.id
            actions.addItem(restore)

            let purge = NSMenuItem(title: "Delete Permanently…", action: #selector(purgeNote(_:)), keyEquivalent: "")
            purge.target = self
            purge.representedObject = note.id
            actions.addItem(purge)

            item.submenu = actions
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        let empty = NSMenuItem(title: "Empty Trash…", action: #selector(emptyTrash(_:)), keyEquivalent: "")
        empty.target = self
        submenu.addItem(empty)
        return submenu
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

private extension NSMenu {
    func withDisabled(_ title: String) -> NSMenu {
        addItem(NSMenuItem.disabled(title))
        return self
    }
}

private extension NSMenuItem {
    static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

if CommandLine.arguments.contains("--self-test") { SelfTest.run() }

let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
