import Foundation

// ── Messreihen fuer die Abstimmung ───────────────────────────────
// Lambda-Kennfeld (Drehzahl x Last), Zuendwinkel ueber Drehzahl und die
// Rohpunkte. "Aktuell" sammelt laufend, gespeicherte Reihen liegen als
// JSON in Dokumente/Messreihen und lassen sich vergleichen.

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

struct TuningSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var created = Date()
    var lambdaCells: [[TuneCell]] = Array(repeating: Array(repeating: TuneCell(), count: TuningSession.cols),
                                          count: TuningSession.rows)
    var advanceBins: [TuneCell] = Array(repeating: TuneCell(), count: TuningSession.advBins)
    var lambdaPoints: [TunePoint] = []
    var advancePoints: [TunePoint] = []

    static let cols = 11          // Spalten 1000 … 6000 U/min, je 500
    static let rows = 8           // Zeilen 20 … 100 kPa, je 10
    static let advBins = 23       // Zuendkurve 625 … 6125 U/min, je 250
    static let maxPoints = 4000
    static let minCount = 3       // weniger Werte gelten als "keine Aussage"

    static func colCenter(_ c: Int) -> Double { 1000 + Double(c) * 500 }
    static func rowLow(_ r: Int) -> Double { 20 + Double(r) * 10 }
    static func advCenter(_ i: Int) -> Double { 625 + Double(i) * 250 }

    static func col(_ rpm: Double) -> Int { min(cols - 1, max(0, Int((rpm - 750) / 500))) }
    static func row(_ kPa: Double) -> Int { min(rows - 1, max(0, Int((kPa - 20) / 10))) }
    static func advBin(_ rpm: Double) -> Int { min(advBins - 1, max(0, Int((rpm - 500) / 250))) }

    var lambdaCount: Int {
        var n = 0
        for row in lambdaCells { for c in row { n += c.count } }
        return n
    }

    var advanceCount: Int {
        var n = 0
        for c in advanceBins { n += c.count }
        return n
    }

    mutating func add(lambda: Double?, rpm: Double?, map: Double?, advance: Double?) {
        guard let r = rpm, r >= 500 else { return }
        let mf: Float? = map.map { Float($0) }
        if let l = lambda, l <= 2 {
            if let m = map {
                lambdaCells[Self.row(m)][Self.col(r)].add(l)
            }
            lambdaPoints.append(TunePoint(r: Float(r), v: Float(l), m: mf))
            if lambdaPoints.count > Self.maxPoints { lambdaPoints.removeFirst(lambdaPoints.count - Self.maxPoints) }
        }
        if let a = advance {
            advanceBins[Self.advBin(r)].add(a)
            advancePoints.append(TunePoint(r: Float(r), v: Float(a), m: mf))
            if advancePoints.count > Self.maxPoints { advancePoints.removeFirst(advancePoints.count - Self.maxPoints) }
        }
    }

    /// Mittleres Lambda einer Kennfeld-Zelle, nil bei zu wenigen Werten
    func lambda(row: Int, col: Int) -> Double? {
        let c = lambdaCells[row][col]
        return c.count >= Self.minCount ? c.sum / Double(c.count) : nil
    }

    /// Streuung (Standardabweichung) des Lambdas einer Zelle
    func spread(row: Int, col: Int) -> Double? { lambdaCells[row][col].spread }

    /// Anzahl Lambda-Werte einer Zelle
    func count(row: Int, col: Int) -> Int { lambdaCells[row][col].count }

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

final class TuningStore: ObservableObject {
    @Published private(set) var current: TuningSession
    @Published private(set) var saved: [TuningSession] = []

    private var work: TuningSession
    private var lastPublish = Date.distantPast
    private var dirty = false

    static let folder: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = docs.appendingPathComponent("Messreihen", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()

    private static var currentURL: URL { folder.appendingPathComponent("aktuell.json") }

    init() {
        let s = Self.read(Self.currentURL) ?? TuningSession(name: "Aktuell")
        work = s
        current = s
        loadSaved()
    }

    /// Alle 0,25 s aus dem AppModel
    func add(_ s: Sample) {
        guard s.rpm != nil else { return }
        work.add(lambda: s.lambda, rpm: s.rpm, map: s.mapKPa, advance: s.advance)
        dirty = true
        if s.time.timeIntervalSince(lastPublish) >= 1 {
            lastPublish = s.time
            current = work
        }
    }

    func persist() {
        guard dirty else { return }
        dirty = false
        Self.write(work, to: Self.currentURL)
    }

    func resetCurrent() {
        work = TuningSession(name: "Aktuell")
        current = work
        dirty = true
        persist()
    }

    func saveCurrent(as name: String) {
        var copy = work
        copy.id = UUID()
        copy.name = name.isEmpty ? "Messreihe" : name
        copy.created = Date()
        Self.write(copy, to: Self.url(for: copy))
        loadSaved()
    }

    /// Eine aufgezeichnete Fahrt als Messreihe speichern
    func save(rows: [TripRow], name: String) {
        var s = TuningSession(name: name.isEmpty ? "Fahrt" : name)
        for r in rows { s.add(lambda: r.lambda, rpm: r.rpm, map: r.map, advance: r.advance) }
        Self.write(s, to: Self.url(for: s))
        loadSaved()
    }

    func delete(_ s: TuningSession) {
        try? FileManager.default.removeItem(at: Self.url(for: s))
        loadSaved()
    }

    /// "Aktuell" plus alle gespeicherten, fuer die Auswahl im Vergleich
    var all: [TuningSession] { [current] + saved }

    func session(_ id: UUID?) -> TuningSession? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    private func loadSaved() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        var list: [TuningSession] = []
        for f in files where f.pathExtension == "json" && f.lastPathComponent != "aktuell.json" {
            if let s = Self.read(f) { list.append(s) }
        }
        saved = list.sorted { $0.created > $1.created }
    }

    private static func url(for s: TuningSession) -> URL {
        folder.appendingPathComponent(s.id.uuidString + ".json")
    }

    private static func read(_ url: URL) -> TuningSession? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TuningSession.self, from: d)
    }

    private static func write(_ s: TuningSession, to url: URL) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: url, options: .atomic)
    }
}
