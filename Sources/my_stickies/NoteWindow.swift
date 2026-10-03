import AppKit
import Combine
import SwiftUI

/// A floating panel that still takes keyboard focus, so text editing works while it
/// hovers above every other app's windows.
final class NotePanel: NSPanel {
    let noteID: UUID
    static let defaultMinSize = NSSize(width: 200, height: 140)

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
        minSize = NotePanel.defaultMinSize
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

    /// Collapsed notes: the frame to restore to, and the stack order (for gap-free relayout).
    private var collapsedFrames: [UUID: CGRect] = [:]
    private var collapsedOrder: [UUID] = []
    private static let chipSize = CGSize(width: 170, height: 26)
    private static let chipGap: CGFloat = 6
    /// Clear of the Dock's auto-reveal/desktop-click hot zone at the screen edge.
    private static let chipBottomMargin: CGFloat = 24

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
            collapsedFrames.removeValue(forKey: id)
            collapsedOrder.removeAll { $0 == id }
        }

        for note in notes where !note.isHidden {
            if let panel = panels[note.id] {
                // A collapsed chip stays floating regardless of the note's own setting —
                // don't let an unrelated store update stomp installChip's level while collapsed.
                if collapsedFrames[note.id] == nil {
                    let level: NSWindow.Level = note.alwaysOnTop ? .floating : .normal
                    if panel.level != level { panel.level = level }
                }
                if panel.title != note.menuTitle { panel.title = note.menuTitle }
            } else {
                panels[note.id] = makePanel(for: note)
            }
        }
    }

    /// A frame saved on a monitor that's since been unplugged would put the note
    /// somewhere invisible — restoring it would look like nothing happened.
    static func onScreenFrame(_ frame: CGRect) -> CGRect {
        let visible = NSScreen.screens.map(\.visibleFrame)
        let showsEnough = visible.contains { screen in
            let overlap = screen.intersection(frame)
            return overlap.width >= 80 && overlap.height >= 40
        }
        if showsEnough { return frame }

        guard let fallback = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return frame }
        let size = CGSize(width: min(frame.width, fallback.width),
                          height: min(frame.height, fallback.height))
        return CGRect(x: fallback.midX - size.width / 2,
                      y: fallback.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func makePanel(for note: Note) -> NotePanel {
        let panel = NotePanel(noteID: note.id, frame: WindowManager.onScreenFrame(note.frame))
        panel.title = note.menuTitle
        panel.level = note.alwaysOnTop ? .floating : .normal
        panel.delegate = self

        installFullContent(on: panel, id: note.id)

        panel.orderFrontRegardless()
        return panel
    }

    /// Content is always installed on a panel already at its target size — never swapped in
    /// on a panel that's about to jump to a very different size. Doing it the other way
    /// (swap content, then resize) left a stale, unclickable ghost of the old window behind
    /// after a big resize (e.g. a full note collapsing down to a 26pt chip).
    private func installFullContent(on panel: NotePanel, id: UUID) {
        let host = NSHostingView(rootView: NoteView(store: store, noteID: id))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.styleMask.insert(.resizable)
        panel.standardWindowButton(.closeButton)?.isHidden = false
        panel.level = store.note(id)?.alwaysOnTop == true ? .floating : .normal
    }

    private func installChip(on panel: NotePanel, id: UUID) {
        let host = NSHostingView(rootView: CollapsedChipView(store: store, noteID: id) { [weak self] in
            self?.expand(id)
        })
        host.autoresizingMask = [.width, .height]
        // Without this, NSHostingView shrink-wraps to the chip text's tiny intrinsic size
        // instead of honoring the frame the window assigns it, leaving most of the chip blank.
        host.sizingOptions = []
        panel.contentView = host
        panel.styleMask.remove(.resizable)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        // Always floating while collapsed, regardless of the note's own setting — a chip
        // that's meant to stay reachable shouldn't be able to fall behind other windows.
        panel.level = .floating
    }

    // MARK: Commands

    func focus(_ id: UUID) {
        store.update(id) { $0.isHidden = false }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if self.collapsedFrames[id] != nil {
                self.expand(id)
            } else {
                self.panels[id]?.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Shrinks every currently-expanded note into a title-only chip stacked in the
    /// screen's bottom-right corner. Never collapses a note twice or bulk-restores —
    /// a second press only picks up whatever's expanded by then.
    func collapseAllVisible() {
        let expandable = store.notes.filter { !$0.isHidden && collapsedFrames[$0.id] == nil }
        guard !expandable.isEmpty else { return }
        for note in expandable {
            guard let panel = panels[note.id] else { continue }
            collapsedFrames[note.id] = panel.frame
            collapsedOrder.append(note.id)
            // Must shrink below the note's usual 200x140 floor before relayoutChips lands below.
            panel.minSize = Self.chipSize
        }
        relayoutChips()
        for id in expandable.map(\.id) {
            guard let panel = panels[id] else { continue }
            installChip(on: panel, id: id)
        }
    }

    /// Restores a single collapsed note to its prior frame and closes the gap it leaves.
    func expand(_ id: UUID) {
        guard let frame = collapsedFrames.removeValue(forKey: id) else { return }
        collapsedOrder.removeAll { $0 == id }
        guard let panel = panels[id] else { return }
        panel.minSize = NotePanel.defaultMinSize
        // animate: false — must be synchronous, so content is never swapped in while a resize
        // is still in flight (an animated resize returns immediately; the swap would race it).
        panel.setFrame(WindowManager.onScreenFrame(frame), display: true, animate: false)
        installFullContent(on: panel, id: id)
        panel.makeKeyAndOrderFront(nil)
        relayoutChips()
    }

    /// Bottom-up stack anchored to the bottom-right corner of the main screen.
    /// animate: false — called right before a content swap in collapseAllVisible, which must
    /// never race an in-flight animated resize (see the comment in expand()).
    private func relayoutChips() {
        guard let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        for (i, id) in collapsedOrder.enumerated() {
            guard let panel = panels[id] else { continue }
            let origin = CGPoint(
                x: screen.maxX - Self.chipSize.width - Self.chipGap,
                y: screen.minY + Self.chipBottomMargin + CGFloat(i) * (Self.chipSize.height + Self.chipGap)
            )
            panel.setFrame(CGRect(origin: origin, size: Self.chipSize), display: true, animate: false)
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
        collapsedFrames.removeValue(forKey: panel.noteID)
        collapsedOrder.removeAll { $0 == panel.noteID }
        // Closing hides the note; deleting is explicit (trash button).
        store.update(panel.noteID) { $0.isHidden = true }
        store.saveNow()
    }

    func windowDidMove(_ notification: Notification) { recordFrame(notification) }
    func windowDidResize(_ notification: Notification) { recordFrame(notification) }

    /// Live drags fire continuously; coalesce so we don't republish on every pixel.
    /// Skipped while collapsed — a chip's tiny frame must never overwrite the note's real one.
    private func recordFrame(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel else { return }
        let id = panel.noteID
        guard collapsedFrames[id] == nil else { return }
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
