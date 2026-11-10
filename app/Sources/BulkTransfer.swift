import AppKit

/// Fast bulk copy that bypasses the FUSE mount entirely, driving `adb pull`/`push`
/// directly. Auto-detects direction from the current Finder selection: paths inside
/// the mounted volume are phone files (→ pull to Mac); everything else is local Mac
/// files (→ push to phone).
///
/// Items are grouped into batches (≤ `batchSize`) so one `adb` call copies many files
/// at once instead of spawning a process per file — the per-file spawn + stat storm is
/// what made the old per-item path ~60× slower for many small files.
final class BulkTransfer {
    enum Direction { case phoneToMac, macToPhone }

    enum SelectionResult {
        case empty
        case mixed                  // selection straddles the mount boundary
        case phone([String])        // device-absolute paths (e.g. /sdcard/DCIM/x.jpg)
        case mac([String])          // local POSIX paths
    }

    /// Files copied per `adb` invocation. Big enough to amortize the process
    /// spawn, small enough to keep argv and progress granularity reasonable.
    static let batchSize = 16

    struct Item {
        let path: String            // source path (device-absolute or local POSIX)
        let totalBytes: Int64?      // known size in bytes, or nil if unknown
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
        self.mountPoint = MountController.mountPoint
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

    /// Run a transfer. `progress` receives CUMULATIVE counts: `bytes` is everything
    /// copied so far (including finished batches) against the grand `totalBytes`, so
    /// the bar fills monotonically across the whole job. `done`/`total` count items.
    func run(direction: Direction,
             items: [String],
             destination: String,
             progress: @escaping (Int, Int, String, Int64, Int64?) -> Void,
             completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard !self.cancelled else { completion(nil); return }

            // Pre-compute byte totals (one adb call for phone files, local stat for
            // Mac files) so the progress bar knows the grand total up front.
            let sizes: [Int64?]
            if direction == .phoneToMac {
                sizes = self.remoteSizes(items)
            } else {
                sizes = items.map { self.localSize($0) }
            }
            let items = zip(items, sizes).map { Item(path: $0.0, totalBytes: $0.1) }
            let total = items.count
            let grandTotal = items.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
            progress(0, total, "", 0, grandTotal > 0 ? grandTotal : nil)

            // Multi-source `adb push` requires the destination dir to already exist
            // (single-source push would create it). Make sure it does.
            if direction == .macToPhone,
               let dirErr = self.ensureRemoteDir(destination) {
                completion("Can't copy to \(destination) on the phone: \(dirErr)")
                return
            }
            // `adb pull` also wants an existing destination directory on the Mac.
            if direction == .phoneToMac {
                var isDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: destination, isDirectory: &isDir)
                    || !isDir.boolValue {
                    do {
                        try FileManager.default.createDirectory(
                            atPath: destination, withIntermediateDirectories: true)
                    } catch {
                        completion("Can't create destination \(destination): \(error.localizedDescription)")
                        return
                    }
                }
            }

            var done = 0
            var completedBytes: Int64 = 0

