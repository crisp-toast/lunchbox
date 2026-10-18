import Foundation
import TesselCore

// Trains Tessel's window classifier and says how it does against the hand-written rules.
//
//   swift run -c release TesselTrain Training/windows.jsonl [--write Sources/TesselCore/BehaviorModelWeights.swift]
//   swift run -c release TesselTrain Training/windows.jsonl --features <path>   (each window's views, for experiments)
//
// Evaluation is leave-one-app-out: every app's windows are judged by a model that never saw that
// app, which is what a new user's apps are to the shipped model.

// MARK: Data

struct Record: Decodable {
    var id: Int
    var label: WindowBehavior
    var traits: WindowTraits
}

struct Example {
    var id: Int
    var app: String
    var label: WindowBehavior
    var traits: WindowTraits
    var structure: [Double]
    var title: [Double]
    var meaning: [Double]
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: TesselTrain <windows.jsonl> [--write <BehaviorModelWeights.swift>] [--features <path>]")
    exit(1)
}
let lines = try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n")
let records = try lines.map { try JSONDecoder().decode(Record.self, from: Data($0.utf8)) }
let examples = records.map { r in
    Example(id: r.id, app: r.traits.app, label: r.label, traits: r.traits, structure: BehaviorFeatures.structure(r.traits),
            title: BehaviorFeatures.title(r.traits), meaning: TitleMeaning.shared.vector(r.traits.title))
}
let classes = WindowBehavior.allCases
print("\(examples.count) windows from \(Set(examples.map(\.app)).count) apps:",
      classes.map { c in "\(c.rawValue) \(examples.filter { $0.label == c }.count)" }.joined(separator: ", "))
let asked = examples.filter { WindowBehavior.hardRule($0.traits) == nil }
print("Tessel asks the classifier about \(asked.count) of them (window-like); the rules decide the other \(examples.count - asked.count).")

if let i = args.firstIndex(of: "--features") {
    let rows = examples.map { ["id": $0.id, "structure": $0.structure, "title": $0.title] as [String: Any] }
    try JSONSerialization.data(withJSONObject: rows).write(to: URL(fileURLWithPath: args[i + 1]))
    print("wrote \(rows.count) feature rows to \(args[i + 1])")
    exit(0)
}

// MARK: Training

typealias Matrix = [[Double]]

func mul(_ m: Matrix, _ v: [Double]) -> [Double] { m.map { row in zip(row, v).reduce(0) { $0 + $1.0 * $1.1 } } }

func softmax(_ v: [Double]) -> [Double] {
    let m = v.max() ?? 0
    let e = v.map { exp($0 - m) }
    let s = e.reduce(0, +)
    return e.map { $0 / s }
}

struct Standardizer {
    var mean: [Double], scale: [Double]
    init(_ rows: [[Double]]) {
        let d = rows.first?.count ?? 0, n = Double(max(1, rows.count))
        mean = (0..<d).map { j in rows.reduce(0) { $0 + $1[j] } / n }
        scale = (0..<d).map { j in
            let m = rows.reduce(0) { $0 + $1[j] } / n
            let sd = sqrt(rows.reduce(0) { $0 + ($1[j] - m) * ($1[j] - m) } / n)
            return sd > 1e-6 ? sd : 1
        }
    }
    func apply(_ v: [Double]) -> [Double] { zip(v, zip(mean, scale)).map { ($0 - $1.0) / $1.1 } }
}

/// The top `k` directions of the title meanings (power iteration, uncentered, fixed start):
/// what's kept of Apple's 300 numbers per title.
func principal(_ rows: [[Double]], k: Int) -> Matrix {
    let usable = rows.filter { $0.contains { $0 != 0 } }
    guard let d = usable.first?.count, !usable.isEmpty else { return [] }
    var basis: Matrix = []
    for c in 0..<k {
        var v = (0..<d).map { j in sin(Double(j * 7 + c * 13 + 1)) }
        for _ in 0..<60 {
            var next = [Double](repeating: 0, count: d)
            for r in usable { let dot = zip(r, v).reduce(0) { $0 + $1.0 * $1.1 }; for j in 0..<d { next[j] += dot * r[j] } }
            for b in basis { let dot = zip(next, b).reduce(0) { $0 + $1.0 * $1.1 }; for j in 0..<d { next[j] -= dot * b[j] } }
            let norm = sqrt(next.reduce(0) { $0 + $1 * $1 })
            guard norm > 1e-12 else { break }
            v = next.map { $0 / norm }
        }
        basis.append(v)
    }
    return basis
}

