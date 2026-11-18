import Foundation

// ── Rechenkern der Mac-Auswertung ────────────────────────────────
// Ohne Oberflaeche, damit er sich auch ohne Mac pruefen laesst
// (Tests/CoreCheck.swift). Baut auf TripModel, TuningSession,
// MixtureDiagnosis, PullDetector, TipInDetector und AlertMonitor auf.

// MARK: - Kanaele einer Fahrt

enum Channel: String, CaseIterable, Identifiable, Codable {
    case lambda, rpm, map, advance, oilT, oilP, speed, voltage, tank, coil, moduleTemp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lambda:     return "Lambda"
        case .rpm:        return "Drehzahl"
        case .map:        return "Saugrohrdruck"
        case .advance:    return "Zündwinkel"
        case .oilT:       return "Öltemperatur"
        case .oilP:       return "Öldruck"
        case .speed:      return "Tempo"
        case .voltage:    return "Bordnetz"
        case .tank:       return "Tank"
        case .coil:       return "Spulenstrom"
        case .moduleTemp: return "Temperatur 123"
        }
    }

    var unit: String {
        switch self {
        case .lambda:     return ""
        case .rpm:        return "U/min"
        case .map:        return "kPa"
        case .advance:    return "°"
        case .oilT:       return "°C"
        case .oilP:       return "bar"
        case .speed:      return "km/h"
        case .voltage:    return "V"
        case .tank:       return "%"
        case .coil:       return "A"
        case .moduleTemp: return "°C"
        }
    }

    var digits: Int {
        switch self {
        case .lambda:            return 3
        case .oilP, .coil:       return 2
        case .advance, .voltage: return 1
        default:                 return 0
        }
    }

    /// Feste Achse, damit sich Fahrten vergleichen lassen. nil = aus den Daten.
    var range: ClosedRange<Double>? {
        switch self {
        case .lambda:     return 0.75...1.25
        case .rpm:        return 0...6000
        case .map:        return 0...105
        case .advance:    return 0...45
        case .oilT:       return 0...150
        case .oilP:       return 0...6
        case .speed:      return 0...120
        case .voltage:    return 11...15.5
        case .tank:       return 0...100
        case .coil:       return nil
        case .moduleTemp: return nil
        }
    }

    /// Hilfslinien der Achse
    var grid: [Double] {
        switch self {
        case .lambda:  return [0.8, 0.9, 1.0, 1.1, 1.2]
        case .rpm:     return [1000, 2000, 3000, 4000, 5000]
        case .map:     return [30, 50, 70, 90]
        case .advance: return [10, 20, 30, 40]
        case .oilT:    return [50, 100, 150]
        case .oilP:    return [1, 2, 3, 4, 5]
        case .speed:   return [30, 60, 90]
        case .voltage: return [12, 13, 14, 15]
        case .tank:    return [25, 50, 75]
        default:       return []
        }
    }

    static let defaults: [Channel] = [.lambda, .rpm, .map, .advance, .oilT, .oilP, .speed]

    func value(_ r: TripRow) -> Double? {
        switch self {
        case .lambda:     return r.lambdaValid
        case .rpm:        return r.rpm
        case .map:        return r.map
        case .advance:    return r.advance
        case .oilT:       return r.oilT.flatMap { $0 >= 0 ? $0 : nil }
        case .oilP:       return r.oilP.flatMap { $0 >= 0 ? $0 : nil }
        case .speed:      return r.speed
        case .voltage:    return r.voltage
        case .tank:       return r.tank.flatMap { $0 <= 100 ? $0 : nil }
        case .coil:       return r.coil
        case .moduleTemp: return r.moduleTemp
        }
    }

    func format(_ v: Double, unit withUnit: Bool = true) -> String {
        let n = String(format: "%.\(digits)f", v)
        return withUnit && !unit.isEmpty ? n + " " + unit : n
    }
}

// MARK: - Punkte fuer Diagramme

struct SeriesPoint: Hashable {
    var t: Double
    var v: Double
    var seg: Int        // neue Nummer nach einer Luecke: dort keine Linie ziehen
}

enum Downsample {
    /// Luecke in der Aufzeichnung, ab der die Linie unterbrochen wird (Sekunden)
    static let gap = 3.0

