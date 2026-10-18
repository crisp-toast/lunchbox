// motion <seconds> <owners,comma,separated> [step ...]
// Records every frame of every window the owners have, every 2 ms, while it runs the steps
// at their times, so a case's clock starts at the exact moment its trigger is posted.
//   step: <ms>:tessel:<command>   posts a Tessel command
//         <ms>:wl:<command>       posts a WindowLab command
//         <ms>:sh:<command line>  runs a shell command (not waited for)
//         <ms>:mark               just notes the time
// Prints one JSON object: {"steps": [[t, step]], "windows": {id: {"owner", "pid", "samples": [[t, x, y, w, h] | [t]]}}}
// t is in ms from the start; a sample of only [t] means the window left the screen.
import CoreGraphics
import Foundation
import QuartzCore

let args = CommandLine.arguments
let seconds = Double(args[1]) ?? 3
let owners = Set(args[2].split(separator: ",").map(String.init))
struct Step { let at: Double; let kind: String; let body: String }
var steps: [Step] = args.dropFirst(3).compactMap { s in
    let parts = s.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    guard let at = Double(parts[0]) else { return nil }
    return Step(at: at, kind: parts.count > 1 ? parts[1] : "mark", body: parts.count > 2 ? parts[2] : "")
}.sorted { $0.at < $1.at }

let start = CACurrentMediaTime()
func now() -> Double { (CACurrentMediaTime() - start) * 1000 }
var stepLog: [[Any]] = []
func post(_ name: String, _ object: String) {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name(name), object: object, userInfo: nil, deliverImmediately: true)
}
func run(_ step: Step) {
    let t = now()
    switch step.kind {
    case "tessel": post("com.tyleryouens.tessel.command", step.body)
    case "wl": post("com.tyleryouens.windowlab", step.body)
    case "sh":
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", step.body]
        try? p.run()
    default: break
    }
    stepLog.append([(t * 10).rounded() / 10, "\(step.kind):\(step.body)"])
}

var samples: [CGWindowID: [[Any]]] = [:]
var info: [CGWindowID: (String, Int)] = [:]
var last: [CGWindowID: CGRect] = [:]
while now() < seconds * 1000 {
    while let s = steps.first, s.at <= now() { steps.removeFirst(); run(s) }
    let t = (now() * 10).rounded() / 10
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var seen = Set<CGWindowID>()
    for w in list where owners.contains(w[kCGWindowOwnerName as String] as? String ?? "") && (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let id = w[kCGWindowNumber as String] as? CGWindowID, let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b), r.width > 60, r.height > 60 else { continue }
        seen.insert(id)
        if info[id] == nil { info[id] = (w[kCGWindowOwnerName as String] as? String ?? "", w[kCGWindowOwnerPID as String] as? Int ?? 0) }
        if last[id] != r {
            last[id] = r
            samples[id, default: []].append([t, Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)])
        }
    }
    for id in Array(last.keys) where !seen.contains(id) {
        last[id] = nil
        samples[id, default: []].append([t])
    }
    usleep(2000)
}
var windows: [String: Any] = [:]
for (id, s) in samples { windows[String(id)] = ["owner": info[id]?.0 ?? "", "pid": info[id]?.1 ?? 0, "samples": s] }
let data = try! JSONSerialization.data(withJSONObject: ["steps": stepLog, "windows": windows], options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
