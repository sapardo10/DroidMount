import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = DeviceMonitor()
    private let mounter = MountController()
    private var transfer: BulkTransfer?      // retained during an active transfer
    private var progressWin: ProgressWindow?

    private var lastDevices: [Device] = []
    private var lastMountState: MountController.State = .unmounted
    private var adoptInFlight = false
    /// Consecutive failed mount attempts per serial (boot-race retries).
    private var mountFailures: [String: Int] = [:]
    private static let maxMountRetries = 5

    // MARK: - Preferences

    private let autoMountKey = "autoMount"
    private let blockedKey = "blockedAutoMountSerials"

    /// Auto-mount newly attached devices. Default on — the point of a menu-bar
    /// drive agent is "plug in, it's there".
    private var autoMountEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoMountKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoMountKey) }
    }
    /// Serials the user manually unmounted — skip auto-mounting them (until they
    /// physically reconnect, or the user mounts them again explicitly).
    private var blockedSerials: [String] {
        get { UserDefaults.standard.stringArray(forKey: blockedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: blockedKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar agent, no Dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "iphone.gen3",
                                   accessibilityDescription: "DroidMount")
            button.image?.isTemplate = true
        }

        Notifier.shared.requestAuthorization()
        monitor.onChange = { [weak self] new in self?.handleDeviceChange(new) }
        mounter.onStateChange = { [weak self] s in self?.handleMountStateChange(s) }
        monitor.start()
        rebuildMenu()

        // Re-adopt a mount that was already active (app relaunched with the drive up).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.mounter.isMounted() else { return }
            if let serial = self.monitor.devices.first?.serial {
                self.adoptInFlight = true   // suppress the "mounted" notification
                self.mounter.adopt(serial: serial)
            } else {
                self.mounter.unmount()      // orphaned mount: clear it for a clean state
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if mounter.isMounted() { mounter.unmount() }
    }

    // MARK: - Device / mount reactions

    private func handleDeviceChange(_ new: [Device]) {
        let oldSerials = Set(lastDevices.map(\.serial))
        let newSerials = Set(new.map(\.serial))

        // Devices that left: reset their unmount-block (a physical reconnect is a
        // fresh session), and unmount a drive whose device just vanished.
        for dev in lastDevices where !newSerials.contains(dev.serial) {
            if blockedSerials.contains(dev.serial) {
                blockedSerials = blockedSerials.filter { $0 != dev.serial }
            }
            mountFailures[dev.serial] = nil
            if case .mounted(let s) = mounter.state, s == dev.serial {
                mounter.unmount()   // state handler posts the disconnect notification
            }
        }

        // Newly attached devices: auto-mount, unless the user blocked this one
        // (manual unmount) or the master switch is off, or something's mounted.
        if autoMountEnabled {
            for dev in new where !oldSerials.contains(dev.serial) {
                if blockedSerials.contains(dev.serial) { continue }
                if case .mounted = mounter.state { continue }
                mounter.mount(serial: dev.serial)
            }
        }
        lastDevices = new
    }

    private func handleMountStateChange(_ s: MountController.State) {
        let adopting = adoptInFlight
        adoptInFlight = false
        defer { lastMountState = s }
        switch s {
        case .mounted(let serial):
            mountFailures[serial] = 0
            if !adopting {
                let name = monitor.devices.first { $0.serial == serial }?.model ?? serial
                Notifier.shared.post("mounted", title: "DroidMount",
                                     message: "“\(name)” is mounted at ~/DroidMount (read/write).")
            }
        case .unmounted:
            if case .mounted(let serial) = lastMountState {
                let name = monitor.devices.first { $0.serial == serial }?.model ?? serial
                if monitor.devices.contains(where: { $0.serial == serial }) {
                    Notifier.shared.post("unmounted", title: "DroidMount",
                                         message: "“\(name)” was unmounted.")
                } else {
                    Notifier.shared.post("disconnected", title: "DroidMount",
                                         message: "“\(name)” disconnected — drive unmounted.")
                }
            }
        case .error(let msg):
            if case .mounted(let serial) = lastMountState {
                // Mounted drive dropped underneath us (daemon died) — rare path.
                let name = monitor.devices.first { $0.serial == serial }?.model ?? serial
                Notifier.shared.post("disconnected", title: "DroidMount",
                                     message: "“\(name)” disconnected — drive unmounted.")
            } else if let serial = lastSerialOfAttempt {
                // A mount attempt failed. Retry silently while the device is
                // connected (boot race: adb reports the device before /sdcard is
                // ready); only notify once the retry budget is exhausted.
                let n = (mountFailures[serial] ?? 0) + 1
                mountFailures[serial] = n
                if n < Self.maxMountRetries {
                    scheduleMountRetry(serial)
                } else {
                    let name = monitor.devices.first { $0.serial == serial }?.model ?? serial
                    Notifier.shared.post("mount-error", title: "DroidMount: mount failed",
                                         message: "\(msg) (tried \(n) times). Retry from the menu or reconnect the device.")
                }
            } else {
                // No serial (adb/daemon not found) — nothing to retry.
                Notifier.shared.post("mount-error", title: "DroidMount: mount failed", message: msg)
            }
        case .mounting:
            break
        }
        rebuildMenu()
    }

    /// Serial of the attempt that just ended (nil when the failure is a tooling
    /// error that never started an attempt for a device).
    private var lastSerialOfAttempt: String? {
        if case .mounting(let serial) = lastMountState { return serial }
        return nil
    }

    private func scheduleMountRetry(_ serial: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            guard self.monitor.devices.contains(where: { $0.serial == serial }) else { return }
            if case .error = self.mounter.state { self.mounter.mount(serial: serial) }
        }
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
            let path = NSMenuItem(title: "  ~/DroidMount", action: nil, keyEquivalent: "")
            path.isEnabled = false
            menu.addItem(path)
            menu.addItem(actionItem("Unmount", #selector(unmount)))

        case .mounting(let serial):
            let item = NSMenuItem(title: "Mounting \(serial)…", action: nil, keyEquivalent: "")
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
            menu.addItem(actionItem("Send Finder Selection (fast)…", #selector(sendFinderSelection)))
            let hint = NSMenuItem(title: "  phone files → Mac · Mac files → phone",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())
        let auto = actionItem("Auto-Mount on Connect", #selector(toggleAutoMount))
        auto.state = autoMountEnabled ? .on : .off
        menu.addItem(auto)
        if launchAtLoginAvailable() {
            let login = actionItem("Launch at Login", #selector(toggleLaunchAtLogin))
            login.state = launchAtLoginEnabled() ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())
        let quit = actionItem("Quit DroidMount", #selector(quit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
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
        blockedSerials = blockedSerials.filter { $0 != serial }   // explicit mount wins
        mountFailures[serial] = 0
        mounter.mount(serial: serial)
    }

    @objc private func unmount() {
        // Remember the user said "no" to this device until it reconnects.
        if case .mounted(let serial) = mounter.state, !blockedSerials.contains(serial) {
            blockedSerials = blockedSerials + [serial]
        }
        mounter.unmount()
    }

    @objc private func openFinder() { mounter.revealInFinder() }

    @objc private func toggleAutoMount() {
        autoMountEnabled = !autoMountEnabled
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        guard launchAtLoginAvailable() else { return }
        let turningOn = !launchAtLoginEnabled()
        do {
            if turningOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            rebuildMenu()
        } catch {
            alert("Couldn't update Launch at Login: \(error.localizedDescription)")
        }
    }

    @objc private func quit() {
        if mounter.isMounted() { mounter.unmount() }
        NSApp.terminate(nil)
    }

    // MARK: - Launch at login (macOS 13+)

    private func launchAtLoginAvailable() -> Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    private func launchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

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
            choosePhoneFolder { [weak self] dest in
                guard let self, let dest = dest else { return }
                self.startTransfer(bt, .macToPhone, items: localPaths, dest: dest, verb: "Copying to phone")
            }
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
               progress: { done, total, label, bytes, totalBytes in
                   win.update(done: done, total: total, label: label,
                              bytes: bytes, totalBytes: totalBytes)
               },
               completion: { [weak self] err in
                   DispatchQueue.main.async {
                       self?.transfer = nil
                       self?.progressWin = nil
                       if let err = err {
                           win.finish()
                           Notifier.shared.post("transfer-error", title: "DroidMount: transfer failed",
                                                message: err)
                           self?.alert(err)
                       } else {
                           let noun = dir == .phoneToMac ? "Mac" : "phone"
                           let msg = "Copied \(items.count) item\(plural) to \(noun)."
                           win.done(message: msg)
                           Notifier.shared.post("transfer-done", title: "DroidMount", message: msg)
                           if dir == .phoneToMac {
                               NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dest)
                           }
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

    /// Ask for a phone destination, listing the REAL top-level folders on the device
    /// (fetched over adb) so the combo box matches what's actually there.
    private func choosePhoneFolder(_ completion: @escaping (String?) -> Void) {
        let fallback = [
            "/sdcard/Download", "/sdcard/DCIM/Camera", "/sdcard/Movies",
            "/sdcard/Pictures", "/sdcard/Music",
        ]
        guard let serial = activeSerial(), let adb = MountController.adbPath() else {
            presentPhoneFolderPicker(fallback, completion: completion)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, out) = Self.runADBShell(adb: adb, serial: serial,
                                                 script: "find /sdcard -maxdepth 1 -mindepth 1 -type d 2>/dev/null")
            var dirs = status == 0
                ? out.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/sdcard/") }
                : []
            if dirs.isEmpty { dirs = fallback }
            let missing = fallback.filter { !dirs.contains($0) }
            dirs = missing + dirs.sorted()
            DispatchQueue.main.async {
                self.presentPhoneFolderPicker(dirs, completion: completion)
            }
        }
    }

    private func presentPhoneFolderPicker(_ options: [String],
                                         completion: @escaping (String?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Copy to which folder on the phone?"
        alert.informativeText = "Pick or type a destination on the device."
        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        combo.addItems(withObjectValues: options)
        combo.stringValue = options.contains("/sdcard/Download")
            ? "/sdcard/Download" : (options.first ?? "")
        alert.accessoryView = combo
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            completion(nil)
            return
        }
        let v = combo.stringValue.trimmingCharacters(in: .whitespaces)
        completion(v.isEmpty ? nil : v)
    }

    private static func runADBShell(adb: String, serial: String, script: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["-s", serial, "shell", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = "DroidMount"
        a.informativeText = msg
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - Signal cleanup
//
// An accessory app launched from a terminal dies on SIGTERM via the default
// disposition — AppKit never runs applicationWillTerminate, so the FUSE mount
// and its daemon would be orphaned (the mount entry sticks around). Install a
// handler that best-effort unmounts by replacing the process with
// `umount <mountpoint>`; the daemon's fuse loop then sees ENOTCONN and exits
// on its own. (The menu Quit path goes through terminate: and does the full
// unmount with the diskutil force fallback.)

var gUmountCmd: UnsafeMutablePointer<CChar>? = nil
var gUmountArgv: [UnsafeMutablePointer<CChar>?] = []

func installSignalCleanup(mountPoint: String) {
    gUmountCmd = strdup("/sbin/umount")
    let mp = strdup(mountPoint)
    let name = strdup("umount")
    gUmountArgv = [name, mp, nil]
    guard gUmountCmd != nil, mp != nil, name != nil else { return }
    let handler: @convention(c) (Int32) -> Void = { _ in
        execv(gUmountCmd, &gUmountArgv)   // replaces the process image
        _exit(1)                          // exec failed: just die
    }
    signal(SIGTERM, handler)
    signal(SIGINT, handler)
    signal(SIGHUP, handler)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
installSignalCleanup(mountPoint: MountController.mountPoint)
app.run()