/// Softmax regression with Adam, class weights (rare classes count more, at most 4×) and L2.
func trainHead(_ x: [[Double]], _ labels: [Int], steps: Int = 600, l2: Double = 0.1) -> Matrix {
    let k = classes.count, d = x[0].count + 1
    var w = Array(repeating: [Double](repeating: 0, count: d), count: k)
    var m = w, v = w
    let counts = (0..<k).map { c in Double(labels.filter { $0 == c }.count) }
    let weights = counts.map { $0 > 0 ? min(4, Double(labels.count) / (Double(k) * $0)) : 0 }
    let xs = x.map { $0 + [1] }
    for t in 1...steps {
        var g = Array(repeating: [Double](repeating: 0, count: d), count: k)
        for (i, row) in xs.enumerated() {
            let p = softmax(mul(w, row))
            for c in 0..<k {
                let a = weights[labels[i]] * (p[c] - (c == labels[i] ? 1 : 0)) / Double(xs.count)
                for j in row.indices { g[c][j] += a * row[j] }
            }
        }
        for c in 0..<k { for j in 0..<(d - 1) { g[c][j] += l2 * w[c][j] } }
        for c in 0..<k { for j in 0..<d {
            m[c][j] = 0.9 * m[c][j] + 0.1 * g[c][j]
            v[c][j] = 0.999 * v[c][j] + 0.001 * g[c][j] * g[c][j]
            let mh = m[c][j] / (1 - pow(0.9, Double(t))), vh = v[c][j] / (1 - pow(0.999, Double(t)))
            w[c][j] -= 0.05 * mh / (sqrt(vh) + 1e-8)
        } }
    }
    return w
}

let meaningDim = 6

func fit(_ train: [Example]) -> BehaviorModel {
    let meaning = principal(train.map(\.meaning), k: meaningDim)
    let titleRows = train.map { $0.title + (meaning.isEmpty ? [] : mul(meaning, $0.meaning)) }
    let sStd = Standardizer(train.map(\.structure)), tStd = Standardizer(titleRows)
    let x = zip(train, titleRows).map { sStd.apply($0.0.structure) + tStd.apply($0.1) }
    let head = trainHead(x, train.map { classes.firstIndex(of: $0.label)! })
    return BehaviorModel(structureMean: sStd.mean, structureScale: sStd.scale, titleMean: tStd.mean, titleScale: tStd.scale,
                         meaning: meaning, head: head, classes: classes, threshold: 0.5, trainedOn: train.count,
                         note: "softmax head over structure and title views (L2 0.1), \(train.count) windows")
}

// MARK: Leave one app out

let floatingApps = WindowBehavior.floatingApps

struct Outcome { var example: Example; var rule: WindowBehavior; var model: WindowBehavior; var confidence: Double }

var outcomes: [Outcome] = []
for app in Array(Set(examples.map(\.app))).sorted() {
    let model = fit(examples.filter { $0.app != app })
    for ex in examples where ex.app == app {
        let (behavior, confidence) = model.classify(ex.traits, meaning: ex.meaning)
        outcomes.append(Outcome(example: ex, rule: WindowBehavior.byRules(ex.traits, floatingApps: floatingApps),
                                model: behavior, confidence: confidence))
    }
}

let n = outcomes.count
func pct(_ k: Int, _ d: Int) -> String { String(format: "%3.0f%% (%d/%d)", 100 * Double(k) / Double(max(1, d)), k, d) }
func shipped(_ o: Outcome, threshold: Double) -> WindowBehavior {
    BehaviorDecision.combine(o.example.traits, rule: o.rule, model: o.model, confidence: o.confidence,
                             threshold: threshold, floatingApps: floatingApps)
}
print("\nLeave-one-app-out over \(n) windows (each app judged by a model that never saw it):")
print("  rules         behavior", pct(outcomes.filter { $0.rule == $0.example.label }.count, n),
      " tile-or-not", pct(outcomes.filter { $0.rule.tiles == $0.example.label.tiles }.count, n))
print("  model alone   behavior", pct(outcomes.filter { $0.model == $0.example.label }.count, n),
      " tile-or-not", pct(outcomes.filter { $0.model.tiles == $0.example.label.tiles }.count, n))
