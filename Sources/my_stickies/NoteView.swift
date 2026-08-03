import AppKit
import SwiftUI

struct NoteView: View {
    @ObservedObject var store: Store
    let noteID: UUID

    @State private var focusedItem: UUID?
    @State private var showingSettings = false

    private var note: Note { store.note(noteID) ?? Note() }
    private var palette: StickyPalette { note.palette }
    private var itemFont: NSFont { note.fontStyle.nsFont(size: note.fontSize) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.ink.opacity(0.12)).frame(height: 1)
            list
        }
        .background(palette.paper.opacity(note.paperOpacity))
        .contextMenu { appearanceMenu }
        .environment(\.colorScheme, note.colorIndex == 6 ? .dark : .light)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            TextField("Title", text: binding(\.title))
                .textFieldStyle(.plain)
                .font(.system(size: note.fontSize + 1, weight: .semibold, design: note.fontStyle.design))
                .foregroundStyle(palette.ink)
                .lineLimit(1)

            Spacer(minLength: 4)

            headerButton("plus", help: "Add item") { appendItem() }
            headerButton("paintpalette", help: "Color, font & transparency") { showingSettings = true }
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) { settings }
            headerButton("trash", help: "Move note to Trash") { moveToTrash() }
        }
        .padding(.leading, 34)   // clears the close button
        .padding(.trailing, 8)
        .frame(height: 30)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.ink.opacity(0.55))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Items

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(note.items.visibleIndices, id: \.self) { index in
                    row(at: index)
                }
                if note.items.isEmpty {
                    Button("Add an item") { appendItem() }
                        .buttonStyle(.plain)
                        .font(.system(size: note.fontSize, design: note.fontStyle.design))
                        .foregroundStyle(palette.ink.opacity(0.4))
                        .padding(.vertical, 6)
                }
                Color.clear
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture { appendItem() }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
    }

    private func row(at index: Int) -> some View {
        let item = note.items[index]
        let hasChildren = note.items.hasChildren(index)
        let (done, total) = note.items.progress(of: index)

        return ItemRow(
            item: item,
            hasChildren: hasChildren,
            progress: total > 0 ? "\(done)/\(total)" : nil,
            palette: palette,
            font: itemFont,
            fontSize: note.fontSize,
            design: note.fontStyle.design,
            text: itemTextBinding(item.id),
            isFocused: focusedItem == item.id,
            onFocus: { if focusedItem != item.id { focusedItem = item.id } },
            onStrayInput: { appendToFocusedItem($0) },
            onToggleCheck: { mutate { $0.setChecked(!item.checked, at: idx(item.id, in: $0) ?? index) } },
            onToggleCollapse: {
                mutate { items in
                    guard let i = idx(item.id, in: items) else { return }
                    items[i].collapsed.toggle()
                }
            },
            onEnter: { newLine(after: item.id) },
            onTab: { mutate { items in idx(item.id, in: items).map { items.indent($0) } } },
            onShiftTab: { mutate { items in idx(item.id, in: items).map { items.outdent($0) } } },
            onDeleteEmpty: { deleteRow(item.id, focusPrevious: true) },
            onDelete: { deleteRow(item.id, focusPrevious: false) },
            onMoveUp: { moveFocus(from: item.id, by: -1) },
            onMoveDown: { moveFocus(from: item.id, by: +1) }
        )
        .id(item.id)
    }

    // MARK: Appearance settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Color").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(StickyPalette.all) { p in
                        Button {
                            store.update(noteID) { $0.colorIndex = p.id }
                        } label: {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(p.paper)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(note.colorIndex == p.id ? Color.accentColor : Color.black.opacity(0.15),
                                                      lineWidth: note.colorIndex == p.id ? 2 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(p.name)
                    }
                }
            }

            Picker("Font", selection: binding(\.fontStyle)) {
                ForEach(FontStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            labeledSlider("Size", value: binding(\.fontSize), range: 10...26, step: 1,
                          readout: "\(Int(note.fontSize))pt")

            labeledSlider("Opacity", value: binding(\.paperOpacity), range: 0.2...1.0, step: 0.05,
                          readout: "\(Int(note.paperOpacity * 100))%")

            Toggle("Float above other windows", isOn: binding(\.alwaysOnTop))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 260)
    }

    /// Right-click menu — the same settings without hunting for the header button.
    @ViewBuilder private var appearanceMenu: some View {
        Menu("Color") {
            ForEach(StickyPalette.all) { p in
                Button { store.update(noteID) { $0.colorIndex = p.id } } label: {
                    if note.colorIndex == p.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
        }
        Menu("Transparency") {
            ForEach(Note.opacityPresets, id: \.self) { value in
                Button { store.update(noteID) { $0.paperOpacity = value } } label: {
                    let label = "\(Int(value * 100))%"
                    if abs(note.paperOpacity - value) < 0.01 {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        }
        Menu("Font") {
            ForEach(FontStyle.allCases) { style in
                Button { store.update(noteID) { $0.fontStyle = style } } label: {
                    if note.fontStyle == style { Label(style.label, systemImage: "checkmark") } else { Text(style.label) }
                }
            }
            Divider()
            Button("Bigger") { store.update(noteID) { $0.fontSize = min($0.fontSize + 1, 26) } }
            Button("Smaller") { store.update(noteID) { $0.fontSize = max($0.fontSize - 1, 10) } }
        }
        Divider()
        Button(note.alwaysOnTop ? "Stop Floating Above Others" : "Float Above Others") {
            store.update(noteID) { $0.alwaysOnTop.toggle() }
        }
        Button("Color, Font & Transparency…") { showingSettings = true }
        Divider()
        Button("Move Note to Trash") { moveToTrash() }
    }

    private func labeledSlider(_ label: String, value: Binding<Double>,
                               range: ClosedRange<Double>, step: Double, readout: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(readout).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    // MARK: Bindings

    private func binding<V>(_ keyPath: WritableKeyPath<Note, V>) -> Binding<V> {
        Binding(
            get: { store.note(noteID)?[keyPath: keyPath] ?? Note()[keyPath: keyPath] },
            set: { newValue in store.update(noteID) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func itemTextBinding(_ itemID: UUID) -> Binding<String> {
        Binding(
            get: { store.note(noteID)?.items.first { $0.id == itemID }?.text ?? "" },
            set: { newValue in
                mutate { items in
                    guard let i = idx(itemID, in: items) else { return }
                    items[i].text = newValue
                }
            }
        )
    }

    // MARK: Mutations

    private func idx(_ itemID: UUID, in items: [Item]) -> Int? {
        items.firstIndex { $0.id == itemID }
    }

    private func mutate(_ body: (inout [Item]) -> Void) {
        store.update(noteID) { body(&$0.items) }
    }

    private func appendItem() {
        var newID: UUID?
        mutate { items in
            let item = Item()
            items.append(item)
            newID = item.id
        }
        focusedItem = newID
    }

    private func newLine(after itemID: UUID) {
        var newID: UUID?
        mutate { items in
            guard let i = idx(itemID, in: items) else { return }
            let at = items.insertSibling(after: i)
            newID = items[at].id
        }
        focusedItem = newID
    }

    private func deleteRow(_ itemID: UUID, focusPrevious: Bool) {
        var nextFocus: UUID?
        mutate { items in
            guard let i = idx(itemID, in: items) else { return }
            if focusPrevious, i > 0 {
                let visible = items.visibleIndices
                if let pos = visible.firstIndex(of: i), pos > 0 {
                    nextFocus = items[visible[pos - 1]].id
                }
            }
            items.removeSubtree(at: i)
        }
        focusedItem = nextFocus
    }

    /// Rescues keystrokes that reached the previous row during a focus handoff.
    private func appendToFocusedItem(_ characters: String) {
        guard let target = focusedItem else { return }
        mutate { items in
            guard let i = idx(target, in: items) else { return }
            items[i].text += characters
        }
    }

    private func moveFocus(from itemID: UUID, by offset: Int) {
        let items = note.items
        let visible = items.visibleIndices
        guard let i = idx(itemID, in: items), let pos = visible.firstIndex(of: i) else { return }
        let target = pos + offset
        guard visible.indices.contains(target) else { return }
        focusedItem = items[visible[target]].id
    }

    /// No confirmation: the note lands in Notes ▸ Trash and can be put back from there.
    private func moveToTrash() {
        store.moveToTrash(noteID)
    }
}

// MARK: - Row

private struct ItemRow: View {
    let item: Item
    let hasChildren: Bool
    let progress: String?
    let palette: StickyPalette
    let font: NSFont
    let fontSize: Double
    let design: Font.Design

    @Binding var text: String
    let isFocused: Bool

    let onFocus: () -> Void
    let onStrayInput: (String) -> Void
    let onToggleCheck: () -> Void
    let onToggleCollapse: () -> Void
    let onEnter: () -> Void
    let onTab: () -> Void
    let onShiftTab: () -> Void
    let onDeleteEmpty: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Color.clear.frame(width: CGFloat(item.depth) * 15, height: 1)

            Group {
                if hasChildren {
                    Button(action: onToggleCollapse) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: fontSize * 0.6, weight: .bold))
                            .rotationEffect(.degrees(item.collapsed ? 0 : 90))
                            .foregroundStyle(palette.ink.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10, height: rowHeight)

            Button(action: onToggleCheck) {
                Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: fontSize * 0.95))
                    .foregroundStyle(item.checked ? palette.ink.opacity(0.5) : palette.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .frame(height: rowHeight)

            OutlineTextField(
                text: $text,
                placeholder: "…",
                font: font,
                color: palette.nsInk,
                strikethrough: item.checked,
                isFocused: isFocused,
                onFocus: onFocus,
                onEnter: onEnter,
                onTab: onTab,
                onShiftTab: onShiftTab,
                onDeleteEmpty: onDeleteEmpty,
                onMoveUp: onMoveUp,
                onMoveDown: onMoveDown,
                onStrayInput: onStrayInput
            )

            if let progress, item.collapsed {
                Text(progress)
                    .font(.system(size: fontSize * 0.75, design: design).monospacedDigit())
                    .foregroundStyle(palette.ink.opacity(0.45))
                    .frame(height: rowHeight)
            }

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: fontSize * 0.7, weight: .bold))
                    .foregroundStyle(palette.ink.opacity(0.4))
            }
            .buttonStyle(.plain)
            .frame(width: 14, height: rowHeight)
            .opacity(hovering ? 1 : 0)
            .help("Delete this item")
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var rowHeight: CGFloat { ceil(font.boundingRectForFont.height) }
}
