import AppKit

/// A small always-frontmost window showing transfer progress with a Cancel button.
/// Progress is cumulative across the whole job (bytes/totalBytes are running totals,
/// so the bar fills monotonically). On success the window flashes a transient
/// "Done" state before closing itself.
final class ProgressWindow: NSWindowController {
    private let bar = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Cancel", target: nil, action: nil)
    var onCancel: (() -> Void)?
    private var doneShown = false

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
        bar.maxValue = 1
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        bar.doubleValue = 0

        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(buttonTapped)

        let stack = NSStackView(views: [titleLabel, bar, detailLabel, button])
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

    /// Update from any thread with cumulative progress: `done` items complete,
    /// `bytes` copied so far out of `totalBytes` overall.
    func update(done: Int, total: Int, label: String, bytes: Int64, totalBytes: Int64?) {
        guard !doneShown else { return }
        DispatchQueue.main.async {
            let hasSize = (totalBytes ?? 0) > 0
            if hasSize {
                self.bar.stopAnimation(nil)
                self.bar.isIndeterminate = false
                self.bar.maxValue = Double(totalBytes!)
                self.bar.doubleValue = Double(min(bytes, totalBytes!))
            } else {
                self.bar.isIndeterminate = true
                self.bar.startAnimation(nil)
            }

            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            if !label.isEmpty {
                let copied = formatter.string(fromByteCount: max(bytes, 0))
                if hasSize {
                    let size = formatter.string(fromByteCount: totalBytes!)
                    let percent = min(100, Int((Double(bytes) / Double(totalBytes!)) * 100))
                    self.detailLabel.stringValue =
                        "(\(done) of \(total))  \(label) — \(copied) of \(size) (\(percent)%)"
                } else {
                    self.detailLabel.stringValue = "(\(done) of \(total))  \(label) — \(copied) transferred"
                }
            } else {
                self.detailLabel.stringValue = done >= total ? "All items copied" : "Finishing…"
            }
        }
    }

    /// Transient success state: fill the bar, show the message, then auto-close.
    func done(message: String) {
        doneShown = true
        DispatchQueue.main.async {
            self.bar.stopAnimation(nil)
            self.bar.isIndeterminate = false
            self.bar.maxValue = 1
            self.bar.doubleValue = 1
            self.detailLabel.textColor = .labelColor
            self.detailLabel.stringValue = message
            self.button.title = "Close"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.doneShown else { return }
                self.close()
            }
        }
    }

    /// Close immediately (used for errors and cancel).
    func finish() { DispatchQueue.main.async { self.close() } }

    @objc private func buttonTapped() {
        if doneShown {
            close()
        } else {
            onCancel?()
            close()
        }
    }
}