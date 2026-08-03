import Foundation

/// Assertions for the outline logic, run with `my-stickies --self-test`.
///
/// XCTest isn't part of the Command Line Tools, so `swift test` can't run on a machine
/// without Xcode. Folding the checks into the binary keeps them runnable everywhere.
enum SelfTest {

    private static var failures: [String] = []
    private static var checks = 0

    static func run() -> Never {
        structure()
        indenting()
        checking()
        editing()
        visibility()
        strayInput()

        if failures.isEmpty {
            print("ok — \(checks) checks passed")
            exit(0)
        }
        print("FAILED — \(failures.count) of \(checks) checks")
        failures.forEach { print("  ✗ \($0)") }
        exit(1)
    }

    // MARK: Harness

    private static func expect(_ condition: Bool, _ what: String, line: Int = #line) {
        checks += 1
        if !condition { failures.append("\(what) (line \(line))") }
    }

    private static func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: Int = #line) {
        checks += 1
        if actual != expected { failures.append("\(what): expected \(expected), got \(actual) (line \(line))") }
    }

    /// Builds a flat outline from (depth, text) pairs.
    private static func outline(_ spec: [(Int, String)]) -> [Item] {
        spec.map { Item(text: $0.1, depth: $0.0) }
    }

    private static func expectShape(_ items: [Item], _ expected: [(Int, String, Bool)],
                                    _ what: String, line: Int = #line) {
        let actual = items.map { ($0.depth, $0.text, $0.checked) }
        checks += 1
        guard actual.count == expected.count else {
            failures.append("\(what): expected \(expected.count) rows, got \(actual.count) (line \(line))")
            return
        }
        for (a, e) in zip(actual, expected) where a != e {
            failures.append("\(what): expected \(e), got \(a) (line \(line))")
            return
        }
    }

    // MARK: Structure

    private static func structure() {
        let items = outline([(0, "a"), (1, "a1"), (2, "a1x"), (1, "a2"), (0, "b")])
        expect(items.descendantRange(of: 0), 1..<4, "subtree of a")
        expect(items.descendantRange(of: 1), 2..<3, "subtree of a1")
        expect(items.descendantRange(of: 4), 5..<5, "leaf has no subtree")
        expect(items.hasChildren(0), "a has children")
        expect(!items.hasChildren(4), "b has no children")

        expect(items.childIndices(of: 0), [1, 3], "direct children only")
        expect(items.childIndices(of: 1), [2], "children of a1")

        expect(items.parentIndex(of: 0) == nil, "top-level row has no parent")
        expect(items.parentIndex(of: 1), 0, "parent of a1")
        expect(items.parentIndex(of: 2), 1, "parent of a1x")
    }

    // MARK: Indent / outdent

    private static func indenting() {
        var items = outline([(0, "a"), (0, "b"), (1, "b1")])
        items.indent(1)
        expectShape(items, [(0, "a", false), (1, "b", false), (2, "b1", false)],
                    "indent carries the subtree along")

        items = outline([(0, "a"), (0, "b")])
        items.indent(1)
        items.indent(1)
        expect(items[1].depth, 1, "indent refuses to skip a level")

        items = outline([(0, "a"), (0, "b")])
        items.indent(0)
        expect(items[0].depth, 0, "first row cannot indent")

        items = outline([(0, "a")])
        for _ in 1...(maxDepth + 3) {
            items.append(Item(depth: items[items.count - 1].depth))
            items.indent(items.count - 1)
        }
        expect(items.map(\.depth).max(), maxDepth, "indent is capped at maxDepth")

        items = outline([(0, "a"), (0, "b")])
        items[0].collapsed = true
        items.indent(1)
        expect(!items[0].collapsed, "indenting into a collapsed row expands it")

        // Outdenting adopts the following sibling, which is standard outliner behaviour.
        items = outline([(0, "a"), (1, "a1"), (1, "a2")])
        items.outdent(1)
        expectShape(items, [(0, "a", false), (0, "a1", false), (1, "a2", false)],
                    "outdent adopts the following sibling")
        expect(items.parentIndex(of: 2), 1, "a2 reparented under a1")

        items = outline([(0, "a")])
        items.outdent(0)
        expect(items[0].depth, 0, "outdent at top level is a no-op")
    }

    // MARK: Checking

    private static func checking() {
        var items = outline([(0, "a"), (1, "a1"), (2, "a1x"), (0, "b")])
        items.setChecked(true, at: 0)
        expectShape(items, [(0, "a", true), (1, "a1", true), (2, "a1x", true), (0, "b", false)],
                    "checking a parent cascades down")

        items = outline([(0, "a"), (1, "a1"), (1, "a2")])
        items.setChecked(true, at: 1)
        expect(!items[0].checked, "parent stays unchecked while a child is open")
        items.setChecked(true, at: 2)
        expect(items[0].checked, "parent checks itself once every child is done")

        items = outline([(0, "a"), (1, "a1"), (2, "a1x")])
        items.setChecked(true, at: 0)
        expect(items.allSatisfy(\.checked), "whole branch checked")
        items.setChecked(false, at: 2)
        expectShape(items, [(0, "a", false), (1, "a1", false), (2, "a1x", false)],
                    "unchecking a leaf clears every ancestor")

        items = outline([(0, "a"), (1, "a1"), (2, "a1x"), (2, "a1y"), (1, "a2")])
        items.setChecked(true, at: 2)
        let (done, total) = items.progress(of: 0)
        expect(total, 3, "progress counts leaves")
        expect(done, 1, "progress counts checked leaves")
        expect(items.progress(of: 4).1, 0, "leaf rows have no progress")
    }

    // MARK: Insert / delete

    private static func editing() {
        var items = outline([(0, "a"), (1, "a1"), (0, "b")])
        let at = items.insertSibling(after: 0)
        expect(at, 2, "new sibling lands after the whole subtree")
        expect(items[2].depth, 0, "new sibling inherits depth")
        expect(items[3].text, "b", "following rows shift down")

        items = outline([(0, "a"), (1, "a1")])
        expect(items[items.insertSibling(after: 1)].depth, 1, "nested sibling keeps its depth")

        items = outline([(0, "a"), (1, "a1"), (2, "a1x"), (0, "b")])
        items.removeSubtree(at: 0)
        expectShape(items, [(0, "b", false)], "deleting a row deletes its children")

        items = outline([(0, "a"), (1, "a1"), (1, "a2")])
        items.setChecked(true, at: 1)
        expect(!items[0].checked, "parent open before delete")
        items.removeSubtree(at: 2)
        expect(items[0].checked, "parent rechecks after its last open child is deleted")
    }

    // MARK: Focus handoff

    /// A keystroke that lands in the old row during a ⏎ handoff has to be extracted
    /// verbatim so it can be replayed into the row that should have received it.
    private static func strayInput() {
        let inserted = OutlineTextField.Coordinator.inserted
        expect(inserted("Antes", "AntesC"), "C", "character appended at the end")
        expect(inserted("", "T"), "T", "first character of an empty row")
        expect(inserted("larity Care", "Clarity Care"), "C", "character inserted at the start")
        expect(inserted("abcd", "abXcd"), "X", "character inserted mid-string")
        expect(inserted("abc", "abc"), "", "no change yields nothing")
        expect(inserted("abc", "ab"), "", "deletions are not stray input")
        expect(inserted("Ant", "Antes"), "es", "multi-character paste")
    }

    // MARK: Visibility

    private static func visibility() {
        var items = outline([(0, "a"), (1, "a1"), (2, "a1x"), (0, "b")])
        items[0].collapsed = true
        expect(items.visibleIndices, [0, 3], "collapsed row hides its whole subtree")

        items = outline([(0, "a"), (0, "b")])
        items[0].collapsed = true
        expect(items.visibleIndices, [0, 1], "collapsing a leaf hides nothing")

        items = outline([(0, "a"), (1, "a1"), (2, "a1x"), (1, "a2")])
        items[1].collapsed = true
        expect(items.visibleIndices, [0, 1, 3], "nested collapse keeps siblings visible")
    }
}
