import AppKit

/// Fast bulk copy that bypasses the FUSE mount entirely, driving `adb pull`/`push`
/// directly. Auto-detects direction from the current Finder selection: paths inside
/// the mounted volume are phone files (→ pull to Mac); everything else is local Mac
/// files (→ push to phone).
final class BulkTransfer {
    enum Direction { case phoneToMac, macToPhone }

    enum SelectionResult {
        case empty
        case mixed                  // selection straddles the mount boundary
        case phone([String])        // device-absolute paths (e.g. /sdcard/DCIM/x.jpg)
        case mac([String])          // local POSIX paths
    }

    let adb: String
    let serial: String
    let mountPoint: String

    private var current: Process?
    private(set) var cancelled = false

    init?(serial: String) {
        guard let adb = MountController.adbPath() else { return nil }
        self.adb = adb
        self.serial = serial
        self.mountPoint = (NSHomeDirectory() as NSString).appendingPathComponent("DroidMount")
    }

    // MARK: - Finder selection

    /// Current Finder selection as POSIX paths (empty if none / Finder not scriptable).
    static func finderSelection() -> [String] {
        let script = """
        set AppleScript's text item delimiters to linefeed
        tell application "Finder"
            set out to {}
            repeat with i in (get selection)
                set end of out to POSIX path of (i as alias)
            end repeat
            return out as text
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Classify the selection relative to the mount boundary.
    func classify(_ paths: [String]) -> SelectionResult {
        guard !paths.isEmpty else { return .empty }
        let prefix = mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/"
        let onPhone = paths.filter { $0 == mountPoint || $0.hasPrefix(prefix) }
        let onMac = paths.filter { !($0 == mountPoint || $0.hasPrefix(prefix)) }
        if !onPhone.isEmpty && !onMac.isEmpty { return .mixed }
        if !onPhone.isEmpty {
            // Map mount path -> device-absolute path by stripping the mountpoint.
            let devicePaths = onPhone.map { mp -> String in
                var rel = String(mp.dropFirst(mountPoint.count))
                if !rel.hasPrefix("/") { rel = "/" + rel }
                return rel
            }
            return .phone(devicePaths)
        }
        return .mac(onMac)
    }

    // MARK: - Transfer

    /// Run a transfer. Progress reports the current item's byte count while ADB runs.
    func run(direction: Direction,
             items: [String],
             destination: String,
             progress: @escaping (Int, Int, String, Int64, Int64?) -> Void,
             completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let total = items.count
            for (idx, item) in items.enumerated() {
                if self.cancelled { completion(nil); return }
                let name = (item as NSString).lastPathComponent
                let itemTotal = direction == .phoneToMac
                    ? self.remoteSize(item)
                    : self.localSize(item)
                progress(idx, total, name, 0, itemTotal)

                let p = Process()
                p.executableURL = URL(fileURLWithPath: self.adb)
                switch direction {
                case .phoneToMac:
                    // adb -s <serial> pull <devicePath> <macDestDir>/
                    p.arguments = ["-s", self.serial, "pull", "-a", item, destination + "/"]
                case .macToPhone:
                    // adb -s <serial> push <localPath> <deviceDestDir>/
                    p.arguments = ["-s", self.serial, "push", item, destination + "/"]
                }
                let err = Pipe()
                p.standardOutput = FileHandle.nullDevice
                p.standardError = err
                let errorLock = NSLock()
                var errorData = Data()
                let errorRead = DispatchGroup()
                errorRead.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = err.fileHandleForReading.readDataToEndOfFile()
                    errorLock.lock()
                    errorData = data
                    errorLock.unlock()
                    errorRead.leave()
                }
                do { try p.run() } catch {
                    err.fileHandleForReading.closeFile()
                    completion("Failed to launch adb: \(error.localizedDescription)"); return
                }
                self.current = p
                let localTarget = (destination as NSString).appendingPathComponent(name)
                let remoteTarget = (destination.hasSuffix("/") ? destination : destination + "/") + name
                while p.isRunning && !self.cancelled {
                    Thread.sleep(forTimeInterval: 0.5)
                    let bytes = direction == .phoneToMac
                        ? self.localSize(localTarget) ?? 0
                        : self.remoteSize(remoteTarget) ?? 0
                    progress(idx, total, name, min(bytes, itemTotal ?? bytes), itemTotal)
                }
                p.waitUntilExit()
                self.current = nil
                errorRead.wait()

                if self.cancelled { completion(nil); return }
                if p.terminationStatus != 0 {
                    errorLock.lock()
                    let msg = String(data: errorData, encoding: .utf8) ?? ""
                    errorLock.unlock()
                    completion("adb failed on \(name): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
                    return
                }
                progress(idx + 1, total, name, itemTotal ?? 0, itemTotal)
            }
            completion(nil)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func remoteSize(_ path: String) -> Int64? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["-s", serial, "shell", "du -sk \(shellQuote(path))"]
        let output = Pipe()
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let line = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline).first,
              let kilobytes = Int64(line.split(whereSeparator: \.isWhitespace).first ?? "") else {
            return nil
        }
        return kilobytes * 1024
    }

    private func localSize(_ path: String) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        }
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return nil
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    func cancel() {
        cancelled = true
        current?.terminate()
    }
}
