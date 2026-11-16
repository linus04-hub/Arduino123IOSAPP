import Foundation

// ── Messreihe: Lambda-Kennfeld, Zuendwinkel, Rohpunkte ───────────
// Lambda-Kennfeld (Drehzahl x Last), Zuendwinkel ueber Drehzahl und die
// Rohpunkte. Ab Version 2.0 zusaetzlich ein zweites Kennfeld nur aus
// ruhiger Fahrt bei warmem Motor, Leerlauf-Statistik, Lambda-Verteilung
// je Betriebsbereich und Lambda ueber der Oeltemperatur. Alles Neue ist
// optional, damit aeltere Messreihen weiter lesbar bleiben.

struct TuneCell: Codable, Hashable {
    var sum: Double = 0
    var count: Int = 0
    // Fuer die Streuung. Erst ab Version 1.2 erfasst; Messreihen von vorher
    // haben diese Felder nicht und zeigen dort keine Streuung.
    var vSum: Double = 0
    var vSq: Double = 0
    var vCount: Int = 0

    var mean: Double? { count > 0 ? sum / Double(count) : nil }

    init() {}

    enum CodingKeys: String, CodingKey { case sum, count, vSum, vSq, vCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sum = try c.decodeIfPresent(Double.self, forKey: .sum) ?? 0
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        vSum = try c.decodeIfPresent(Double.self, forKey: .vSum) ?? 0
        vSq = try c.decodeIfPresent(Double.self, forKey: .vSq) ?? 0
        vCount = try c.decodeIfPresent(Int.self, forKey: .vCount) ?? 0
    }

    mutating func add(_ v: Double) {
        sum += v
        count += 1
        vSum += v
        vSq += v * v
        vCount += 1
    }

    /// Standardabweichung, nil bei zu wenigen Werten
    var spread: Double? {
        guard vCount >= TuningSession.minCount else { return nil }
        let n = Double(vCount)
        let m = vSum / n
        return (max(0, vSq / n - m * m)).squareRoot()
    }
}

struct TunePoint: Codable, Hashable {
    var r: Float       // Drehzahl
    var v: Float       // Lambda oder Zuendwinkel
    var m: Float?      // Saugrohrdruck in kPa
}

/// Ein Messpunkt, wie er in die Messreihe einfliesst
struct SessionPoint {
    var lambda: Double?
    var rpm: Double?
    var map: Double?
    var advance: Double?
    var oilT: Double? = nil
    var speed: Double? = nil
    var steady = false          // ruhige Fahrt, siehe SteadyTracker
}

/// Erkennt ruhige Fahrt: Gaspedal und Drehzahl aendern sich kaum. Nur
/// solche Werte taugen fuer das Kennfeld, weil die Sonde dem Motor etwas
/// hinterherlaeuft und Gasstoesse das Bild sonst verfaelschen.
struct SteadyTracker {
    static let window = 1.5            // Sekunden
    static let maxMapSpan = 6.0        // kPa
    static let maxRPMSpan = 500.0      // U/min; Beschleunigen im Gang bleibt erlaubt
    static let minSamples = 5

    private var times: [Double] = []
    private var rpms: [Double] = []
    private var maps: [Double] = []

    mutating func reset() {
        times.removeAll()
        rpms.removeAll()
        maps.removeAll()
    }

    /// `t` in Sekunden (beliebiger Nullpunkt). Gibt true bei ruhiger Fahrt zurueck.
    mutating func push(t: Double, rpm: Double?, map: Double?) -> Bool {
        guard let r = rpm, let m = map else {
            reset()
            return false
        }
        if let last = times.last, t - last > 1.0 || t < last { reset() }
        times.append(t)
        rpms.append(r)
        maps.append(m)
        while let first = times.first, t - first > Self.window + 0.01 {
            times.removeFirst()
            rpms.removeFirst()
            maps.removeFirst()
        }
        guard times.count >= Self.minSamples,
              let rLo = rpms.min(), let rHi = rpms.max(),
              let mLo = maps.min(), let mHi = maps.max() else { return false }
        return rHi - rLo <= Self.maxRPMSpan && mHi - mLo <= Self.maxMapSpan
    }
}

