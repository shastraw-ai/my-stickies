import AppKit
import Combine

final class Store: ObservableObject {
    @Published var notes: [Note] = [] {
        didSet { scheduleSave() }
    }

    /// Bundle display name, so the app and its storage folder never drift apart.
    static let appName: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "my-stickies"

    /// Defaults to ~/Library/Application Support/<appName>/notes.json.
    /// STICKIES_NOTES points the app at a different file (separate note sets, testing).
    static let fileURL: URL = {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["STICKIES_NOTES"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent(appName, isDirectory: true)

        // Carry notes over from a previous name of the app rather than starting empty.
        if !fm.fileExists(atPath: base.path) {
            let legacy = support.appendingPathComponent("Stickies", isDirectory: true)
            if fm.fileExists(atPath: legacy.path) {
                try? fm.moveItem(at: legacy, to: base)
            }
        }

        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("notes.json")
    }()

    private var pendingSave: DispatchWorkItem?
    private var loading = false

    init() {
        load()
    }

    // MARK: Persistence

    private func load() {
        loading = true
        defer { loading = false }

        guard let data = try? Data(contentsOf: Store.fileURL) else {
            notes = [Store.welcomeNote()]
            loading = false
            saveNow()
            return
        }
        do {
            notes = try JSONDecoder().decode([Note].self, from: data)
        } catch {
            // Don't clobber a file we failed to parse — move it aside first.
            let backup = Store.fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: Store.fileURL, to: backup)
            NSLog("Stickies: could not read notes.json (\(error)); backed up to \(backup.lastPathComponent)")
            notes = [Store.welcomeNote()]
        }
        if notes.isEmpty { notes = [Store.welcomeNote()] }
    }

    private func scheduleSave() {
        guard !loading else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(notes)
            try data.write(to: Store.fileURL, options: .atomic)
        } catch {
            NSLog("Stickies: save failed — \(error)")
        }
    }

    // MARK: Mutation helpers

    func index(of id: UUID) -> Int? { notes.firstIndex { $0.id == id } }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    /// Mutate in place without replacing the whole element (keeps identity stable).
    func update(_ id: UUID, _ body: (inout Note) -> Void) {
        guard let i = index(of: id) else { return }
        body(&notes[i])
    }

    @discardableResult
    func addNote() -> UUID {
        var note = Note()
        note.title = "Untitled"
        note.colorIndex = (notes.last?.colorIndex).map { ($0 + 1) % StickyPalette.all.count } ?? 0
        note.frame = Store.cascadedFrame(after: notes.last?.frame)
        notes.append(note)
        return note.id
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
    }

    // MARK: Placement

    private static func cascadedFrame(after previous: CGRect?) -> CGRect {
        let size = CGSize(width: 300, height: 340)
        guard let screen = NSScreen.main else {
            return CGRect(origin: CGPoint(x: 240, y: 240), size: size)
        }
        let visible = screen.visibleFrame
        guard let previous else {
            return CGRect(x: visible.maxX - size.width - 40,
                          y: visible.maxY - size.height - 40,
                          width: size.width, height: size.height)
        }
        var origin = CGPoint(x: previous.minX + 28, y: previous.minY - 28)
        if origin.x + size.width > visible.maxX || origin.y < visible.minY {
            origin = CGPoint(x: visible.minX + 40, y: visible.maxY - size.height - 40)
        }
        return CGRect(origin: origin, size: size)
    }

    private static func welcomeNote() -> Note {
        var note = Note()
        note.title = "Welcome"
        note.items = [
            Item(text: "Press ⏎ for a new line", depth: 0),
            Item(text: "Press ⇥ to nest it under the line above", depth: 0),
            Item(text: "…like this", depth: 1),
            Item(text: "⇧⇥ moves it back out", depth: 1),
            Item(text: "Click a box to strike it through", checked: true, depth: 0),
            Item(text: "⌘N makes a new note", depth: 0),
        ]
        note.frame = cascadedFrame(after: nil)
        return note
    }
}
