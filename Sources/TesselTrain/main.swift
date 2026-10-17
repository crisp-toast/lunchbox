import Foundation
import TesselCore

// Trains Tessel's window classifier and says how it does against the hand-written rules.
//
//   swift run -c release TesselTrain Training/windows.jsonl [--write Sources/TesselCore/BehaviorModelWeights.swift]
//
// Evaluation is leave-one-app-out: every app's windows are judged by a model that never saw
// that app, which is what a new user's apps are to the base model.

// MARK: Data

struct Record: Decodable {
    var id: Int
    var label: WindowBehavior
    var traits: WindowTraits
    var note: String?
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
    print("usage: TesselTrain <windows.jsonl> [--write <BehaviorModelWeights.swift>]")
    exit(1)
}
let writePath = args.firstIndex(of: "--write").map { args[$0 + 1] }
let lines = try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n")
let records = try lines.map { try JSONDecoder().decode(Record.self, from: Data($0.utf8)) }
let examples = records.map { r in
    Example(id: r.id, app: r.traits.app, label: r.label, traits: r.traits, structure: BehaviorFeatures.structure(r.traits),
            title: BehaviorFeatures.title(r.traits), meaning: TitleMeaning.shared.vector(r.traits.title))
}
let classes = WindowBehavior.allCases
print("\(examples.count) windows from \(Set(examples.map(\.app)).count) apps:",
      classes.map { c in "\(c.rawValue) \(examples.filter { $0.label == c }.count)" }.joined(separator: ", "))

// MARK: Little linear algebra

typealias Matrix = [[Double]]

func zeros(_ r: Int, _ c: Int) -> Matrix { Array(repeating: Array(repeating: 0, count: c), count: r) }
/// A seeded generator, so a training run can be repeated exactly.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
var seed: UInt64 = 1

func random(_ r: Int, _ c: Int, scale: Double, rng: inout SplitMix) -> Matrix {
    (0..<r).map { _ in (0..<c).map { _ in Double.random(in: -scale...scale, using: &rng) } }
}
func mul(_ m: Matrix, _ v: [Double]) -> [Double] { m.map { row in zip(row, v).reduce(0) { $0 + $1.0 * $1.1 } } }
func transposeMul(_ m: Matrix, _ v: [Double]) -> [Double] {
    var out = [Double](repeating: 0, count: m.first?.count ?? 0)
    for (i, row) in m.enumerated() { for j in row.indices { out[j] += row[j] * v[i] } }
    return out
}
func addOuter(_ g: inout Matrix, _ a: [Double], _ b: [Double], _ k: Double) {
    for i in a.indices where a[i] != 0 { for j in b.indices { g[i][j] += k * a[i] * b[j] } }
}

