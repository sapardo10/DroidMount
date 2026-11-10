import Foundation
import AppKit

/// Locates adb and the bundled adbfs daemon, and manages the mount lifecycle.
final class MountController {
    enum State: Equatable {
        case unmounted
        case mounting(serial: String)
        case mounted(serial: String)
        case error(String)
    }

    private(set) var state: State = .unmounted
    private var daemon: Process?

    /// Where the device is mounted. Under the home dir so no root is needed.
    static let mountPoint = (NSHomeDirectory() as NSString).appendingPathComponent("DroidMount")

    var onStateChange: ((State) -> Void)?

    // MARK: - Tool resolution

    /// Resolve the adb binary path, preferring the Android SDK location.
    static func adbPath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Resolve the adbfs daemon: bundled in Resources, or the dev build under bin/.
    static func adbfsPath() -> String? {
        if let res = Bundle.main.resourcePath {
            let bundled = (res as NSString).appendingPathComponent("adbfs")
            if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        }
        // Dev fallback: <repo>/bin/adbfs relative to the executable.
        let exec = Bundle.main.executablePath ?? ""
        let devGuess = (exec as NSString)
            .deletingLastPathComponent + "/../../../../bin/adbfs"
        if FileManager.default.isExecutableFile(atPath: devGuess) { return devGuess }
        return nil
    }

    // MARK: - Mount / unmount

    /// Re-adopt a mount that is already active (e.g. the app was relaunched while
    /// the drive was up). Best-effort serial attribution.
    func adopt(serial: String) {
        guard daemon == nil, isMounted() else { return }
        setState(.mounted(serial: serial))
    }

    func mount(serial: String) {
        guard daemon == nil else { return }
        guard let adb = MountController.adbPath() else {
            setState(.error("adb not found")); return
        }
        guard let adbfs = MountController.adbfsPath() else {
            setState(.error("adbfs daemon not found")); return
        }

        // Clear a stale mount entry (orphaned daemon, previous run) before mounting.
        if isMounted() { unmount() }

        try? FileManager.default.createDirectory(
            atPath: MountController.mountPoint, withIntermediateDirectories: true)

        setState(.mounting(serial: serial))

        let platformTools = (adb as NSString).deletingLastPathComponent
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: adbfs)
        // -o rootdir=/sdcard: mount the phone's user storage as the volume root,
        // not the device root (which has tiny, mostly read-only partitions).
        proc.arguments = ["-f", "-o", "rootdir=/sdcard", MountController.mountPoint]
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_SERIAL"] = serial                       // pin the device
        env["PATH"] = platformTools + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env

        // Log the daemon's stdout/stderr to ~/Library/Logs/DroidMount/daemon.log
        // (fresh per mount attempt — the daemon logs every adb command it runs,
        // so this is the ground truth for mount failures).
        let logDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/DroidMount")
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let logPath = (logDir as NSString).appendingPathComponent("daemon.log")
        try? FileManager.default.removeItem(atPath: logPath)
        FileManager.default.createFile(atPath: logPath, contents: nil)
        if let log = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
            proc.standardOutput = log
            proc.standardError = log
        } else {
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.daemon = nil
                if case .mounted = self?.state { self?.setState(.unmounted) }
                if case .mounting = self?.state { self?.setState(.error("daemon exited")) }
            }
        }

        do {
            try proc.run()
            daemon = proc
        } catch {
            setState(.error("launch failed: \(error.localizedDescription)"))
            return
        }

        // Confirm the mount actually came up.
        confirmMount(serial: serial, attempt: 0)
    }

    private func confirmMount(serial: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if self.isMounted() {
                self.setState(.mounted(serial: serial))
            } else if attempt < 12, self.daemon != nil {
                self.confirmMount(serial: serial, attempt: attempt + 1)
            } else if self.daemon != nil {
                self.unmount()   // kill the stuck daemon so a retry can relaunch it
                self.setState(.error("mount timed out"))
            }
        }
    }

    /// Is our mountpoint currently an active mount?
    func isMounted() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // FUSE-T mounts show as: fuse-t:/DroidMount on /Users/.../DroidMount (nfs,...)
        return out.contains(" \(MountController.mountPoint) ")
    }

    func unmount() {
        // Unmounting causes the foreground daemon to exit on its own.
        let umount = Process()
        umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
        umount.arguments = [MountController.mountPoint]
        try? umount.run()
        umount.waitUntilExit()
        if umount.terminationStatus != 0 {
            let force = Process()
            force.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            force.arguments = ["unmount", "force", MountController.mountPoint]
            try? force.run()
            force.waitUntilExit()
        }
        daemon?.terminate()
        daemon = nil
        setState(.unmounted)
    }

    func revealInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: MountController.mountPoint)
    }

    private func setState(_ s: State) {
        state = s
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(s) }
    }
}
