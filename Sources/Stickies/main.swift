import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    private var windows: WindowManager!
    private var notesMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        windows = WindowManager(store: store)
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)

        // Dev aid: STICKIES_SNAPSHOT=/path/to/dir dumps each note window to a PNG.
        if let dir = ProcessInfo.processInfo.environment["STICKIES_SNAPSHOT"] {
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

    @objc func openNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        windows.focus(id)
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let name = Store.appName
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Show All Notes", action: #selector(showAllNotes(_:)), keyEquivalent: "0")
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

        let notesItem = NSMenuItem()
        notesMenu = NSMenu(title: "Notes")
        notesMenu.delegate = self
        notesItem.submenu = notesMenu
        main.addItem(notesItem)

        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === notesMenu else { return }
        menu.removeAllItems()

        let float = NSMenuItem(title: "Float This Note Above Others",
                               action: #selector(toggleFloatOnTop(_:)), keyEquivalent: "t")
        float.target = self
        if let id = windows.keyNoteID, let note = store.note(id) {
            float.state = note.alwaysOnTop ? .on : .off
        } else {
            float.isEnabled = false
        }
        menu.addItem(float)
        menu.addItem(.separator())

        if store.notes.isEmpty {
            let empty = NSMenuItem(title: "No Notes", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for note in store.notes {
            let item = NSMenuItem(title: note.menuTitle, action: #selector(openNote(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = note.id
            item.state = note.isHidden ? .off : .on
            menu.addItem(item)
        }
    }
}

if CommandLine.arguments.contains("--self-test") { SelfTest.run() }

let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
