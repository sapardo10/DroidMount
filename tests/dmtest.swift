// CLI harness that exercises the real BulkTransfer engine (same source files as
// the app) without the menu-bar UI. Usage:
//   dmtest <serial> <phoneToMac|macToPhone> <destDir> <src>...
// Prints cumulative progress as it arrives and exits 0 on success.
import Foundation

let args = CommandLine.arguments
guard args.count >= 5 else {
    FileHandle.standardError.write("usage: dmtest <serial> <phoneToMac|macToPhone> <destDir> <src...>\n".data(using: .utf8)!)
    exit(2)
}
let serial = args[1]
let direction: BulkTransfer.Direction = args[2] == "phoneToMac" ? .phoneToMac : .macToPhone
let dest = args[3]
let items = Array(args[4...])

guard let bt = BulkTransfer(serial: serial) else {
    FileHandle.standardError.write("adb not found\n".data(using: .utf8)!)
    exit(3)
}

var lastBytes: Int64 = 0
let start = Date()
bt.run(direction: direction, items: items, destination: dest,
       progress: { done, total, label, bytes, totalBytes in
           // Only print when something changed, to keep output readable.
           guard bytes != lastBytes || label.hasPrefix("Finishing"), bytes != 0 || done > 0 else { return }
           lastBytes = bytes
           let pct = (totalBytes ?? 0) > 0 ? Int(Double(bytes) / Double(totalBytes!) * 100) : -1
           let ts = Date().timeIntervalSince(start)
           print(String(format: "t=%4.1fs done=%d/%d bytes=%lld/%lld pct=%d%%  %@",
                        ts, done, total, bytes, totalBytes ?? 0, pct, label))
       },
       completion: { err in
           let secs = Date().timeIntervalSince(start)
           if let err = err {
               print("FAILED after \(secs)s: \(err)")
               exit(1)
           }
           print("OK in \(secs)s")
           exit(0)
       })
RunLoop.main.run()