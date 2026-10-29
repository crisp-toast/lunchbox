import Foundation

/// The sort show's sound, made on the Mac rather than played from a file: a warm chord that
/// swells in with the color, air rising behind it, a soft bell as each window lands (panned
/// toward its Workspace), letting go once they're all in; then, when you pick a Workspace, the
/// chord back and opening up as that Workspace does. Timed to the show, a few seconds each, quiet,
/// and only when macOS plays interface sounds (System Settings › Sound › Play user interface
/// sound effects).
enum SortSound {
    static let rate = 44_100.0

    static var allowed: Bool {
        (UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled") as? Int) != 0
    }

    /// The sound as two 16-bit stereo WAVs at one loudness: `sorting` plays with the show, and
    /// `opening` when you pick a Workspace. `plinks`: when each window lands, and its pan (-1 left
    /// to 1 right).
    static func render(_ timeline: Timeline, plinks: [(at: Double, pan: Double)]) -> (sorting: Data, opening: Data) {
        // The chord swelling in with the color and letting go once every window is in, air rising
        // as the color comes up, and the bells.
        var sorting = Mix(seconds: timeline.settled + 2.6)
        let letGo = timeline.settled + 0.2
        sorting.chord { t in smooth(0, 1.1, t) * fadeOut(t, from: letGo, over: 0.75) }
        sorting.air { t in
            (amount: 0.05 * bump(t, at: timeline.cover * 0.8, width: 0.9),
             brightness: smooth(0, timeline.cover, t) * (1 - smooth(timeline.cover, 1.6, t)))
        }
        sorting.bells(plinks)

        // The chord back, opening up with higher notes as the Workspace you picked does, and air
        // rising with it.
        let reveal = max(0.35, timeline.opening * 0.6), release = timeline.afterPick - 0.15
        var opening = Mix(seconds: timeline.afterPick + 1.6)
        opening.chord { t in smooth(0, 0.3, t) * (1 + 0.3 * bump(t, at: reveal, width: 0.7)) * fadeOut(t, from: release, over: 0.75) }
        opening.bloom(at: reveal)
        if !timeline.still {
            opening.air { t in
                let open = bump(t, at: reveal - 0.1, width: 0.8)
                return (amount: 0.035 * open, brightness: open)
            }
        }

        sorting.addRoom()
        opening.addRoom()
        let peak = max(sorting.peak, opening.peak)
        let gain = peak > 0 ? 0.85 / peak : 0
        return (sorting.wav(gain: gain), opening.wav(gain: gain))
    }

    // MARK: Parts

    /// A sound being made: what's heard directly, and what goes through the room too.
    private struct Mix {
        let n: Int
        private var left: [Double], right: [Double]
        private var wetLeft: [Double], wetRight: [Double]

        init(seconds: Double) {
            n = Int(seconds * SortSound.rate)
            left = [Double](repeating: 0, count: n)
            right = left
            wetLeft = left
            wetRight = left
        }

        /// The chord: C major 9, low and wide, each note three slightly detuned voices, as loud
        /// as `level` says at each moment.
        mutating func chord(_ level: (Double) -> Double) {
            let env = (0..<n).map { level(Double($0) / rate) }
            let notes: [(f: Double, gain: Double, pan: Double)] = [
                (65.41, 0.10, 0), (130.81, 0.14, -0.3), (196.00, 0.13, 0.3), (293.66, 0.11, -0.45), (329.63, 0.10, 0.45), (493.88, 0.06, 0),
            ]
            for (k, note) in notes.enumerated() {
                let shimmer = (0..<n).map { 1 + 0.1 * sin(2 * .pi * 0.21 * Double($0) / rate + Double(k)) }
                let (l, r) = panned(note.pan)
                for (j, detune) in [-0.0035, 0, 0.0035].enumerated() {
                    var osc = Oscillator(frequency: note.f * (1 + detune), phase: Double(k * 3 + j) * 1.7)
                    var octave = Oscillator(frequency: note.f * 2 * (1 + detune), phase: Double(k + j))
                    for i in 0..<n {
                        let v = (osc.next() + 0.12 * octave.next()) * note.gain / 3 * env[i] * shimmer[i]
                        left[i] += v * l
                        right[i] += v * r
                        if k >= 3 { wetLeft[i] += v * l * 0.25; wetRight[i] += v * r * 0.25 }
                    }
                }
            }
        }

        /// Higher notes blooming at `reveal`.
        mutating func bloom(at reveal: Double) {
            for (k, f) in [392.00, 587.33, 987.77].enumerated() {
                var osc = Oscillator(frequency: f, phase: Double(k))
                let (l, r) = panned([-0.35, 0.35, 0][k])
                let begin = Int(max(0, reveal - 0.35) * rate)
                for i in begin..<n {
                    let t = Double(i) / rate
                    let env = smooth(reveal - 0.35, reveal + 0.15, t) * exp(-max(0, t - reveal - 0.15) / 1.1)
                    let v = osc.next() * 0.045 * env
                    left[i] += v * l
                    right[i] += v * r
                    wetLeft[i] += v * l * 0.6
                    wetRight[i] += v * r * 0.6
                }
            }
        }

        /// Filtered noise: how loud and how bright (0 to 1) at each moment.
        mutating func air(_ shape: (Double) -> (amount: Double, brightness: Double)) {
            var noise = Noise(seed: 0x4C42)
            var low = (0.0, 0.0), high = (0.0, 0.0)
            let b = 1 - exp(-2 * .pi * 180 / rate)
            for i in 0..<n {
                let (amount, brightness) = shape(Double(i) / rate)
                let a = 1 - exp(-2 * .pi * (700 + 5000 * brightness) / rate)
                let (x, y) = (noise.next(), noise.next())
                low.0 += a * (x - low.0); high.0 += b * (low.0 - high.0)
                low.1 += a * (y - low.1); high.1 += b * (low.1 - high.1)
                left[i] += (low.0 - high.0) * amount
                right[i] += (low.1 - high.1) * amount
            }
        }

        /// A soft bell for each window landing, up and down a pentatonic scale.
        mutating func bells(_ plinks: [(at: Double, pan: Double)]) {
            let scale = [659.25, 783.99, 880.00, 1046.50, 1174.66, 1318.51, 1567.98]
            let partials: [(ratio: Double, gain: Double, decay: Double)] = [(1, 1, 0.55), (2, 0.28, 0.2), (3, 0.1, 0.1), (4.2, 0.05, 0.06)]
            for (index, plink) in plinks.enumerated() {
                let step = index % (2 * scale.count - 2)
                let f = scale[step < scale.count ? step : 2 * scale.count - 2 - step]
                let (l, r) = panned(plink.pan)
                let ring = 1.6
                let begin = Int(plink.at * rate), count = min(n - begin, Int(ring * rate))
                guard begin >= 0, count > 0 else { continue }
                for partial in partials {
                    var osc = Oscillator(frequency: f * partial.ratio, phase: 0)
                    for i in 0..<count {
                        let t = Double(i) / rate
                        // Struck, ringing down, and faded to nothing by the end (a cut-off ring clicks).
                        let v = osc.next() * 0.07 * partial.gain * min(1, t / 0.004) * exp(-t / partial.decay) * min(1, (ring - t) / 0.4)
                        left[begin + i] += v * l
                        right[begin + i] += v * r
                        wetLeft[begin + i] += v * l
                        wetRight[begin + i] += v * r
                    }
                }
            }
        }

        /// A little room around the bells and the high notes.
        mutating func addRoom() {
            var roomLeft = Reverb(spread: 0), roomRight = Reverb(spread: 23)
            for i in 0..<n {
                left[i] += roomLeft.process(wetLeft[i]) * 0.3
                right[i] += roomRight.process(wetRight[i]) * 0.3
            }
        }

        var peak: Double { max(left.map(abs).max() ?? 0, right.map(abs).max() ?? 0) }

        func wav(gain: Double) -> Data {
            let length = Double(n) / rate
            var samples = [Int16]()
            samples.reserveCapacity(n * 2)
            for i in 0..<n {
                let t = Double(i) / rate
                let edge = min(1, t / 0.005) * fadeOut(t, from: length - 0.4, over: 0.12)
                for v in [left[i], right[i]] {
                    samples.append(Int16(max(-1, min(1, tanh(v * gain * 1.1) * edge)) * 32_000))
                }
            }
            return SortSound.wav(samples)
        }
    }

    private struct Oscillator {
        private var y1: Double, y2: Double
        private let c: Double

        /// A sine by recurrence: two multiplies a sample.
        init(frequency: Double, phase: Double) {
            let w = 2 * .pi * frequency / SortSound.rate
            c = 2 * cos(w)
            y1 = sin(phase - w)
            y2 = sin(phase - 2 * w)
        }

        mutating func next() -> Double {
            let y = c * y1 - y2
            y2 = y1
            y1 = y
            return y
        }
    }

    private struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: state) >> 11) / Double(1 << 52)
        }
    }

    /// Four combs and two all-passes (Schroeder): enough room for a few seconds of bells.
    private struct Reverb {
        private var combs: [(buffer: [Double], index: Int, store: Double)]
        private var passes: [(buffer: [Double], index: Int)]

        init(spread: Int) {
            combs = [1557, 1617, 1491, 1422].map { (Array(repeating: 0, count: $0 + spread), 0, 0) }
            passes = [556, 441].map { (Array(repeating: 0, count: $0 + spread), 0) }
        }

        mutating func process(_ x: Double) -> Double {
            var out = 0.0
            for k in combs.indices {
                let y = combs[k].buffer[combs[k].index]
                combs[k].store = y * 0.7 + combs[k].store * 0.3
                combs[k].buffer[combs[k].index] = x + combs[k].store * 0.8
                combs[k].index = (combs[k].index + 1) % combs[k].buffer.count
                out += y
            }
            out /= 4
            for k in passes.indices {
                let b = passes[k].buffer[passes[k].index]
                let y = -out + b
                passes[k].buffer[passes[k].index] = out + b * 0.5
                passes[k].index = (passes[k].index + 1) % passes[k].buffer.count
                out = y
            }
            return out
        }
    }

    private static func panned(_ pan: Double) -> (Double, Double) {
        let angle = (max(-1, min(1, pan)) + 1) * .pi / 4
        return (cos(angle), sin(angle))
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / max(0.0001, b - a)))
        return t * t * (3 - 2 * t)
    }

    /// A soft hill centered `at`, about `width` across.
    private static func bump(_ t: Double, at center: Double, width: Double) -> Double {
        let x = (t - center) / (width / 2)
        return exp(-x * x * 2)
    }

    private static func fadeOut(_ t: Double, from start: Double, over seconds: Double) -> Double {
        t <= start ? 1 : exp(-(t - start) / seconds)
    }

    private static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(2))
        put(UInt32(rate)); put(UInt32(rate) * 4); put(UInt16(4)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
