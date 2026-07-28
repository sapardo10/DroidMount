import AppKit

/// A small always-frontmost window showing transfer progress with a Cancel button.
final class ProgressWindow: NSWindowController {
    private let bar = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    var onCancel: (() -> Void)?

    convenience init(title: String, total: Int) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "DroidMount"
        w.center()
        self.init(window: w)

        titleLabel.stringValue = title
        titleLabel.font = .boldSystemFont(ofSize: 13)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        bar.minValue = 0
        bar.maxValue = Double(max(total, 1))
        bar.isIndeterminate = false
        bar.doubleValue = 0

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded

        let stack = NSStackView(views: [titleLabel, bar, detailLabel, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = stack
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: 388),
            detailLabel.widthAnchor.constraint(equalToConstant: 388),
        ])
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.level = .floating
    }

    /// Update from any thread.
    func update(done: Int, total: Int, label: String) {
        DispatchQueue.main.async {
            self.bar.maxValue = Double(max(total, 1))
            self.bar.doubleValue = Double(done)
            self.detailLabel.stringValue = label.isEmpty
                ? "Finishing…"
                : "(\(done + 1) of \(total))  \(label)"
        }
    }

    func finish() { DispatchQueue.main.async { self.close() } }

    @objc private func cancelTapped() {
        onCancel?()
        close()
    }
}
