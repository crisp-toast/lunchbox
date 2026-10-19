// The same text jobs as texttasks.py, with what macOS already ships (0 MB added to Lunchbox):
// NLEmbedding's sentence vectors and NLContextualEmbedding's token vectors, averaged.
// Commands are matched to the nearest of three example phrasings per action, written before
// any run and different from the test phrasings.
import Foundation
import NaturalLanguage

struct Data: Decodable {
    let desktop: [[String]]
    let queries: [[Q]]
    let intents: [String: String]
    let commands: [[String]]
    enum Q: Decodable {
        case s(String), i(Int)
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .i(i) } else { self = .s(try c.decode(String.self)) }
        }
        var s: String { if case .s(let v) = self { return v }; return "" }
        var i: Int { if case .i(let v) = self { return v }; return -1 }
    }
}

let examples: [String: [String]] = [
    "open": ["launch safari", "show me the finder", "go to messages"],
    "side_by_side": ["safari and mail next to each other", "split notes with xcode", "two up: chrome and slack"],
    "move_workspace": ["move this window to workspace 4", "send mail to my other workspace", "put finder on workspace three"],
    "go_workspace": ["take me to workspace 4", "switch workspaces to the first one", "show me my other desktop"],
    "focus_mode": ["focus mode", "hide everything except this", "zen mode on this window"],
    "hide": ["hide mail", "minimize slack", "make spotify go away for now"],
    "close": ["close it", "close safari's window", "kill this window"],
    "float": ["make it float", "don't tile this", "unpin this from the layout"],
    "grow": ["make mail wider", "enlarge this window", "bigger please"],
    "shrink": ["make mail narrower", "smaller window please", "reduce this one"],
    "tidy": ["balance the windows", "clean up my layout", "equalize all windows"],
    "new_window": ["new safari window", "open another finder window", "one more terminal window"],
]

func cosine(_ a: [Double], _ b: [Double]) -> Double {
    var d = 0.0, na = 0.0, nb = 0.0
    for i in a.indices { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    return d / max((na * nb).squareRoot(), 1e-9)
}

func wordsMatch(_ q: String, _ t: String) -> Int {
    let words = { (s: String) in s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
    let tw = words(t)
    return words(q).filter { x in tw.contains { $0.hasPrefix(x) } }.count
}

let data = try JSONDecoder().decode(Data.self, from: Foundation.Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let windows = data.desktop.map { "\($0[0]): \($0[1])" }

let sentence = NLEmbedding.sentenceEmbedding(for: .english)!
let contextual = NLContextualEmbedding(language: .english)!
if !contextual.hasAvailableAssets {
    let done = DispatchSemaphore(value: 0)
    contextual.requestAssets { r, e in print("contextual assets:", r.rawValue, e as Any); done.signal() }
    done.wait()
}
try contextual.load()

let encoders: [(String, (String) -> [Double])] = [
    ("sentence", { sentence.vector(for: $0.lowercased()) ?? [] }),
    ("contextual", { text in
        guard let r = try? contextual.embeddingResult(for: text, language: .english) else { return [] }
        var sum: [Double] = [], n = 0.0
        r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in
            if sum.isEmpty { sum = v } else { for i in v.indices { sum[i] += v[i] } }
            n += 1
            return true
        }
        return sum.map { $0 / max(n, 1) }
    }),
]

for (name, encode) in encoders {
    let wv = windows.map(encode)
    var times: [Double] = []
    print("\n\(name): find a window by describing it")
    for kind in ["words", "partial", "meaning"] {
        let rows = data.queries.filter { $0[2].s == kind }
        var model = 0, hybrid = 0
        for r in rows {
            let t0 = Date()
            let qv = encode(r[0].s)
            let sims = wv.map { cosine(qv, $0) }
            times.append(Date().timeIntervalSince(t0) * 1000)
            let pick = sims.indices.max { sims[$0] < sims[$1] }!
            model += pick == r[1].i ? 1 : 0
            // Words first; meaning only breaks ties and fills in when no word matches.
            let w = windows.map { wordsMatch(r[0].s, $0) }
            let top = w.max()!
            let hpick = sims.indices.filter { top == 0 || w[$0] == top }.max { sims[$0] < sims[$1] }!
            hybrid += hpick == r[1].i ? 1 : 0
        }
        print("  \(kind.padding(toLength: 8, withPad: " ", startingAt: 0)) meaning alone \(model)/\(rows.count)   words, then meaning \(hybrid)/\(rows.count)")
    }
    let ex = examples.flatMap { k, v in v.map { (k, encode($0)) } }
    var right = 0
    for c in data.commands {
        let t0 = Date()
        let qv = encode(c[0])
        let best = ex.max { cosine(qv, $0.1) < cosine(qv, $1.1) }!.0
        times.append(Date().timeIntervalSince(t0) * 1000)
        right += best == c[1] ? 1 : 0
    }
    times.sort()
    print("  plain-English commands: action \(right)/\(data.commands.count)")
    print(String(format: "  time per answer: median %.2f ms, max %.2f ms", times[times.count / 2], times.last!))
}