            for batch in Self.chunk(items, size: Self.batchSize) {
                if self.cancelled { completion(nil); return }
                let label = self.batchLabel(for: batch)
                let (ok, error, copied) = self.runBatch(
                    direction, batch, destination: destination) { bytes in
                        progress(done, total, label, completedBytes + bytes,
                                 grandTotal > 0 ? grandTotal : nil)
                    }
                if self.cancelled { completion(nil); return }
                guard ok else {
                    completion(error)
                    return
                }
                done += batch.count
                completedBytes += copied
                progress(done, total, "", completedBytes, grandTotal > 0 ? grandTotal : nil)
            }
            completion(nil)
        }
    }

    private func batchLabel(for batch: [Item]) -> String {
        let first = (batch[0].path as NSString).lastPathComponent
        return batch.count == 1 ? first : "\(batch.count) items (first: \(first))"
    }

    /// Copy one batch with a single `adb` call, polling byte progress while it runs.
    /// Returns (ok, errorMessage, bytesCopied). A cancelled transfer returns (false, nil, _).
    private func runBatch(_ direction: Direction, _ batch: [Item], destination: String,
                          poll: @escaping (Int64) -> Void) -> (Bool, String?, Int64) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: self.adb)
        let names = batch.map { ($0.path as NSString).lastPathComponent }
        let targets = names.map { (destination as NSString).appendingPathComponent($0) }
        switch direction {
        case .phoneToMac:
            // adb -s <serial> pull -a src1 src2 ... dest/
            p.arguments = ["-s", self.serial, "pull", "-a"] + batch.map(\.path) + [destination + "/"]
        case .macToPhone:
            // adb -s <serial> push src1 src2 ... dest
            // NOTE: no trailing slash — with an existing dest dir, a bare dest makes
            // directory sources land under their own names (Finder semantics). A
            // trailing slash would merge a directory's CONTENTS into dest instead.
            p.arguments = ["-s", self.serial, "push"] + batch.map(\.path) + [destination]
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
            return (false, "Failed to launch adb: \(error.localizedDescription)", 0)
        }
        self.current = p

        while p.isRunning {
            Thread.sleep(forTimeInterval: 0.5)
            if self.cancelled {
                p.terminate()
                let deadline = Date().addingTimeInterval(2)
                while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
                break
            }
            let bytes: Int64
            switch direction {
            case .phoneToMac:
                // adb pull writes the local target incrementally — measure it locally.
                bytes = zip(batch, targets).reduce(Int64(0)) { acc, pair in
                    let measured = self.localSize(pair.1) ?? 0
                    return acc + min(measured, pair.0.totalBytes ?? measured)
                }
            case .macToPhone:
                // Measure on the phone — one adb call sizes the whole batch.
                let sizes = self.remoteSizes(targets)
                bytes = zip(batch, sizes).reduce(Int64(0)) { acc, pair in
                    let measured = pair.1 ?? 0
                    return acc + min(measured, pair.0.totalBytes ?? measured)
                }
            }
            poll(bytes)
        }
        p.waitUntilExit()
        self.current = nil
        errorRead.wait()

        if self.cancelled { return (false, nil, 0) }
        if p.terminationStatus != 0 {
            errorLock.lock()
            let msg = String(data: errorData, encoding: .utf8) ?? ""
            errorLock.unlock()
            let first = names.first ?? "?"
            return (false,
                    "adb failed in a \(batch.count)-item batch (first: \(first)): " +
                        msg.trimmingCharacters(in: .whitespacesAndNewlines),
                    0)
        }
        // Trust the pre-computed sizes as the final count (bar clamps at max anyway).
        let finalBytes = batch.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        return (true, nil, finalBytes)
    }

    func cancel() {
        cancelled = true
        current?.terminate()
    }

    // MARK: - Sizing helpers

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Size a list of DEVICE paths, in input order, with as few adb calls as possible
    /// (chunked by 128 so huge selections stay within argv limits). Files use
    /// `stat -c %s`, directories use `du -sk` (KB → bytes). Missing paths read 0.
    func remoteSizes(_ paths: [String]) -> [Int64?] {
        var result: [Int64?] = Array(repeating: nil, count: paths.count)
        for (offset, chunk) in Self.chunk(paths, size: 128).enumerated() {
            // Emit "<index> D <kb>" or "<index> F <bytes>" per path, in order, so the
            // mapping survives paths that don't exist (they still print, with 0).
            var script = "i=0; for f in " + chunk.map(shellQuote).joined(separator: " ")
            script += "; do i=$((i+1)); if [ -d \"$f\" ]; then "
            script += "s=$(du -sk \"$f\" 2>/dev/null | awk '{print $1}'); [ -n \"$s\" ] || s=0; "
            script += "echo \"$i D $s\"; else "
            script += "s=$(stat -c %s \"$f\" 2>/dev/null); [ -n \"$s\" ] || s=0; "
            script += "echo \"$i F $s\"; fi; done"
            let (status, out) = self.runShell(script)
            guard status == 0 else { continue }
            for line in out.split(whereSeparator: \.isNewline) {
                let cols = line.split(whereSeparator: \.isWhitespace)
                // cols: [index, "D"|"F", value, (du's path column)]
                guard cols.count >= 3,
                      let idx = Int(cols[0]), idx >= 1, idx <= chunk.count,
                      let value = Int64(cols[2]) else { continue }
                let kind = cols[1]
                let pos = offset + idx - 1
                result[pos] = (kind == "D") ? value * 1024 : value
            }
        }
        return result
    }

    /// `adb shell mkdir -p` the phone destination if it doesn't exist.
    /// Returns an error message, or nil on success.
    private func ensureRemoteDir(_ dest: String) -> String? {
        let q = shellQuote(dest)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["-s", serial, "shell", "[ -d \(q) ] || mkdir -p \(q) 2>&1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe   // merge: surface mkdir's error text
        do { try p.run() } catch { return "adb launch failed: \(error.localizedDescription)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus != 0 {
            return trimmed.isEmpty ? "adb exit \(p.terminationStatus)" : trimmed
        }
        return nil
    }

    /// Run an `adb shell <script>` and return (exitStatus, stdout).
    private func runShell(_ script: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["-s", serial, "shell", script]
        let output = Pipe()
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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

    static func chunk<T>(_ items: [T], size: Int) -> [[T]] {
        guard !items.isEmpty, size > 0 else { return [] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0 ..< min($0 + size, items.count)])
        }
    }
}