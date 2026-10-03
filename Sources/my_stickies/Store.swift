import AppKit
import Combine

final class Store: ObservableObject {
    @Published var notes: [Note] = [] {
        didSet { notesDirty = true; scheduleSave() }
    }

    /// Deleted notes, newest first. Recoverable until purged.
    @Published var trash: [Note] = [] {
        didSet { trashDirty = true; scheduleSave() }
    }

    /// Bundle display name, so the app and its storage folder never drift apart.
    static let appName: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "my-stickies"

    /// Defaults to ~/Library/Application Support/<appName>/notes.json.
    /// MY_STICKIES_NOTES points the app at a different file (separate note sets, testing).
    static let fileURL: URL = {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["MY_STICKIES_NOTES"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent(appName, isDirectory: true)

        // The app used to be called "Stickies"; adopt that folder instead of starting empty.
        if !fm.fileExists(atPath: base.path) {
            let legacy = support.appendingPathComponent("Stickies", isDirectory: true)
            if fm.fileExists(atPath: legacy.path) {
                try? fm.moveItem(at: legacy, to: base)
            }
        }

        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("notes.json")
    }()

    /// Sits beside notes.json so a whole set stays together when copied or synced.
    static let trashURL: URL =
        fileURL.deletingLastPathComponent().appendingPathComponent("trash_notes.json")

    private var pendingSave: DispatchWorkItem?
    private var loading = false
    private var notesDirty = false
    private var trashDirty = false

    init() {
        load()
    }

    // MARK: Persistence

    private func load() {
        loading = true

        let hadNotesFile = FileManager.default.fileExists(atPath: Store.fileURL.path)
        notes = Store.read(Store.fileURL) ?? []
        trash = Store.read(Store.trashURL) ?? []

        loading = false
        notesDirty = !hadNotesFile
        trashDirty = !FileManager.default.fileExists(atPath: Store.trashURL.path)

        // Only seed a welcome note on a genuinely fresh install. An empty notes.json
        // means the user trashed everything, and that should be respected.
        if !hadNotesFile, notes.isEmpty, trash.isEmpty {
            notes = [Store.welcomeNote()]
        }
        if notesDirty || trashDirty { saveNow() }
    }

    private static func read(_ url: URL) -> [Note]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decode(data)
        } catch {
            // Don't clobber a file we failed to parse — move it aside first.
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            NSLog("my-stickies: could not read \(url.lastPathComponent) (\(error)); "
                  + "backed up to \(backup.lastPathComponent)")
            return nil
        }
    }

    private func scheduleSave() {
        guard !loading else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Re-reads both files from disk, e.g. after a sync overwrites them underneath the app.
    func reloadFromDisk() {
        loading = true
        if let n = Store.read(Store.fileURL) { notes = n }
        if let t = Store.read(Store.trashURL) { trash = t }
        loading = false
        notesDirty = false
        trashDirty = false
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        if notesDirty, Store.write(notes, to: Store.fileURL) { notesDirty = false }
        if trashDirty, Store.write(trash, to: Store.trashURL) { trashDirty = false }
    }

    /// The on-disk format of notes.json / trash_notes.json, shared with DriveSync's merge.
    static func decode(_ data: Data) throws -> [Note] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Note].self, from: data)
    }

    static func encode(_ notes: [Note]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(notes)
    }

    @discardableResult
    private static func write(_ notes: [Note], to url: URL) -> Bool {
        do {
            try encode(notes).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("my-stickies: saving \(url.lastPathComponent) failed — \(error)")
            return false
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

    // MARK: Trash

    /// Deleting is recoverable: the note moves to trash_notes.json until purged.
    func moveToTrash(_ id: UUID) {
        guard let i = index(of: id) else { return }
        var note = notes.remove(at: i)
        note.deletedAt = Date()
        note.isHidden = false      // so restoring puts a window back on screen
        trash.insert(note, at: 0)  // newest first
    }

    /// Returns the restored note's id so the caller can bring its window forward.
    @discardableResult
    func restoreFromTrash(_ id: UUID) -> UUID? {
        guard let i = trash.firstIndex(where: { $0.id == id }) else { return nil }
        var note = trash.remove(at: i)
        note.deletedAt = nil
        note.isHidden = false
        notes.append(note)
        return note.id
    }

    func purgeFromTrash(_ id: UUID) {
        trash.removeAll { $0.id == id }
    }

    func emptyTrash() {
        guard !trash.isEmpty else { return }
        trash.removeAll()
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