/// Adam on one matrix.
struct Adam {
    var m: Matrix, v: Matrix, t = 0
    let rate: Double
    init(like w: Matrix, rate: Double) { m = zeros(w.count, w.first?.count ?? 0); v = m; self.rate = rate }
    mutating func step(_ w: inout Matrix, _ g: Matrix) {
        t += 1
        let b1 = 0.9, b2 = 0.999
        for i in w.indices { for j in w[i].indices {
            m[i][j] = b1 * m[i][j] + (1 - b1) * g[i][j]
            v[i][j] = b2 * v[i][j] + (1 - b2) * g[i][j] * g[i][j]
            let mh = m[i][j] / (1 - pow(b1, Double(t))), vh = v[i][j] / (1 - pow(b2, Double(t)))
            w[i][j] -= rate * mh / (sqrt(vh) + 1e-8)
        } }
    }
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

/// The top `k` directions of the title meanings (power iteration, uncentered): what's kept of
/// Apple's 300 numbers per title.
func principal(_ rows: [[Double]], k: Int) -> Matrix {
    let usable = rows.filter { $0.contains { $0 != 0 } }
    guard let d = usable.first?.count, !usable.isEmpty else { return [] }
    var basis: Matrix = []
    var rng = SplitMix(state: 7)
    for _ in 0..<k {
        var v = (0..<d).map { _ in Double.random(in: -1...1, using: &rng) }
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

// MARK: The JEPA-style encoder

/// Two linear encoders, one per view, each learning to predict the *embedding* of the other view
/// (against a slowly-moving copy, as in JEPA), with VICReg-style variance and covariance terms
/// so the embedding can't collapse.
struct Encoder {
    var a: Matrix, b: Matrix, p1: Matrix, p2: Matrix
    var aTarget: Matrix, bTarget: Matrix

    init(structureDim: Int, titleDim: Int, z: Int, y: Int) {
        var rng = SplitMix(state: seed)
        a = random(z, structureDim, scale: 0.3, rng: &rng)
        b = random(y, titleDim, scale: 0.3, rng: &rng)
        p1 = random(y, z, scale: 0.3, rng: &rng)
        p2 = random(z, y, scale: 0.3, rng: &rng)
        aTarget = a
        bTarget = b
    }

    func embed(_ s: [Double], _ t: [Double]) -> [Double] {
        let z = mul(a, s), y = mul(b, t)
        return z + y + mul(p1, z)
    }

    static func spreadGradient(_ rows: [[Double]]) -> [[Double]] {
        let n = Double(rows.count), d = rows[0].count
        let mean = (0..<d).map { j in rows.reduce(0) { $0 + $1[j] } / n }
        let centered = rows.map { r in zip(r, mean).map { $0 - $1 } }
        var cov = zeros(d, d)
        for r in centered { addOuter(&cov, r, r, 1 / n) }
        var grads = rows.map { _ in [Double](repeating: 0, count: d) }
        for j in 0..<d {
            let sd = sqrt(cov[j][j] + 1e-4)
            if sd < 1 { for i in rows.indices { grads[i][j] -= centered[i][j] / (n * sd) } }
        }
        for i in rows.indices {
            for j in 0..<d { for k in 0..<d where k != j { grads[i][j] += 0.1 * 4 * cov[j][k] * centered[i][k] / (n * Double(d)) } }
        }
        return grads
    }

    mutating func train(_ s: [[Double]], _ t: [[Double]], steps: Int) {
        var oa = Adam(like: a, rate: 0.01), ob = Adam(like: b, rate: 0.01), o1 = Adam(like: p1, rate: 0.01), o2 = Adam(like: p2, rate: 0.01)
        let n = Double(s.count)
        for _ in 0..<steps {
            let z = s.map { mul(a, $0) }, y = t.map { mul(b, $0) }
            let zt = s.map { mul(aTarget, $0) }, yt = t.map { mul(bTarget, $0) }
            var ga = zeros(a.count, a[0].count), gb = zeros(b.count, b[0].count)
            var g1 = zeros(p1.count, p1[0].count), g2 = zeros(p2.count, p2[0].count)
            var gz = Self.spreadGradient(z), gy = Self.spreadGradient(y)
            for i in s.indices {
                let r1 = zip(mul(p1, z[i]), yt[i]).map { $0 - $1 }   // structure predicts the title's embedding
                let r2 = zip(mul(p2, y[i]), zt[i]).map { $0 - $1 }   // and the title predicts the structure's
                addOuter(&g1, r1, z[i], 2 / n)
                addOuter(&g2, r2, y[i], 2 / n)
                let dz = transposeMul(p1, r1).map { $0 * 2 / n }, dy = transposeMul(p2, r2).map { $0 * 2 / n }
                for j in gz[i].indices { gz[i][j] += dz[j] }
                for j in gy[i].indices { gy[i][j] += dy[j] }
            }
            for i in s.indices { addOuter(&ga, gz[i], s[i], 1); addOuter(&gb, gy[i], t[i], 1) }
            for i in ga.indices { for j in ga[i].indices { ga[i][j] += 1e-3 * a[i][j] } }
            for i in gb.indices { for j in gb[i].indices { gb[i][j] += 1e-3 * b[i][j] } }
            oa.step(&a, ga); ob.step(&b, gb); o1.step(&p1, g1); o2.step(&p2, g2)
            for i in a.indices { for j in a[i].indices { aTarget[i][j] = 0.99 * aTarget[i][j] + 0.01 * a[i][j] } }
            for i in b.indices { for j in b[i].indices { bTarget[i][j] = 0.99 * bTarget[i][j] + 0.01 * b[i][j] } }
        }
    }
}

// MARK: The head

/// Softmax regression with class weights (rare classes count more) and L2.
func trainHead(_ x: [[Double]], _ labels: [Int], classes: Int, steps: Int, l2: Double) -> Matrix {
    let d = x[0].count + 1
    var w = zeros(classes, d)
    var opt = Adam(like: w, rate: 0.05)
    let counts = (0..<classes).map { c in Double(labels.filter { $0 == c }.count) }
    let weights = counts.map { $0 > 0 ? min(4, Double(labels.count) / (Double(classes) * $0)) : 0 }
    let xs = x.map { $0 + [1] }
    for _ in 0..<steps {
        var g = zeros(classes, d)
        for (i, row) in xs.enumerated() {
            let p = softmax(mul(w, row))
            for c in 0..<classes {
                let k = weights[labels[i]] * (p[c] - (c == labels[i] ? 1 : 0)) / Double(xs.count)
                for j in row.indices { g[c][j] += k * row[j] }
            }
        }
        for c in 0..<classes { for j in 0..<(d - 1) { g[c][j] += l2 * w[c][j] } }
        opt.step(&w, g)
    }
    return w
}

func softmax(_ v: [Double]) -> [Double] {
    let m = v.max() ?? 0
    let e = v.map { exp($0 - m) }
    let s = e.reduce(0, +)
    return e.map { $0 / s }
}

// MARK: Fitting a whole model

let zDim = 8, yDim = 6, meaningDim = 6

struct Variant { var name: String; var views: Bool; var jepa: Bool; var l2: Double }

func fit(_ train: [Example], _ v: Variant) -> BehaviorModel {
    let meaning = principal(train.map(\.meaning), k: meaningDim)
    let titleRows = train.map { $0.title + (meaning.isEmpty ? [] : mul(meaning, $0.meaning)) }
    let sStd = Standardizer(train.map(\.structure)), tStd = Standardizer(titleRows)
    let s = train.map { sStd.apply($0.structure) }, t = titleRows.map { tStd.apply($0) }
    var encoder = Encoder(structureDim: s[0].count, titleDim: t[0].count, z: v.jepa ? zDim : 0, y: v.jepa ? yDim : 0)
    if v.jepa { encoder.train(s, t, steps: 400) }
    let e = zip(s, t).map { (v.views ? $0 + $1 : []) + (v.jepa ? encoder.embed($0, $1) : []) }
    let eStd = Standardizer(e)
    let head = trainHead(e.map { eStd.apply($0) }, train.map { classes.firstIndex(of: $0.label)! }, classes: classes.count, steps: 600, l2: v.l2)
    return BehaviorModel(structureMean: sStd.mean, structureScale: sStd.scale, titleMean: tStd.mean, titleScale: tStd.scale,
                         meaning: meaning, structure: encoder.a, title: encoder.b, predictor: encoder.p1,
                         embeddingMean: eStd.mean, embeddingScale: eStd.scale, head: head, classes: classes,
                         headReadsViews: v.views, threshold: 0.8, trainedOn: train.count,
                         note: "\(v.name): \(v.jepa ? "JEPA-style linear encoder (z \(zDim), y \(yDim)), " : "")softmax head (L2 \(v.l2)), \(train.count) windows")
}

// MARK: Leave one app out

let floatingApps: Set<String> = [
    "com.apple.systempreferences", "com.apple.iphonesimulator", "com.1password.1password",
    "com.apple.calculator", "com.apple.QuickTimePlayerX", "com.apple.ScreenSharing",
    "com.apple.screencaptureui", "com.tyleryouens.tessel",
]

struct Outcome { var example: Example; var rule: WindowBehavior; var model: WindowBehavior; var confidence: Double }

func leaveOneAppOut(_ v: Variant) -> [Outcome] {
    var outcomes: [Outcome] = []
    for app in Array(Set(examples.map(\.app))).sorted() {
        let train = examples.filter { $0.app != app }, test = examples.filter { $0.app == app }
        let model = fit(train, v)
        for ex in test {
            let (behavior, confidence) = model.classify(ex.traits, meaning: ex.meaning)
            outcomes.append(Outcome(example: ex, rule: WindowBehavior.byRules(ex.traits, floatingApps: floatingApps),
                                    model: behavior, confidence: confidence))
        }
    }
    return outcomes
}

func pct(_ n: Int, _ d: Int) -> String { String(format: "%3.0f%% (%d/%d)", 100 * Double(n) / Double(max(1, d)), n, d) }
func shipped(_ o: Outcome, threshold: Double) -> WindowBehavior {
    BehaviorDecision.combine(o.example.traits, rule: o.rule, model: o.model, confidence: o.confidence,
                             threshold: threshold, floatingApps: floatingApps)
}

let variants = [
    Variant(name: "plain head on both views", views: true, jepa: false, l2: 0.02),
    Variant(name: "plain head on both views", views: true, jepa: false, l2: 0.1),
    Variant(name: "JEPA embedding only", views: false, jepa: true, l2: 0.02),
    Variant(name: "JEPA embedding only", views: false, jepa: true, l2: 0.1),
    Variant(name: "views + JEPA embedding", views: true, jepa: true, l2: 0.02),
    Variant(name: "views + JEPA embedding", views: true, jepa: true, l2: 0.1),
]
let started = Date()
let seeds: [UInt64] = [1, 2, 3, 4, 5]
func accuracy(_ o: [Outcome], _ f: (Outcome) -> Bool) -> Double { Double(o.filter(f).count) / Double(max(1, o.count)) }
func spread(_ xs: [Double]) -> String {
    let mean = xs.reduce(0, +) / Double(xs.count)
    return String(format: "%3.0f%% (%2.0f–%2.0f)", mean * 100, (xs.min() ?? 0) * 100, (xs.max() ?? 0) * 100)
}
var results: [(Variant, [Outcome], Double)] = []
seed = 1
let first = leaveOneAppOut(variants[0])
let n = first.count
print("\nLeave-one-app-out over \(n) windows (each app judged by a model that never saw it), mean (range) over \(seeds.count) seeds:")
print("  rules                                   behavior", pct(first.filter { $0.rule == $0.example.label }.count, n),
      " tile-or-not", pct(first.filter { $0.rule.tiles == $0.example.label.tiles }.count, n))
for v in variants {
    var runs: [[Outcome]] = []
    for s in seeds {
        seed = s
        runs.append(v.jepa || s == seeds[0] ? leaveOneAppOut(v) : runs[0]) // without the encoder, seeds don't matter
    }
    let behavior = runs.map { o in accuracy(o) { $0.model == $0.example.label } }
    let tiles = runs.map { o in accuracy(o) { $0.model.tiles == $0.example.label.tiles } }
    let ship = runs.map { o in accuracy(o) { shipped($0, threshold: 0.7) == $0.example.label } }
    let label = "\(v.name), L2 \(v.l2)".padding(toLength: 40, withPad: " ", startingAt: 0)
    print("  \(label)behavior", spread(behavior), " tile-or-not", spread(tiles), " shipped@0.7", spread(ship))
    let meanShip = ship.reduce(0, +) / Double(ship.count)
    results.append((v, runs[0], meanShip + behavior.reduce(0, +) / Double(behavior.count) / 100))
}
print(String(format: "  (%.1f s)", Date().timeIntervalSince(started)))
let (best, outcomes, _) = results.max { $0.2 < $1.2 }!
seed = 1
print("\nBest: \(best.name), L2 \(best.l2)")
print("Shipped decision (hard rules, then the model where it's sure, else the rules):")
for th in [0.5, 0.6, 0.7, 0.8, 0.9, 0.95] {
    print("  sure ≥ \(th)  behavior", pct(outcomes.filter { shipped($0, threshold: th) == $0.example.label }.count, n),
          " tile-or-not", pct(outcomes.filter { shipped($0, threshold: th).tiles == $0.example.label.tiles }.count, n))
}
let thresholds = [0.5, 0.6, 0.7, 0.8, 0.9]
let chosen = thresholds.max { a, b in
    let sa = outcomes.filter { shipped($0, threshold: a) == $0.example.label }.count
    let sb = outcomes.filter { shipped($0, threshold: b) == $0.example.label }.count
    return sa != sb ? sa < sb : a > b // a tie goes to the surer threshold
}!
print("Chosen threshold: \(chosen)")
print("\nPer class, recall: rules | model | shipped at \(chosen)")
for c in classes {
    let these = outcomes.filter { $0.example.label == c }
    print("  \(c.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))",
          pct(these.filter { $0.rule == c }.count, these.count), "|", pct(these.filter { $0.model == c }.count, these.count), "|",
          pct(these.filter { shipped($0, threshold: chosen) == c }.count, these.count))
}
print("\nWhere the shipped decision (\(chosen)) differs from the rules:")
for o in outcomes where shipped(o, threshold: chosen) != o.rule {
    let s = shipped(o, threshold: chosen)
    print("  \(s == o.example.label ? "fixed" : "BROKE") \(o.example.app.split(separator: ".").last!) '\(o.example.traits.title ?? "")': rules \(o.rule.rawValue), model \(s.rawValue) (\(String(format: "%.2f", o.confidence))), truth \(o.example.label.rawValue)")
}

// MARK: Speed

var model = fit(examples, best)
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
let each = Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds)
print(String(format: "\nOne decision (title meaning + model), averaged over %d: %.3f ms", rounds * examples.count, each * 1000 / Double(rounds * examples.count)))

if let writePath {
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
    try source.write(toFile: writePath, atomically: true, encoding: .utf8)
    print("wrote \(writePath) (\(json.count / 1024) KB of weights)")
}
