import AppKit
import SwiftUI

// MARK: - Fonts

enum FontStyle: String, Codable, CaseIterable, Identifiable {
    case system, rounded, serif, mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .mono: return "Mono"
        }
    }

    var design: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        switch self {
        case .system:
            return base
        case .mono:
            return .monospacedSystemFont(ofSize: size, weight: weight)
        case .rounded:
            guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
            return NSFont(descriptor: d, size: size) ?? base
        case .serif:
            guard let d = base.fontDescriptor.withDesign(.serif) else { return base }
            return NSFont(descriptor: d, size: size) ?? base
        }
    }
}

// MARK: - Colors

struct StickyPalette: Identifiable {
    let id: Int
    let name: String
    let paperHex: String
    let inkHex: String

    var paper: Color { Color(hex: paperHex) }
    var ink: Color { Color(hex: inkHex) }
    var nsInk: NSColor { NSColor(hex: inkHex) }

    static let all: [StickyPalette] = [
        .init(id: 0, name: "Butter",   paperHex: "FFF3B0", inkHex: "3B3218"),
        .init(id: 1, name: "Blossom",  paperHex: "FFD6E3", inkHex: "40222E"),
        .init(id: 2, name: "Mint",     paperHex: "D3F3D0", inkHex: "1F3320"),
        .init(id: 3, name: "Sky",      paperHex: "D0E7FF", inkHex: "1D2C3E"),
        .init(id: 4, name: "Lilac",    paperHex: "E5DCFF", inkHex: "2B2242"),
        .init(id: 5, name: "Sand",     paperHex: "EDE4D3", inkHex: "35301F"),
        .init(id: 6, name: "Graphite", paperHex: "2C2C31", inkHex: "EDEDF0"),
    ]

    static func at(_ index: Int) -> StickyPalette {
        all.indices.contains(index) ? all[index] : all[0]
    }
}

private func rgb(fromHex hex: String) -> (Double, Double, Double) {
    var value: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&value)
    return (Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255)
}

extension Color {
    init(hex: String) {
        let (r, g, b) = rgb(fromHex: hex)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let (r, g, b) = rgb(fromHex: hex)
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - Data model

/// One checklist line. Hierarchy is encoded as a flat list + `depth`, which keeps
/// indent/outdent/move/delete as plain index arithmetic instead of tree surgery.
struct Item: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var text: String = ""
    var checked: Bool = false
    var depth: Int = 0
    var collapsed: Bool = false
}

struct Note: Codable, Identifiable {
    var id: UUID = UUID()
    var title: String = "Untitled"
    var items: [Item] = [Item()]
    var frame: CGRect = CGRect(x: 240, y: 240, width: 300, height: 340)
    var colorIndex: Int = 0
    var fontStyle: FontStyle = .system
    var fontSize: Double = 13
    var paperOpacity: Double = 0.95
    var alwaysOnTop: Bool = true
    var isHidden: Bool = false

    var palette: StickyPalette { StickyPalette.at(colorIndex) }

    /// Title fallback used in menus.
    var menuTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let firstLine = items.first(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })?.text
        return firstLine ?? "Untitled"
    }
}

// MARK: - Outline operations

let maxDepth = 8

extension Array where Element == Item {
    /// Indices of `index`'s descendants: the contiguous run of deeper items after it.
    func descendantRange(of index: Int) -> Range<Int> {
        guard indices.contains(index) else { return index..<index }
        let d = self[index].depth
        var end = index + 1
        while end < count, self[end].depth > d { end += 1 }
        return (index + 1)..<end
    }

    func hasChildren(_ index: Int) -> Bool { !descendantRange(of: index).isEmpty }

    /// Nearest preceding item with a smaller depth.
    func parentIndex(of index: Int) -> Int? {
        guard indices.contains(index), self[index].depth > 0 else { return nil }
        var i = index - 1
        while i >= 0 {
            if self[i].depth < self[index].depth { return i }
            i -= 1
        }
        return nil
    }

    /// Rows to render, skipping anything hidden under a collapsed ancestor.
    var visibleIndices: [Int] {
        var result: [Int] = []
        var hiddenBelowDepth: Int?
        for (i, item) in enumerated() {
            if let threshold = hiddenBelowDepth {
                if item.depth > threshold { continue }
                hiddenBelowDepth = nil
            }
            result.append(i)
            if item.collapsed, hasChildren(i) { hiddenBelowDepth = item.depth }
        }
        return result
    }

    mutating func indent(_ index: Int) {
        guard index > 0, indices.contains(index) else { return }
        // Can only indent under a previous sibling, never skip a level.
        guard self[index].depth <= self[index - 1].depth, self[index].depth < maxDepth else { return }
        let range = descendantRange(of: index)
        self[index].depth += 1
        for i in range { self[i].depth += 1 }
        if self[index - 1].collapsed { self[index - 1].collapsed = false }
        refreshAncestors(from: index)
    }

    mutating func outdent(_ index: Int) {
        guard indices.contains(index), self[index].depth > 0 else { return }
        let oldParent = parentIndex(of: index)
        let range = descendantRange(of: index)
        self[index].depth -= 1
        for i in range { self[i].depth -= 1 }
        if let p = oldParent { refreshAncestors(from: p + 1) }
        refreshAncestors(from: index)
    }

    /// Insert a sibling directly after `index` and its subtree. Returns the new index.
    @discardableResult
    mutating func insertSibling(after index: Int) -> Int {
        guard indices.contains(index) else {
            append(Item())
            return count - 1
        }
        let at = descendantRange(of: index).upperBound
        insert(Item(depth: self[index].depth), at: at)
        return at
    }

    /// Remove an item together with everything nested under it.
    mutating func removeSubtree(at index: Int) {
        guard indices.contains(index) else { return }
        let range = descendantRange(of: index)
        removeSubrange(index..<range.upperBound)
        refreshAncestors(from: index)
    }

    /// Toggle a box; the state cascades down to descendants and parents recompute.
    mutating func setChecked(_ value: Bool, at index: Int) {
        guard indices.contains(index) else { return }
        self[index].checked = value
        for i in descendantRange(of: index) { self[i].checked = value }
        refreshAncestors(from: index)
    }

    /// A parent is checked exactly when all of its children are.
    mutating func refreshAncestors(from index: Int) {
        var cursor = Swift.min(index, count - 1)
        while cursor >= 0 {
            guard let parent = parentIndex(of: cursor) else { break }
            let children = childIndices(of: parent)
            if !children.isEmpty {
                self[parent].checked = children.allSatisfy { self[$0].checked }
            }
            cursor = parent
        }
    }

    func childIndices(of index: Int) -> [Int] {
        let range = descendantRange(of: index)
        guard !range.isEmpty else { return [] }
        let childDepth = self[index].depth + 1
        return range.filter { self[$0].depth == childDepth }
    }

    /// (checked, total) across all descendants — shown as progress on parent rows.
    func progress(of index: Int) -> (Int, Int) {
        let range = descendantRange(of: index)
        guard !range.isEmpty else { return (0, 0) }
        let leaves = range.filter { !hasChildren($0) }
        let scope: [Int] = leaves.isEmpty ? [Int](range) : leaves
        return (scope.filter { self[$0].checked }.count, scope.count)
    }
}
