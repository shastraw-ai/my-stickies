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

        if isFocused, nsView.currentEditor() == nil, let window = nsView.window, window.isVisible {
            DispatchQueue.main.async {
                guard nsView.currentEditor() == nil else { return }
                window.makeFirstResponder(nsView)
                nsView.currentEditor()?.selectedRange = NSRange(location: nsView.stringValue.utf16.count, length: 0)
            }
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
            appliedSignature = "\(value)|\(parent.strikethrough)|\(parent.font.fontName)|\(parent.font.pointSize)|\(parent.color.description)"
            parent.text = value
            field.invalidateIntrinsicContentSize()
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
private final class WrappingTextField: NSTextField {
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