    /// Werte eines Kanals im Zeitfenster. Bei vielen Werten Min und Max je Eimer,
    /// damit Spitzen sichtbar bleiben.
    static func series(_ rows: [TripRow], range: ClosedRange<Double>, buckets: Int,
                       _ value: (TripRow) -> Double?) -> [SeriesPoint] {
        let lo = range.lowerBound
        let span = max(1e-6, range.upperBound - lo)
        let first = TripIndex.first(rows, atOrAfter: lo - gap)
        var inRange = 0
        var i = first
        while i < rows.count && rows[i].t <= range.upperBound + gap { inRange += 1; i += 1 }

        var out: [SeriesPoint] = []
        var seg = 0
        var lastT = -Double.infinity
        if inRange <= buckets * 2 {
            for k in first..<(first + inRange) {
                guard let v = value(rows[k]) else { continue }
                let t = rows[k].t
                if t - lastT > gap { seg += 1 }
                lastT = t
                out.append(SeriesPoint(t: t, v: v, seg: seg))
            }
            return out
        }
        var bucket = -1
        var mn: (t: Double, v: Double)?
        var mx: (t: Double, v: Double)?
        func flush() {
            guard let a = mn, let b = mx else { return }
            if a.t <= b.t {
                out.append(SeriesPoint(t: a.t, v: a.v, seg: seg))
                if b.t != a.t { out.append(SeriesPoint(t: b.t, v: b.v, seg: seg)) }
            } else {
                out.append(SeriesPoint(t: b.t, v: b.v, seg: seg))
                out.append(SeriesPoint(t: a.t, v: a.v, seg: seg))
            }
            mn = nil
            mx = nil
        }
        for k in first..<(first + inRange) {
            guard let v = value(rows[k]) else { continue }
            let t = rows[k].t
            if t - lastT > gap {
                flush()
                seg += 1
            }
            lastT = t
            let b = Int((t - lo) / span * Double(buckets))
            if b != bucket {
                flush()
                bucket = b
            }
            if mn == nil || v < mn!.v { mn = (t, v) }
            if mx == nil || v > mx!.v { mx = (t, v) }
        }
        flush()
        return out
    }
}

enum TripIndex {
    /// Erste Zeile mit t >= x (binaere Suche, Zeilen sind nach Zeit sortiert)
    static func first(_ rows: [TripRow], atOrAfter x: Double) -> Int {
        var lo = 0
        var hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].t < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Zeile, die am naechsten an t liegt
    static func nearest(_ rows: [TripRow], _ t: Double) -> Int? {
        guard !rows.isEmpty else { return nil }
        let i = first(rows, atOrAfter: t)
        if i == 0 { return 0 }
        if i >= rows.count { return rows.count - 1 }
        return t - rows[i - 1].t <= rows[i].t - t ? i - 1 : i
    }
}

// MARK: - Auswertung eines Zeitfensters

struct ChannelStat: Hashable {
    var min: Double
    var max: Double
    var mean: Double
    var n: Int
}

enum RangeStats {
    static func of(_ rows: [TripRow], _ ch: Channel, range: ClosedRange<Double>? = nil) -> ChannelStat? {
        var mn = Double.infinity
        var mx = -Double.infinity
        var sum = 0.0
        var n = 0
        let start = range.map { TripIndex.first(rows, atOrAfter: $0.lowerBound) } ?? 0
        var i = start
        while i < rows.count {
            let r = rows[i]
            if let rg = range, r.t > rg.upperBound { break }
            if let v = ch.value(r) {
                mn = min(mn, v)
                mx = max(mx, v)
                sum += v
                n += 1
            }
            i += 1
        }
        return n > 0 ? ChannelStat(min: mn, max: mx, mean: sum / Double(n), n: n) : nil
    }

    static func slice(_ rows: [TripRow], _ range: ClosedRange<Double>) -> [TripRow] {
        let a = TripIndex.first(rows, atOrAfter: range.lowerBound)
        let b = TripIndex.first(rows, atOrAfter: range.upperBound.nextUp)
        return a < b ? Array(rows[a..<b]) : []
    }
}

