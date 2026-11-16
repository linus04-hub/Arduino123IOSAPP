import Foundation

// ── Messreihen fuer die Abstimmung: Ablage ───────────────────────
// "Aktuell" sammelt laufend, gespeicherte Reihen liegen als JSON in
// Dokumente/Messreihen und lassen sich vergleichen. Das Datenmodell
// steht in TuningSession.swift.

final class TuningStore: ObservableObject {
    @Published private(set) var current: TuningSession
    @Published private(set) var saved: [TuningSession] = []

    private var work: TuningSession
    private var tracker = SteadyTracker()
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
        guard s.rpm != nil else {
            tracker.reset()
            return
        }
        let steady = tracker.push(t: s.time.timeIntervalSinceReferenceDate, rpm: s.rpm, map: s.mapKPa)
        work.add(SessionPoint(lambda: s.lambda, rpm: s.rpm, map: s.mapKPa, advance: s.advance,
                              oilT: s.oilT, speed: s.speed, steady: steady))
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
        tracker.reset()
        work = TuningSession(name: "Aktuell")
        current = work
        dirty = true
        persist()
    }

    @discardableResult
    func saveCurrent(as name: String) -> TuningSession {
        var copy = work
        copy.id = UUID()
        copy.name = name.isEmpty ? "Messreihe" : name
        copy.created = Date()
        Self.write(copy, to: Self.url(for: copy))
        loadSaved()
        return copy
    }

    /// Nach einer Aenderung am Vergaser: das Bisherige sichern und leer weitermessen.
    /// Gibt die gesicherte Messreihe zurueck, nil wenn noch nichts gemessen war.
    func archiveCurrent(as name: String) -> TuningSession? {
        guard work.lambdaCount >= 240 else {
            resetCurrent()
            return nil
        }
        let saved = saveCurrent(as: name)
        resetCurrent()
        return saved
    }

    /// Eine aufgezeichnete Fahrt als Messreihe speichern
    func save(rows: [TripRow], name: String) {
        var s = TuningSession(name: name.isEmpty ? "Fahrt" : name)
        var steady = SteadyTracker()
        for r in rows {
            let calm = steady.push(t: r.t, rpm: r.rpm, map: r.map)
            s.add(SessionPoint(lambda: r.lambda.flatMap { $0 <= 2 ? $0 : nil }, rpm: r.rpm, map: r.map,
                               advance: r.advance, oilT: r.oilT, speed: r.speed, steady: calm))
        }
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
