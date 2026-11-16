import Foundation

// ── Zuege unter Last ─────────────────────────────────────────────
// Erkennt Phasen mit weit offenem Gas (Saugrohrdruck ab 80 kPa):
//   Zug          die Drehzahl steigt um mindestens 600 U/min (Durchbeschleunigen)
//   Dauervollgas die Drehzahl bleibt mindestens 8 s etwa gleich (Autobahn, Berg)
// Fuer jeden Zug: Lambda ueber der Drehzahl, wo es mager wird, wie schnell
// der Motor hochdreht und, mit GPS, eine Schaetzung der Leistung am Rad.
// Bei Dauervollgas: ob Lambda mit der Zeit weglaeuft (Benzinversorgung).

struct PullSample: Codable, Hashable {
    var t: Float                 // Sekunden seit Beginn
    var rpm: Float
    var lambda: Float?
    var map: Float?
    var adv: Float?
    var speed: Float?            // km/h
}

struct Pull: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case pull, steady }

    var id = UUID()
    var time: Date
    var kind: Kind
    var samples: [PullSample]
}

/// Fahrzeugdaten fuer die Leistungsschaetzung
struct Vehicle: Equatable {
    var mass = 700.0             // kg mit Fahrer und Tank
    var cdA = 0.85               // m², 2CV: cw 0,51 × 1,65 m²
    var crr = 0.014              // Rollwiderstand
    var rotating = 1.06          // Zuschlag fuer drehende Massen

    static let massKey = "vehicle.mass"

    static func load(from d: UserDefaults = .standard) -> Vehicle {
        var v = Vehicle()
        if let m = d.object(forKey: massKey) as? Double, m >= 400, m <= 1500 { v.mass = m }
        return v
    }
}

struct PowerPoint: Identifiable, Equatable {
    var rpm: Double
    var kW: Double
    var id: Double { rpm }
}

struct PullDetector {
    static let enterKPa = 80.0
    static let exitKPa = 74.0
    static let minRPM = 1500.0
    static let minDuration = 3.0
    static let minRise = 600.0
    static let steadyDuration = 8.0
    static let steadySpan = 400.0
    static let steadyKPa = 86.0
    static let maxDuration = 60.0
    static let dropRPM = 400.0           // so viel unter dem Hoechstwert = Schalten

    private var start: Date?
    private var last: Date?
    private var samples: [PullSample] = []
    private var peak = 0.0

    /// Alle 0,25 s. Gibt einen fertigen Zug zurueck, sobald die Lastphase endet.
    mutating func add(_ s: Sample) -> Pull? {
        guard let rpm = s.rpm, let map = s.mapKPa else { return end() }
        if let st = start, let la = last {
            let gap = s.time.timeIntervalSince(la)
            if map < Self.exitKPa || rpm < peak - Self.dropRPM || gap > 1 || gap < 0 {
                let done = end()
                if map >= Self.enterKPa && rpm >= Self.minRPM { begin(s, rpm: rpm, map: map) }
                return done
            }
            append(s, rpm: rpm, map: map, since: st)
            if s.time.timeIntervalSince(st) >= Self.maxDuration { return end() }
            return nil
        }
        if map >= Self.enterKPa && rpm >= Self.minRPM { begin(s, rpm: rpm, map: map) }
        return nil
    }

    private mutating func begin(_ s: Sample, rpm: Double, map: Double) {
        start = s.time
        samples = []
        peak = rpm
        append(s, rpm: rpm, map: map, since: s.time)
    }

    private mutating func append(_ s: Sample, rpm: Double, map: Double, since: Date) {
        last = s.time
        peak = max(peak, rpm)
        samples.append(PullSample(t: Float(s.time.timeIntervalSince(since)), rpm: Float(rpm),
                                  lambda: s.lambda.map { Float($0) }, map: Float(map),
                                  adv: s.advance.map { Float($0) }, speed: s.speed.map { Float($0) }))
    }

    private mutating func end() -> Pull? {
        guard let st = start else { return nil }
        let all = samples
        start = nil
        last = nil
        samples = []
        peak = 0
        return Self.classify(all, start: st)
    }