struct TuningSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var created = Date()
    var lambdaCells: [[TuneCell]] = Array(repeating: Array(repeating: TuneCell(), count: TuningSession.cols),
                                          count: TuningSession.rows)
    var advanceBins: [TuneCell] = Array(repeating: TuneCell(), count: TuningSession.advBins)
    var lambdaPoints: [TunePoint] = []
    var advancePoints: [TunePoint] = []
    /// Zuendwinkel je Kennfeld-Zelle. Erst ab Version 1.4 erfasst, aeltere
    /// Messreihen haben das Feld nicht (deshalb optional).
    var advanceCells: [[TuneCell]]?

    // ── ab Version 2.0 ──
    /// Lambda-Kennfeld nur aus ruhiger Fahrt bei warmem Motor
    var steadyCells: [[TuneCell]]?
    /// Leerlauf im Stand: Lambda und Drehzahl
    var idleLambda: TuneCell?
    var idleRPM: TuneCell?
    /// Lambda-Verteilung je Betriebsbereich (Schluessel Regime.rawValue), ruhige Fahrt
    var hist: [String: [Int]]?
    /// Lambda ueber der Oeltemperatur (Leerlauf und Teillast), siehe warmEdges
    var warmup: [TuneCell]?

    init(name: String) {
        self.name = name
    }

    static let cols = 11          // Spalten 1000 … 6000 U/min, je 500
    static let rows = 8           // Zeilen 20 … 100 kPa, je 10
    static let advBins = 23       // Zuendkurve 625 … 6125 U/min, je 250
    static let maxPoints = 4000
    static let minCount = 3       // weniger Werte gelten als "keine Aussage"
    static let warmOilT = 60.0    // ab hier gilt der Motor als warm

    static let histBins = 30      // Lambda 0,70 … 1,30 in Schritten von 0,02
    static let histLow = 0.70
    static let histStep = 0.02
    static let warmEdges: [Double] = [40, 60, 80]      // 4 Klassen: <40, 40–60, 60–80, ab 80 °C

    static func colCenter(_ c: Int) -> Double { 1000 + Double(c) * 500 }
    static func rowLow(_ r: Int) -> Double { 20 + Double(r) * 10 }
    static func advCenter(_ i: Int) -> Double { 625 + Double(i) * 250 }

    static func col(_ rpm: Double) -> Int { min(cols - 1, max(0, Int((rpm - 750) / 500))) }
    static func row(_ kPa: Double) -> Int { min(rows - 1, max(0, Int((kPa - 20) / 10))) }
    static func advBin(_ rpm: Double) -> Int { min(advBins - 1, max(0, Int((rpm - 500) / 250))) }
    static func histBin(_ lambda: Double) -> Int {
        min(histBins - 1, max(0, Int((lambda - histLow) / histStep)))
    }
    static func warmBin(_ oilT: Double) -> Int {
        var i = 0
        for e in warmEdges where oilT >= e { i += 1 }
        return i
    }

    static func emptyCells() -> [[TuneCell]] {
        Array(repeating: Array(repeating: TuneCell(), count: cols), count: rows)
    }

    var lambdaCount: Int {
        var n = 0
        for row in lambdaCells { for c in row { n += c.count } }
        return n
    }

    var steadyCount: Int {
        var n = 0
        for row in steadyCells ?? [] { for c in row { n += c.count } }
        return n
    }

    var advanceCount: Int {
        var n = 0
        for c in advanceBins { n += c.count }
        return n
    }

    /// Ruhige Fahrt ist erfasst und es sind genug Werte da, um damit zu rechnen
    var hasSteady: Bool { steadyCount >= 120 }

    mutating func add(lambda: Double?, rpm: Double?, map: Double?, advance: Double?) {
        add(SessionPoint(lambda: lambda, rpm: rpm, map: map, advance: advance))
    }

    mutating func add(_ p: SessionPoint) {
        guard let r = p.rpm, r >= 500 else { return }
        let mf: Float? = p.map.map { Float($0) }
        if let l = p.lambda, l <= 2 {
            if let m = p.map {
                let row = Self.row(m)
                let col = Self.col(r)
                lambdaCells[row][col].add(l)
                if p.steady { addSteady(l, rpm: r, map: m, row: row, col: col, oilT: p.oilT, speed: p.speed) }
            }
            lambdaPoints.append(TunePoint(r: Float(r), v: Float(l), m: mf))
            if lambdaPoints.count > Self.maxPoints { lambdaPoints.removeFirst(lambdaPoints.count - Self.maxPoints) }
        }
        if let a = p.advance {
            advanceBins[Self.advBin(r)].add(a)
            if let m = p.map {
                if advanceCells == nil { advanceCells = Self.emptyCells() }
                advanceCells?[Self.row(m)][Self.col(r)].add(a)
            }
            advancePoints.append(TunePoint(r: Float(r), v: Float(a), m: mf))
            if advancePoints.count > Self.maxPoints { advancePoints.removeFirst(advancePoints.count - Self.maxPoints) }
        }
    }

    private mutating func addSteady(_ l: Double, rpm: Double, map: Double, row: Int, col: Int,
                                    oilT: Double?, speed: Double?) {
        let regime = Regime.of(rpm: rpm, kPa: map)
        // Lambda ueber der Oeltemperatur, auch bei kaltem Motor
        if let t = oilT, t >= 0, regime == .idle || regime == .cruise {
            if warmup == nil { warmup = Array(repeating: TuneCell(), count: Self.warmEdges.count + 1) }
            warmup?[Self.warmBin(t)].add(l)
        }
        // alles Weitere nur warm; ohne Oeltemperatur gilt der Motor als warm
        guard (oilT ?? 100) >= Self.warmOilT else { return }
        if steadyCells == nil { steadyCells = Self.emptyCells() }
        steadyCells?[row][col].add(l)

        var h = hist ?? [:]
        var bins = h[regime.rawValue] ?? [Int](repeating: 0, count: Self.histBins)
        if bins.count != Self.histBins { bins = [Int](repeating: 0, count: Self.histBins) }
        bins[Self.histBin(l)] += 1
        h[regime.rawValue] = bins
        hist = h

        if regime == .idle && (speed ?? 0) < 4 {
            var il = idleLambda ?? TuneCell()
            il.add(l)
            idleLambda = il
            var ir = idleRPM ?? TuneCell()
            ir.add(rpm)
            idleRPM = ir
        }
    }

    /// Kennfeld: alle Werte oder nur ruhige Fahrt
    func cells(steady: Bool) -> [[TuneCell]] {
        steady ? (steadyCells ?? Self.emptyCells()) : lambdaCells
    }

    /// Mittleres Lambda einer Kennfeld-Zelle, nil bei zu wenigen Werten
    func lambda(row: Int, col: Int, steady: Bool = false) -> Double? {
        let c = cells(steady: steady)[row][col]
        return c.count >= Self.minCount ? c.sum / Double(c.count) : nil
    }

    /// Streuung (Standardabweichung) des Lambdas einer Zelle
    func spread(row: Int, col: Int, steady: Bool = false) -> Double? {
        cells(steady: steady)[row][col].spread
    }

    /// Anzahl Lambda-Werte einer Zelle
    func count(row: Int, col: Int, steady: Bool = false) -> Int {
        cells(steady: steady)[row][col].count
    }

    /// Mittlerer Zuendwinkel einer Kennfeld-Zelle, nil bei zu wenigen Werten
    func advance(row: Int, col: Int) -> Double? {
        guard let cells = advanceCells else { return nil }
        let c = cells[row][col]
        return c.count >= Self.minCount ? c.sum / Double(c.count) : nil
    }

    /// Lambda-Mittel je 500 U/min ueber alle Lasten
    var lambdaCurve: [(Double, Double)] {
        var out: [(Double, Double)] = []
        for c in 0..<Self.cols {
            var s = 0.0
            var n = 0
            for r in 0..<Self.rows {
                s += lambdaCells[r][c].sum
                n += lambdaCells[r][c].count
            }
            if n >= Self.minCount { out.append((Self.colCenter(c), s / Double(n))) }
        }
        return out
    }

    /// Mittlerer Zuendwinkel je 250 U/min
    var advanceCurve: [(Double, Double)] {
        var out: [(Double, Double)] = []
        for i in 0..<Self.advBins {
            let c = advanceBins[i]
            if c.count >= Self.minCount { out.append((Self.advCenter(i), c.sum / Double(c.count))) }
        }
        return out
    }
}

struct CircuitStats {
    let lambda: Double
    let count: Int
    let cells: Int
}

extension TuningSession {
    /// Mittleres Lambda eines Vergaserkreises, gewichtet nach Anzahl der Werte
    func stats(_ circuit: CarbCircuit, steady: Bool = false) -> CircuitStats? {
        let grid = cells(steady: steady)
        var sum = 0.0
        var n = 0
        var cells = 0
        for r in 0..<Self.rows {
            for c in 0..<Self.cols where circuit.contains(row: r, col: c) {
                let cell = grid[r][c]
                if cell.count >= Self.minCount {
                    sum += cell.sum
                    n += cell.count
                    cells += 1
                }
            }
        }
        guard n > 0 else { return nil }
        return CircuitStats(lambda: sum / Double(n), count: n, cells: cells)
    }
}
