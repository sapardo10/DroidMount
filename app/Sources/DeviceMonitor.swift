import Foundation

struct Device: Equatable {
    let serial: String
    let model: String       // human-friendly, e.g. "Pixel 7" or "emulator-5554"
    var isEmulator: Bool { serial.hasPrefix("emulator-") }
}

/// Polls `adb devices -l` on a timer and reports the attached devices.
final class DeviceMonitor {
    private(set) var devices: [Device] = []
    var onChange: (([Device]) -> Void)?

    private var timer: Timer?

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
        DispatchQueue.global(qos: .background).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adb)
            p.arguments = ["devices", "-l"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { DispatchQueue.main.async { self?.update([]) }; return }
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            let parsed = DeviceMonitor.parse(out)
            DispatchQueue.main.async { self?.update(parsed) }
        }
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
