import AppKit
import SwiftUI

/// A borderless NSTextField wrapper.
///
/// SwiftUI's own TextField can't do what an outliner needs on macOS: ⇥ is stolen by
/// focus traversal, ⏎ can't be distinguished cleanly, and strikethrough doesn't survive
/// into the field editor. Driving NSTextField directly gives us all three.
struct OutlineTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont
    var color: NSColor
    var strikethrough: Bool
    var isFocused: Bool

    var onFocus: () -> Void = {}
    var onEnter: () -> Void = {}
    var onTab: () -> Void = {}
    var onShiftTab: () -> Void = {}
    var onDeleteEmpty: () -> Void = {}
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    /// Text typed into this row after focus had already moved on — belongs elsewhere.
    var onStrayInput: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = WrappingTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.allowsEditingTextAttributes = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.apply(to: field, force: true)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(to: nsView, force: false)

        guard let field = nsView as? WrappingTextField else { return }
        guard isFocused else {
            field.focusWhenPlaced = false
            return
        }
        guard field.currentEditor() == nil else { return }

        // A row created by ⏎ isn't in the window yet on its first update. Focusing
        // asynchronously would let the next keystroke land in the previous row, so
        // hand the request to the view and let it claim focus the moment it's placed.
        if let window = field.window, window.isVisible {
            field.takeFocus(in: window)
        } else {
            field.focusWhenPlaced = true
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 200, 20)
        nsView.preferredMaxLayoutWidth = width
        let fitted = nsView.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, ceil(font.boundingRectForFont.height)))
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OutlineTextField
        private var appliedSignature: String = ""

        init(_ parent: OutlineTextField) { self.parent = parent }

        private var attributes: [NSAttributedString.Key: Any] {
            [
                .font: parent.font,
                .foregroundColor: parent.strikethrough ? parent.color.withAlphaComponent(0.5) : parent.color,
                .strikethroughStyle: parent.strikethrough ? NSUnderlineStyle.single.rawValue : 0,
                .strikethroughColor: parent.color.withAlphaComponent(0.6),
            ]
        }

        /// Push text + styling into the field. While the field editor is active we only
        /// restyle, never reassign the string — that would blow away the insertion point.
        func apply(to field: NSTextField, force: Bool) {
            let signature = "\(parent.text)|\(parent.strikethrough)|\(parent.font.fontName)|\(parent.font.pointSize)|\(parent.color.description)"
            guard force || signature != appliedSignature else { return }
            appliedSignature = signature

            let attrs = attributes
            if let editor = field.currentEditor() as? NSTextView {
                editor.typingAttributes = attrs
                if let storage = editor.textStorage {
                    storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
                }
            } else {
                field.attributedStringValue = NSAttributedString(string: parent.text, attributes: attrs)
            }

            field.placeholderAttributedString = NSAttributedString(
                string: parent.placeholder,
                attributes: [.font: parent.font, .foregroundColor: parent.color.withAlphaComponent(0.35)]
            )
            field.invalidateIntrinsicContentSize()
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onFocus()
            if let field = obj.object as? NSTextField, let editor = field.currentEditor() as? NSTextView {
                editor.typingAttributes = attributes
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let value = field.stringValue

            // Focus already moved to another row, yet this field still holds the field
            // editor. Whatever was typed belongs to the new row — put it back and
            // forward it rather than silently corrupting this one.
            if !parent.isFocused, value != parent.text {
                let stray = Coordinator.inserted(from: parent.text, to: value)
                field.stringValue = parent.text
                appliedSignature = ""
                apply(to: field, force: true)
                if !stray.isEmpty { parent.onStrayInput(stray) }
                return
            }

            appliedSignature = "\(value)|\(parent.strikethrough)|\(parent.font.fontName)|\(parent.font.pointSize)|\(parent.color.description)"
            parent.text = value
            field.invalidateIntrinsicContentSize()
        }

        /// The characters `new` has that `old` didn't, assuming a single insertion.
        static func inserted(from old: String, to new: String) -> String {
            guard new.count > old.count else { return "" }
            let oldChars = Array(old), newChars = Array(new)
            var prefix = 0
            while prefix < oldChars.count, newChars[prefix] == oldChars[prefix] { prefix += 1 }
            return String(newChars[prefix ..< prefix + (newChars.count - oldChars.count)])
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                commit(control)
                parent.onEnter()
                return true
            case #selector(NSResponder.insertTab(_:)):
                commit(control)
                parent.onTab()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                commit(control)
                parent.onShiftTab()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.string.isEmpty else { return false }
                parent.onDeleteEmpty()
                return true
            case #selector(NSResponder.moveUp(_:)):
                commit(control)
                parent.onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                commit(control)
                parent.onMoveDown()
                return true
            default:
                return false
            }
        }

        private func commit(_ control: NSControl) {
            guard let field = control as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

/// NSTextField only reports a wrapped intrinsic height if it knows the width it must fit.
final class WrappingTextField: NSTextField {
    /// Set when SwiftUI wants this row focused before it has joined a window.
    var focusWhenPlaced = false

    func takeFocus(in window: NSWindow) {
        focusWhenPlaced = false
        guard currentEditor() == nil else { return }   // already editing
        window.makeFirstResponder(self)
        currentEditor()?.selectedRange = NSRange(location: stringValue.utf16.count, length: 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusWhenPlaced, let window, window.isVisible else { return }
        takeFocus(in: window)
    }

    override var intrinsicContentSize: NSSize {
        guard preferredMaxLayoutWidth > 0 else { return super.intrinsicContentSize }
        return sizeThatFits(NSSize(width: preferredMaxLayoutWidth, height: .greatestFiniteMagnitude))
    }

    override func layout() {
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5, bounds.width > 0 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        super.layout()
    }
}