// MARK: - Kennzahlen einer Fahrt

struct RegimeStat: Codable, Hashable {
    var seconds = 0.0
    var lambdaSum = 0.0
    var lambdaN = 0

    var lambda: Double? { lambdaN >= 8 ? lambdaSum / Double(lambdaN) : nil }

    mutating func add(_ o: RegimeStat) {
        seconds += o.seconds
        lambdaSum += o.lambdaSum
        lambdaN += o.lambdaN
    }
}

struct TripStats: Codable, Identifiable {
    static let version = 2

    var id: String
    var version = TripStats.version
    var start: Date
    var duration: Double
    var distanceKm: Double
    var runningSeconds = 0.0
    var regimes: [String: RegimeStat] = [:]         // alle Werte mit Drehzahl und Saugrohrdruck
    var steadyRegimes: [String: RegimeStat] = [:]   // nur ruhige Fahrt bei warmem Motor
    var lambdaMean: Double?
    var rpmMax: Double?
    var speedMax: Double?
    var oilTMax: Double?
    var oilTWarmMean: Double?
    var oilPIdleWarm: Double?        // Leerlauf, Oel ab 70 °C
    var oilP3000Warm: Double?        // 2700–3300 U/min, Oel ab 70 °C
    var voltageRunning: Double?      // ab 1500 U/min
    var secondsOver5000 = 0.0
    var warmupMinutes: Double?       // Kaltstart bis Oel 60 °C
    var pulls: [Pull] = []
    var tipIns: [TipInEvent] = []
    var alerts: [String: Int] = [:]  // AlertKind.rawValue -> Anzahl
    var markers = 0

    var end: Date { start.addingTimeInterval(duration) }

    func regime(_ r: Regime, steady: Bool) -> RegimeStat? {
        (steady ? steadyRegimes : regimes)[r.rawValue]
    }

    static func compute(summary: TripSummary, rows: [TripRow]) -> TripStats {
        var s = TripStats(id: summary.id, start: summary.start,
                          duration: max(summary.duration, rows.last?.t ?? 0),
                          distanceKm: summary.distanceKm)
        s.markers = summary.markers.count
        var tracker = SteadyTracker()
        var pullDet = PullDetector()
        var tipDet = TipInDetector()
        var alerts = AlertMonitor()
        var lamSum = 0.0, lamN = 0
        var oilTSum = 0.0, oilTN = 0
        var idleP = 0.0, idleN = 0
        var p3000 = 0.0, p3000N = 0
        var vSum = 0.0, vN = 0
        var firstOilT: Double?
        var lastT = -1.0
        let settings = AlertSettings()

        for (i, r) in rows.enumerated() {
            let next = i + 1 < rows.count ? rows[i + 1].t : r.t + 0.25
            let dt = min(1, max(0, next - r.t))
            if r.t - lastT > 2 { tracker.reset() }
            lastT = r.t
            let calm = tracker.push(t: r.t, rpm: r.rpm, map: r.map)
            let lam = r.lambdaValid
            if let l = lam { lamSum += l; lamN += 1 }
            if let t = r.oilT, t >= 0 {
                if firstOilT == nil { firstOilT = t }
                s.oilTMax = max(s.oilTMax ?? -100, t)
                if s.warmupMinutes == nil, let f = firstOilT, f < 50, t >= 60 { s.warmupMinutes = r.t / 60 }
            }
            if let v = r.speed { s.speedMax = max(s.speedMax ?? 0, v) }
            if let rpm = r.rpm {
                s.rpmMax = max(s.rpmMax ?? 0, rpm)
                if rpm >= 300 { s.runningSeconds += dt }
                if rpm >= 5000 { s.secondsOver5000 += dt }
                let warm70 = (r.oilT ?? 0) >= 70
                if let p = r.oilP, p >= 0, warm70 {
                    if rpm >= 600 && rpm < 1300 { idleP += p; idleN += 1 }
                    if rpm >= 2700 && rpm <= 3300 { p3000 += p; p3000N += 1 }
                }
                if rpm >= 300, let t = r.oilT, t >= 60 { oilTSum += t; oilTN += 1 }
                if rpm >= 1500, let v = r.voltage { vSum += v; vN += 1 }
                if rpm >= 300, let k = r.map {
                    let g = Regime.of(rpm: rpm, kPa: k).rawValue
                    var st = s.regimes[g] ?? RegimeStat()
                    st.seconds += dt
                    if let l = lam { st.lambdaSum += l; st.lambdaN += 1 }
                    s.regimes[g] = st
                    if calm && (r.oilT ?? 100) >= TuningSession.warmOilT {
                        var ss = s.steadyRegimes[g] ?? RegimeStat()
                        ss.seconds += dt
                        if let l = lam { ss.lambdaSum += l; ss.lambdaN += 1 }
                        s.steadyRegimes[g] = ss
                    }
                }
            }
            let sample = r.sample(start: summary.start)
            if let p = pullDet.add(sample) { s.pulls.append(p) }
            if let e = tipDet.add(sample) { s.tipIns.append(e) }
            for a in alerts.update(sample, settings: settings) {
                s.alerts[a.kind.rawValue, default: 0] += 1
            }
        }
        // Zug, der bis zum Ende der Aufzeichnung lief
        if let last = rows.last {
            var end = Sample(time: summary.start.addingTimeInterval(last.t + 0.25))
            end.rpm = 0
            end.mapKPa = 30
            if let p = pullDet.add(end) { s.pulls.append(p) }
        }
        s.lambdaMean = lamN > 0 ? lamSum / Double(lamN) : nil
        s.oilTWarmMean = oilTN > 0 ? oilTSum / Double(oilTN) : nil
        s.oilPIdleWarm = idleN >= 20 ? idleP / Double(idleN) : nil
        s.oilP3000Warm = p3000N >= 20 ? p3000 / Double(p3000N) : nil
        s.voltageRunning = vN >= 20 ? vSum / Double(vN) : nil
        return s
    }
}

