import Foundation

struct Device: Equatable {
    let serial: String
    let model: String       // human-friendly, e.g. "Pixel 7" or "emulator-5554"
    var isEmulator: Bool { serial.hasPrefix("emulator-") }
}

/// Polls `adb devices -l` on a timer and reports the attached devices.
/// A generation counter discards results from superseded polls, and a watchdog
/// kills adb calls that hang, so a wedged adb can never stall the device list.
final class DeviceMonitor {
    private(set) var devices: [Device] = []
    var onChange: (([Device]) -> Void)?

    private var timer: Timer?
    private let lock = NSLock()
    private var generation = 0

    func start(interval: TimeInterval = 3.0) {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        guard let adb = MountController.adbPath() else {
            update([]); return
        }
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()

        DispatchQueue.global(qos: .background).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adb)
            p.arguments = ["devices", "-l"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var out = ""
            do {
                try p.run()
                // Watchdog: kill a hung adb so the next timer tick can supersede it.
                let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: watchdog)
                p.waitUntilExit()
                watchdog.cancel()
                out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            } catch {
                out = ""
            }
            // Ignore results from superseded polls (slow adb, next tick already ran).
            guard let self, self.isCurrent(gen) else { return }
            let parsed = DeviceMonitor.parse(out)
            DispatchQueue.main.async { self.update(parsed) }
        }
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == gen
    }

    private func update(_ new: [Device]) {
        guard new != devices else { return }
        devices = new
        onChange?(new)
    }

    /// Parse `adb devices -l` output into Device values (state == "device" only).
    static func parse(_ output: String) -> [Device] {
        var result: [Device] = []
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2, cols[1] == "device" else { continue }
            let serial = String(cols[0])
            // Prefer the `model:` field for a friendly name.
            var model = serial
            for col in cols where col.hasPrefix("model:") {
                model = String(col.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
            }
            result.append(Device(serial: serial, model: model))
        }
        return result
    }
}