let thresholds = [0.5, 0.6, 0.7, 0.8, 0.9]
for th in thresholds {
    print("  shipped ≥ \(th) behavior", pct(outcomes.filter { shipped($0, threshold: th) == $0.example.label }.count, n),
          " tile-or-not", pct(outcomes.filter { shipped($0, threshold: th).tiles == $0.example.label.tiles }.count, n))
}
// What a person sees is one of three things: it tiles, it floats, or it floats centered (panel,
// transient and media windows all float today).
func seen(_ b: WindowBehavior) -> Int { b == .document ? 0 : b == .dialog ? 2 : 1 }
print("\nWhat you'd see (tiles / floats / floats centered):")
print("  rules        ", pct(outcomes.filter { seen($0.rule) == seen($0.example.label) }.count, n))
print("  model alone  ", pct(outcomes.filter { seen($0.model) == seen($0.example.label) }.count, n))
for th in thresholds {
    print("  shipped ≥ \(th)", pct(outcomes.filter { seen(shipped($0, threshold: th)) == seen($0.example.label) }.count, n))
}
for o in outcomes where seen(shipped(o, threshold: 0.5)) != seen(o.example.label) {
    print("    wrong at 0.5: \(o.example.app.split(separator: ".").last!) '\(o.example.traits.title ?? "")' → \(shipped(o, threshold: 0.5).rawValue), should be \(o.example.label.rawValue)")
}
let chosen = thresholds.max { a, b in
    let sa = outcomes.filter { shipped($0, threshold: a) == $0.example.label }.count
    let sb = outcomes.filter { shipped($0, threshold: b) == $0.example.label }.count
    return sa != sb ? sa < sb : a > b // a tie goes to the surer threshold
}!
print("Chosen threshold: \(chosen) (picked on these same windows, so the numbers above flatter it a little)")
print("\nPer class, recall: rules | model | shipped at \(chosen)")
for c in classes {
    let these = outcomes.filter { $0.example.label == c }
    print("  \(c.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))",
          pct(these.filter { $0.rule == c }.count, these.count), "|", pct(these.filter { $0.model == c }.count, these.count), "|",
          pct(these.filter { shipped($0, threshold: chosen) == c }.count, these.count))
}
print("\nWhere the shipped decision differs from the rules:")
for o in outcomes where shipped(o, threshold: chosen) != o.rule {
    let s = shipped(o, threshold: chosen)
    print("  \(s == o.example.label ? "fixed" : "BROKE") \(o.example.app.split(separator: ".").last!) '\(o.example.traits.title ?? "")': rules \(o.rule.rawValue), model \(s.rawValue) (\(String(format: "%.2f", o.confidence))), truth \(o.example.label.rawValue)")
}

// MARK: Speed, and the shipped weights

var model = fit(examples)
model.threshold = chosen
let clock = ContinuousClock()
var sink = 0
let rounds = 200
let elapsed = clock.measure {
    for _ in 0..<rounds {
        for ex in examples {
            let meaning = TitleMeaning.shared.vector(ex.traits.title)
            if BehaviorDecision.decide(ex.traits, model: model, meaning: meaning, floatingApps: floatingApps).behavior == .document { sink += 1 }
        }
    }
}
let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
print(String(format: "\nOne decision (title meaning + model), averaged over %d: %.3f ms", rounds * examples.count,
             seconds * 1000 / Double(rounds * examples.count)))

if let i = args.firstIndex(of: "--write") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(model), as: UTF8.self)
    let source = """
    // Generated by TesselTrain from Training/windows.jsonl (\(examples.count) windows). Don't edit by hand:
    // swift run -c release TesselTrain Training/windows.jsonl --write Sources/TesselCore/BehaviorModelWeights.swift
    import Foundation

    extension BehaviorModel {
        /// The base window classifier Tessel ships with, trained on labeled windows from test
        /// machines, never on anyone's own windows.
        public static let base: BehaviorModel? = try? JSONDecoder().decode(BehaviorModel.self, from: Data(baseJSON.utf8))

        static let baseJSON = #\"\"\"
    \(json)
    \"\"\"#
    }

    """
    try source.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
    print("wrote \(args[i + 1]) (\(json.count / 1024) KB of weights)")
}
