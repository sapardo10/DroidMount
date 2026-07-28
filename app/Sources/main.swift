import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = DeviceMonitor()
    private let mounter = MountController()
    private var transfer: BulkTransfer?      // retained during an active transfer
    private var progressWin: ProgressWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar agent, no Dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "iphone.gen3",
                                   accessibilityDescription: "DroidMount")
            button.image?.isTemplate = true
        }

        monitor.onChange = { [weak self] _ in self?.rebuildMenu() }
        mounter.onStateChange = { [weak self] _ in self?.rebuildMenu() }
        monitor.start()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if mounter.isMounted() { mounter.unmount() }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(statusHeader())
        menu.addItem(.separator())

        switch mounter.state {
        case .mounted(let serial):
            let name = monitor.devices.first { $0.serial == serial }?.model ?? serial
            menu.addItem(actionItem("Open “\(name)” in Finder", #selector(openFinder)))
            menu.addItem(actionItem("Unmount", #selector(unmount)))

        case .mounting:
            let item = NSMenuItem(title: "Mounting…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

        default: // unmounted / error
            if monitor.devices.isEmpty {
                let item = NSMenuItem(title: "Enable USB Debugging on your phone",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                for device in monitor.devices {
                    let item = actionItem("Mount “\(device.model)”", #selector(mountDevice(_:)))
                    item.representedObject = device.serial
                    menu.addItem(item)
                }
            }
        }

        if !monitor.devices.isEmpty {
            menu.addItem(.separator())
            let fast = actionItem("Send Finder Selection (fast)…", #selector(sendFinderSelection))
            menu.addItem(fast)
            let hint = NSMenuItem(
                title: "  phone files → Mac · Mac files → phone", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Quit DroidMount", #selector(quit)))
        statusItem.menu = menu
    }

    private func statusHeader() -> NSMenuItem {
        let title: String
        switch mounter.state {
        case .mounted(let serial):
            let name = monitor.devices.first { $0.serial == serial }?.model ?? serial
            title = "● Mounted: \(name)"
        case .mounting(let serial):
            title = "○ Mounting \(serial)…"
        case .error(let msg):
            title = "⚠ \(msg)"
        case .unmounted:
            switch monitor.devices.count {
            case 0: title = "No device connected"
            case 1: title = "Ready: \(monitor.devices[0].model)"
            default: title = "\(monitor.devices.count) devices connected"
            }
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func mountDevice(_ sender: NSMenuItem) {
        guard let serial = sender.representedObject as? String else { return }
        mounter.mount(serial: serial)
    }

    @objc private func unmount() { mounter.unmount() }
    @objc private func openFinder() { mounter.revealInFinder() }

    // MARK: - Bulk transfer (fast path, bypasses FUSE)

    @objc private func sendFinderSelection() {
        guard let serial = activeSerial() else { alert("Connect a device first."); return }
        guard let bt = BulkTransfer(serial: serial) else { alert("adb not found."); return }

        switch bt.classify(BulkTransfer.finderSelection()) {
        case .empty:
            alert("Select files in Finder first.\n\n• Phone → Mac: select items inside the mounted phone.\n• Mac → Phone: select files in any Mac folder.")
        case .mixed:
            alert("Your selection mixes phone and Mac files. Select one side or the other.")
        case .phone(let devicePaths):
            guard let dest = chooseMacFolder() else { return }
            startTransfer(bt, .phoneToMac, items: devicePaths, dest: dest, verb: "Copying to Mac")
        case .mac(let localPaths):
            guard let dest = choosePhoneFolder() else { return }
            startTransfer(bt, .macToPhone, items: localPaths, dest: dest, verb: "Copying to phone")
        }
    }

    private func startTransfer(_ bt: BulkTransfer, _ dir: BulkTransfer.Direction,
                               items: [String], dest: String, verb: String) {
        let plural = items.count == 1 ? "" : "s"
        let win = ProgressWindow(title: "\(verb) — \(items.count) item\(plural)", total: items.count)
        win.onCancel = { bt.cancel() }
        transfer = bt
        progressWin = win
        win.show()
        bt.run(direction: dir, items: items, destination: dest,
               progress: { done, total, label in win.update(done: done, total: total, label: label) },
               completion: { [weak self] err in
                   DispatchQueue.main.async {
                       win.finish()
                       self?.transfer = nil
                       self?.progressWin = nil
                       if let err = err {
                           self?.alert(err)
                       } else if dir == .phoneToMac {
                           NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dest)
                       }
                   }
               })
    }

    /// Serial to use: the mounted device if any, else the single/first attached device.
    private func activeSerial() -> String? {
        if case .mounted(let s) = mounter.state { return s }
        return monitor.devices.first?.serial
    }

    private func chooseMacFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose where to save on your Mac"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func choosePhoneFolder() -> String? {
        let alert = NSAlert()
        alert.messageText = "Copy to which folder on the phone?"
        alert.informativeText = "Pick or type a destination on the device."
        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        combo.addItems(withObjectValues: [
            "/sdcard/Download", "/sdcard/DCIM/Camera", "/sdcard/Movies",
            "/sdcard/Pictures", "/sdcard/Music",
        ])
        combo.stringValue = "/sdcard/Download"
        alert.accessoryView = combo
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = combo.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    private func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = "DroidMount"
        a.informativeText = msg
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
    @objc private func quit() {
        if mounter.isMounted() { mounter.unmount() }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
