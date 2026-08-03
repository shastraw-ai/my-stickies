import AppKit
import Combine
import SwiftUI

/// A floating panel that still takes keyboard focus, so text editing works while it
/// hovers above every other app's windows.
final class NotePanel: NSPanel {
    let noteID: UUID

    init(noteID: UUID, frame: CGRect) {
        self.noteID = noteID
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        minSize = NSSize(width: 200, height: 140)
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Keeps one panel alive per visible note and mirrors geometry back into the store.
final class WindowManager: NSObject, NSWindowDelegate {
    private let store: Store
    private var panels: [UUID: NotePanel] = [:]
    private var frameWrites: [UUID: DispatchWorkItem] = [:]
    private var cancellable: AnyCancellable?

    init(store: Store) {
        self.store = store
        super.init()
        cancellable = store.$notes
            .receive(on: RunLoop.main)
            .sink { [weak self] notes in self?.sync(with: notes) }
        sync(with: store.notes)
    }

    // MARK: Sync

    private func sync(with notes: [Note]) {
        let wanted = Set(notes.filter { !$0.isHidden }.map(\.id))

        for (id, panel) in panels where !wanted.contains(id) {
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
            panels.removeValue(forKey: id)
        }

        for note in notes where !note.isHidden {
            if let panel = panels[note.id] {
                let level: NSWindow.Level = note.alwaysOnTop ? .floating : .normal
                if panel.level != level { panel.level = level }
                if panel.title != note.menuTitle { panel.title = note.menuTitle }
            } else {
                panels[note.id] = makePanel(for: note)
            }
        }
    }

    private func makePanel(for note: Note) -> NotePanel {
        let panel = NotePanel(noteID: note.id, frame: note.frame)
        panel.title = note.menuTitle
        panel.level = note.alwaysOnTop ? .floating : .normal
        panel.delegate = self

        let host = NSHostingView(rootView: NoteView(store: store, noteID: note.id))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        panel.orderFrontRegardless()
        return panel
    }

    // MARK: Commands

    func focus(_ id: UUID) {
        store.update(id) { $0.isHidden = false }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.panels[id]?.makeKeyAndOrderFront(nil)
        }
    }

    func showAll() {
        for note in store.notes where note.isHidden {
            store.update(note.id) { $0.isHidden = false }
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for panel in self.panels.values { panel.orderFrontRegardless() }
        }
    }

    var keyNoteID: UUID? { (NSApp.keyWindow as? NotePanel)?.noteID }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel else { return }
        panels.removeValue(forKey: panel.noteID)
        // Closing hides the note; deleting is explicit (trash button).
        store.update(panel.noteID) { $0.isHidden = true }
        store.saveNow()
    }

    func windowDidMove(_ notification: Notification) { recordFrame(notification) }
    func windowDidResize(_ notification: Notification) { recordFrame(notification) }

    /// Live drags fire continuously; coalesce so we don't republish on every pixel.
    private func recordFrame(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel else { return }
        let id = panel.noteID
        let frame = panel.frame
        frameWrites[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.store.update(id) { $0.frame = frame }
            self?.frameWrites.removeValue(forKey: id)
        }
        frameWrites[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
