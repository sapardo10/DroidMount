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

    /// Run a transfer. `progress(done, total, label)` is called on a background queue;
    /// `completion(error?)` fires when finished/cancelled. Per-item granularity.
    func run(direction: Direction,
             items: [String],
             destination: String,
             progress: @escaping (Int, Int, String) -> Void,
             completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let total = items.count
            for (idx, item) in items.enumerated() {
                if self.cancelled { completion(nil); return }
                let name = (item as NSString).lastPathComponent
                progress(idx, total, name)

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
                do { try p.run() } catch {
                    completion("Failed to launch adb: \(error.localizedDescription)"); return
                }
                self.current = p
                p.waitUntilExit()
                self.current = nil

                if self.cancelled { completion(nil); return }
                if p.terminationStatus != 0 {
                    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""
                    completion("adb failed on \(name): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
                    return
                }
            }
            progress(total, total, "")
            completion(nil)
        }
    }

    func cancel() {
        cancelled = true
        current?.terminate()
    }
}