// MARK: - Zusammenfassen ueber mehrere Fahrten

struct Period: Hashable {
    var from: Date?
    var to: Date?

    func contains(_ d: Date) -> Bool {
        if let f = from, d < f { return false }
        if let t = to, d >= t { return false }
        return true
    }

    static let all = Period(from: nil, to: nil)
    static func last(days: Int, now: Date = Date()) -> Period {
        Period(from: now.addingTimeInterval(-Double(days) * 86_400), to: nil)
    }
}

enum Aggregate {
    static func regimes(_ stats: [TripStats], steady: Bool) -> [String: RegimeStat] {
        var out: [String: RegimeStat] = [:]
        for s in stats {
            for (k, v) in (steady ? s.steadyRegimes : s.regimes) {
                var a = out[k] ?? RegimeStat()
                a.add(v)
                out[k] = a
            }
        }
        return out
    }

    struct Totals: Hashable {
        var trips = 0
        var km = 0.0
        var engineHours = 0.0
        var seconds = 0.0
        var pulls = 0
        var tipIns = 0
        var alerts = 0
    }

    static func totals(_ stats: [TripStats]) -> Totals {
        var t = Totals()
        for s in stats {
            t.trips += 1
            t.km += s.distanceKm
            t.engineHours += s.runningSeconds / 3600
            t.seconds += s.duration
            t.pulls += s.pulls.count
            t.tipIns += s.tipIns.count
            t.alerts += s.alerts.values.reduce(0, +)
        }
        return t
    }

    /// Mittel einer Kennzahl je Fahrt (fuer Trends), nil-Werte werden uebersprungen
    static func mean(_ stats: [TripStats], _ key: (TripStats) -> Double?) -> Double? {
        let v = stats.compactMap(key)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
}

// MARK: - Trends ueber die Zeit

struct TrendPoint: Hashable, Identifiable {
    var date: Date
    var series: String           // Bereich oder Kennzahl
    var value: Double
    var id: String { series + "|" + String(date.timeIntervalSinceReferenceDate) }
}

enum Trend {
    /// Mittleres Lambda je Bereich und Fahrt, nur ruhige Fahrt mit mindestens `minSeconds`
    static func lambda(_ stats: [TripStats], regimes: [Regime] = [.idle, .cruise, .transition, .fullLow, .fullHigh],
                       minSeconds: Double = 10) -> [TrendPoint] {
        var out: [TrendPoint] = []
        for s in stats.sorted(by: { $0.start < $1.start }) {
            for r in regimes {
                guard let st = s.steadyRegimes[r.rawValue], st.seconds >= minSeconds, let l = st.lambda else { continue }
                out.append(TrendPoint(date: s.start, series: r.title, value: l))
            }
        }
        return out
    }