    /// Zug, Dauervollgas oder nichts
    static func classify(_ all: [PullSample], start: Date) -> Pull? {
        guard all.count >= 4, let lastT = all.last?.t, Double(lastT) >= minDuration else { return nil }
        // Zug: vom tiefsten bis zum hoechsten Drehzahlpunkt
        var lo = 0
        var hi = 0
        for i in all.indices {
            if all[i].rpm < all[lo].rpm { lo = i }
            if all[i].rpm >= all[hi].rpm { hi = i }
        }
        if hi > lo, Double(all[hi].rpm - all[lo].rpm) >= minRise, Double(all[hi].t - all[lo].t) >= minDuration {
            let t0 = all[lo].t
            let cut = all[lo...hi].map { s -> PullSample in
                var c = s
                c.t = s.t - t0
                return c
            }
            return Pull(time: start.addingTimeInterval(Double(t0)), kind: .pull, samples: cut)
        }
        // Dauervollgas
        let rpms = all.map { Double($0.rpm) }
        let maps = all.compactMap { $0.map }.map { Double($0) }
        guard Double(lastT) >= steadyDuration, let rLo = rpms.min(), let rHi = rpms.max(),
              rHi - rLo <= steadySpan, !maps.isEmpty,
              maps.reduce(0, +) / Double(maps.count) >= steadyKPa else { return nil }
        return Pull(time: start, kind: .steady, samples: all)
    }
}

/// Auswertung eines Zugs
struct PullAnalysis {
    var duration = 0.0
    var rpmFrom = 0.0
    var rpmTo = 0.0
    var mapMean: Double?
    var lambdaMean: Double?
    var lambdaMin: Double?
    var lambdaMax: Double?
    var bins: [RPMValue] = []            // Lambda je 500 U/min
    var leanFrom: Double?                // ab dieser Drehzahl zu mager
    var drift: Double?                   // Dauervollgas: Lambda-Aenderung je 10 s
    var rate = 0.0                       // U/min je Sekunde
    var ratio: Double?                   // km/h je 1000 U/min (welcher Gang)
    var power: [PowerPoint] = []         // geschaetzte Leistung am Rad
    var peak: PowerPoint?

    enum Verdict { case ok, lean, leanTop, rich, starving, noLambda }
    var verdict: Verdict = .noLambda

    static let leanMargin = 0.05

    init(_ p: Pull, target: Double, vehicle: Vehicle = Vehicle()) {
        let s = p.samples
        guard let first = s.first, let last = s.last else { return }
        duration = Double(last.t - first.t)
        rpmFrom = Double(s.map { $0.rpm }.min() ?? first.rpm)
        rpmTo = Double(s.map { $0.rpm }.max() ?? last.rpm)
        rate = duration > 0 ? Double(last.rpm - first.rpm) / duration : 0
        let maps = s.compactMap { $0.map }.map { Double($0) }
        if !maps.isEmpty { mapMean = maps.reduce(0, +) / Double(maps.count) }

        // Die Sonde laeuft dem Motor etwa 0,25 s hinterher: Lambda dem Punkt davor zuordnen
        var sums: [Int: (Double, Int)] = [:]
        var lams: [Double] = []
        for i in s.indices {
            guard let l = s[i].lambda, l <= 2 else { continue }
            lams.append(Double(l))
            let ref = s[max(0, i - 1)]
            let b = Int((Double(ref.rpm) / 500).rounded())
            let old = sums[b] ?? (0, 0)
            sums[b] = (old.0 + Double(l), old.1 + 1)
        }
        if !lams.isEmpty {
            lambdaMean = lams.reduce(0, +) / Double(lams.count)
            lambdaMin = lams.min()
            lambdaMax = lams.max()
        }
        bins = sums.keys.sorted().compactMap { b in
            guard let v = sums[b], v.1 >= 2 else { return nil }
            return RPMValue(rpm: Double(b) * 500, lambda: v.0 / Double(v.1), count: v.1)
        }
        leanFrom = bins.first { $0.lambda >= target + Self.leanMargin }?.rpm

        if p.kind == .steady { drift = Self.slope(s).map { $0 * 10 } }
        ratio = Self.gearRatio(s)
        if p.kind == .pull, let r = ratio {
            power = Self.powerCurve(s, ratio: r, vehicle: vehicle)
            peak = power.max { $0.kW < $1.kW }
        }

        guard let mean = lambdaMean else { return }
        if p.kind == .steady, let d = drift, d >= 0.03, (lams.last ?? 0) >= target + Self.leanMargin {
            verdict = .starving
        } else if let from = leanFrom {
            // schon unten mager oder erst oben
            verdict = from <= rpmFrom + 600 ? .lean : .leanTop
        } else if mean < target - 0.07 {
            verdict = .rich
        } else {
            verdict = .ok
        }
    }