    /// Hoechste geschaetzte Radleistung je Zug
    static func power(_ pulls: [Pull], target: Double, vehicle: Vehicle) -> [TrendPoint] {
        pulls.compactMap { p in
            guard p.kind == .pull, let k = PowerSanity.ok(PullAnalysis(p, target: target, vehicle: vehicle).peak?.kW)
            else { return nil }
            return TrendPoint(date: p.time, series: "Leistung", value: k)
        }
    }
}

// MARK: - Was hat eine Aenderung am Vergaser gebracht?

struct LogEffect: Identifiable {
    var entry: LogEntry
    var before: [String: RegimeStat]
    var after: [String: RegimeStat]
    var beforeTrips: Int
    var afterTrips: Int
    var beforePower: Double?          // Mittel der Spitzenleistung aller Zuege
    var afterPower: Double?
    var beforeTipLean: Double?        // Anteil magerer Gasstoesse
    var afterTipLean: Double?
    var beforeFrom: Date
    var afterTo: Date

    var id: UUID { entry.id }

    func lambda(_ r: Regime, after a: Bool) -> Double? {
        let st = (a ? after : before)[r.rawValue]
        guard let st, st.seconds >= 10 else { return nil }
        return st.lambda
    }

    func delta(_ r: Regime) -> Double? {
        guard let b = lambda(r, after: false), let a = lambda(r, after: true) else { return nil }
        return a - b
    }
}

enum LogAnalysis {
    /// Je Logbuch-Eintrag: bis zu `window` vorher (hoechstens bis zum vorigen Eintrag)
    /// gegen bis zu `window` nachher (hoechstens bis zum naechsten Eintrag)
    static func effects(entries: [LogEntry], stats: [TripStats], window: Double = 30 * 86_400,
                        target: Double, vehicle: Vehicle) -> [LogEffect] {
        let sorted = entries.sorted { $0.date < $1.date }
        var out: [LogEffect] = []
        for (i, e) in sorted.enumerated() {
            let prev = i > 0 ? sorted[i - 1].date : Date.distantPast
            let next = i + 1 < sorted.count ? sorted[i + 1].date : Date.distantFuture
            let from = max(prev, e.date.addingTimeInterval(-window))
            let to = min(next, e.date.addingTimeInterval(window))
            let b = stats.filter { $0.start >= from && $0.start < e.date }
            let a = stats.filter { $0.start >= e.date && $0.start < to }
            func power(_ s: [TripStats]) -> Double? {
                let p = Trend.power(s.flatMap { $0.pulls }, target: target, vehicle: vehicle).map { $0.value }
                return p.isEmpty ? nil : p.reduce(0, +) / Double(p.count)
            }
            func lean(_ s: [TripStats]) -> Double? {
                let t = s.flatMap { $0.tipIns }
                guard t.count >= 3 else { return nil }
                return Double(t.filter { $0.verdict == .lean }.count) / Double(t.count)
            }
            out.append(LogEffect(entry: e, before: Aggregate.regimes(b, steady: true),
                                 after: Aggregate.regimes(a, steady: true),
                                 beforeTrips: b.count, afterTrips: a.count,
                                 beforePower: power(b), afterPower: power(a),
                                 beforeTipLean: lean(b), afterTipLean: lean(a),
                                 beforeFrom: from, afterTo: to))
        }
        return out.reversed()
    }
}

// MARK: - Kennfeld-Differenz

enum MapDiff {
    /// B minus A je Zelle, nur wo beide genug Werte haben
    static func lambda(_ a: TuningSession, _ b: TuningSession, steady: Bool) -> [[Double?]] {
        var v: [[Double?]] = Array(repeating: Array(repeating: nil, count: TuningSession.cols), count: TuningSession.rows)
        for r in 0..<TuningSession.rows {
            for c in 0..<TuningSession.cols {
                if let x = a.lambda(row: r, col: c, steady: steady), let y = b.lambda(row: r, col: c, steady: steady) {
                    v[r][c] = y - x
                }
            }
        }
        return v
    }
}

// MARK: - Zusammenfassung aus Zeilen (Import, Beispieldaten)

extension TripSummary {
    /// Zusammenfassung wie auf dem iPhone, aus den Zeilen gerechnet.
    /// Die Strecke kommt aus dem Tempo.
    static func from(id: String, start: Date, rows: [TripRow]) -> TripSummary {
        var s = TripSummary(id: id, start: start, end: start.addingTimeInterval(rows.last?.t ?? 0))
        var lastT: Double?
        for r in rows {
            let dt = lastT.map { min(1, max(0, r.t - $0)) } ?? 0
            lastT = r.t
            if let v = r.speed {
                s.distanceKm += v / 3600 * dt
                s.maxSpeed = max(s.maxSpeed ?? 0, v)
            }
            if let v = r.rpm {
                s.maxRPM = max(s.maxRPM ?? 0, v)
                if v >= 5000 { s.secondsOver5000 += dt }
                if let p = r.oilP, p >= 0, v >= 1200 { s.minOilPRunning = min(s.minOilPRunning ?? 99, p) }
            }
            if let v = r.oilT, v >= 0 { s.maxOilT = max(s.maxOilT ?? -100, v) }
            if let l = r.lambdaValid {
                s.lambdaSum += l
                s.lambdaCount += 1
            }
            if let m = r.marker { s.markers.append(TripMarker(id: m, time: start.addingTimeInterval(r.t))) }
        }
        return s
    }
}

// MARK: - Lambda ueber der Drehzahl aus dem Kennfeld

enum CurveData {
    /// Mittel je Drehzahlspalte ueber die Zeilen `rows` (Last), gewichtet nach Anzahl
    static func byRPM(_ s: TuningSession, rows: ClosedRange<Int>, steady: Bool, minCount: Int = 8) -> [RPMValue] {
        let grid = s.cells(steady: steady)
        var out: [RPMValue] = []
        for c in 0..<TuningSession.cols {
            var sum = 0.0
            var n = 0
            for r in rows where r >= 0 && r < TuningSession.rows {
                sum += grid[r][c].sum
                n += grid[r][c].count
            }
            if n >= minCount { out.append(RPMValue(rpm: TuningSession.colCenter(c), lambda: sum / Double(n), count: n)) }
        }
        return out
    }

    static let fullLoad = 7...7          // ab 90 kPa
    static let partLoad = 1...4          // 30–70 kPa
}

// MARK: - Zeit als Text

enum TimeText {
    static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m < 60 ? "\(m) min" : String(format: "%d:%02d h", m / 60, m % 60)
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Ein 2CV6 hat knapp 22 kW. Was weit darüber liegt, ist ein Messfehler
/// (Schaltvorgang, Kupplung, Sprung im Tempo) und zählt nicht.
enum PowerSanity {
    static let maxKW = 40.0
    static func ok(_ kW: Double?) -> Double? {
        guard let k = kW, k > 0, k <= maxKW else { return nil }
        return k
    }
}

// ── Text ─────────────────────────────────────────────────────────

/// Vorzeichen immer zeigen, aber kein "-0.000"
enum SignedText {
    static func of(_ v: Double, _ digits: Int) -> String {
        let half = 0.5 / pow(10, Double(digits))
        if abs(v) < half { return "±" + String(format: "%.\(digits)f", 0.0) }
        return String(format: "%+.\(digits)f", v)
    }
}

extension LogEntry {
    /// Erster Eintrag: alle Werte kamen von "–". Das ist der Ausgangsstand, keine Änderung.
    var isBaseline: Bool { !changes.isEmpty && changes.allSatisfy { $0.contains(": – → ") } }
    /// Für Listen und Überschriften
    var label: String { isBaseline ? "Ausgangsstand" : title }
    /// Kurz, für Markierungen in Diagrammen
    var shortLabel: String {
        if isBaseline { return "Ausgangsstand" }
        return changes.first ?? (note.isEmpty ? "Eintrag" : note)
    }
}