    /// Zeit zwischen zwei Drehzahlen in Sekunden, nil wenn der Zug sie nicht abdeckt
    static func time(_ p: Pull, from: Double, to: Double) -> Double? {
        func cross(_ rpm: Double) -> Double? {
            let s = p.samples
            for i in s.indices.dropFirst() {
                let a = Double(s[i - 1].rpm), b = Double(s[i].rpm)
                if a <= rpm && b >= rpm && b > a {
                    return Double(s[i - 1].t) + (rpm - a) / (b - a) * Double(s[i].t - s[i - 1].t)
                }
            }
            return nil
        }
        guard let a = cross(from), let b = cross(to), b > a else { return nil }
        return b - a
    }

    /// Steigung von Lambda ueber der Zeit (je Sekunde)
    static func slope(_ s: [PullSample]) -> Double? {
        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for p in s {
            guard let l = p.lambda, l <= 2 else { continue }
            let x = Double(p.t), y = Double(l)
            n += 1
            sx += x
            sy += y
            sxx += x * x
            sxy += x * y
        }
        let den = n * sxx - sx * sx
        guard n >= 12, den > 1e-9 else { return nil }
        return (n * sxy - sx * sy) / den
    }

    /// km/h je 1000 U/min: Median ueber alle Punkte mit GPS-Tempo
    static func gearRatio(_ s: [PullSample]) -> Double? {
        var r: [Double] = []
        for p in s {
            if let v = p.speed, v >= 15, p.rpm >= 1000 { r.append(Double(v) / (Double(p.rpm) / 1000)) }
        }
        guard r.count >= 5 else { return nil }
        r.sort()
        return r[r.count / 2]
    }

    /// Leistung am Rad aus der Beschleunigung: P = (m·a + Rollen + Luft) · v.
    /// Tempo aus Drehzahl mal Uebersetzung, das ist ruhiger als das GPS.
    static func powerCurve(_ s: [PullSample], ratio: Double, vehicle: Vehicle) -> [PowerPoint] {
        guard s.count >= 8 else { return [] }
        var sums: [Int: (Double, Int)] = [:]
        for i in s.indices {
            // Ausgleichsgerade ueber ±0,75 s: geglaettete Drehzahl und ihre Aenderung
            let t0 = Double(s[i].t)
            var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for q in s where abs(Double(q.t) - t0) <= 0.76 {
                let x = Double(q.t) - t0, y = Double(q.rpm)
                n += 1
                sx += x
                sy += y
                sxx += x * x
                sxy += x * y
            }
            let den = n * sxx - sx * sx
            guard n >= 5, den > 1e-9 else { continue }
            let dr = (n * sxy - sx * sy) / den            // U/min je s
            let rpm = (sy - dr * sx) / n                   // Wert bei t0
            let v = ratio * rpm / 1000 / 3.6               // m/s
            let a = ratio * dr / 1000 / 3.6                // m/s²
            let force = vehicle.mass * vehicle.rotating * a
                + vehicle.mass * 9.81 * vehicle.crr
                + 0.5 * 1.2 * vehicle.cdA * v * v
            let kW = force * v / 1000
            let b = Int((rpm / 250).rounded())
            let old = sums[b] ?? (0, 0)
            sums[b] = (old.0 + kW, old.1 + 1)
        }
        return sums.keys.sorted().compactMap { b in
            guard let v = sums[b], v.1 >= 2 else { return nil }
            return PowerPoint(rpm: Double(b) * 250, kW: v.0 / Double(v.1))
        }
    }
}

extension Array where Element == Pull {
    func summary(target: Double) -> PullSummary? {
        guard !isEmpty else { return nil }
        var s = PullSummary(count: count)
        for p in self {
            switch PullAnalysis(p, target: target).verdict {
            case .leanTop, .lean: s.leanTop += 1
            case .starving:       s.starving += 1
            default:              break
            }
        }
        return s
    }
}
