import Foundation
import CoreLocation

// ── Fahrtenschreiber ─────────────────────────────────────────────
// Jede Fahrt = eine CSV (alle Werte, 4 Zeilen/s) plus eine JSON mit
// Zusammenfassung und Markierungen, beide in Dokumente/Fahrten.
// Die CSV nutzt ";" und Dezimalkomma, damit sie direkt in Excel aufgeht.

struct TripMarker: Codable, Hashable, Identifiable {
    var id: Int              // laufende Nummer 1, 2, 3 …
    var time: Date
    var note: String = ""
}

struct TripSummary: Codable, Hashable, Identifiable {
    var id: String           // Dateiname ohne Endung, z. B. 2026-10-14_10-05-12
    var start: Date
    var end: Date
    var distanceKm: Double = 0
    var maxSpeed: Double?
    var maxRPM: Double?
    var maxOilT: Double?
    var minOilPRunning: Double?      // nur bei laufendem Motor (ab 1200 U/min)
    var secondsOver5000: Double = 0
    var lambdaSum: Double = 0
    var lambdaCount: Int = 0
    var markers: [TripMarker] = []

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var avgLambda: Double? { lambdaCount > 0 ? lambdaSum / Double(lambdaCount) : nil }
    var avgSpeed: Double? {
        guard duration > 60, distanceKm > 0.1 else { return nil }
        return distanceKm / (duration / 3600)
    }
}

/// Eine Zeile der CSV, fuer die Auswertung
struct TripRow {
    var t: Double            // Sekunden seit Start
    var lambda: Double?
    var rpm: Double?
    var map: Double?
    var oilP: Double?
    var oilT: Double?
    var tank: Double?
    var advance: Double?
    var voltage: Double?
    var coil: Double?
    var moduleTemp: Double?
    var speed: Double?
    var lat: Double?
    var lon: Double?
    var marker: Int?
}

final class TripRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var current: TripSummary?      // laufende Fahrt, 1x/s aktualisiert
    @Published private(set) var trips: [TripSummary] = []  // abgeschlossene Fahrten, neueste zuerst

    private var work: TripSummary?
    private var handle: FileHandle?
    private var buffer = ""
    private var lastLocation: CLLocation?
    private var lastSampleTime: Date?
    private var pendingMarker: Int?
    private var lastPublish = Date.distantPast
    private var lastSave = Date.distantPast
    private var autoStarted = false
    private var hold = false                 // nach manuellem Stopp erst nach Motor-aus wieder automatisch
    private var activeSince: Date?
    private var inactiveSince: Date?

    static let header = "Zeit;Sekunden;Lambda;Drehzahl;Saugrohr_kPa;Oeldruck_bar;Oeltemp_C;Tank_Prozent;"
        + "Zuendwinkel_Grad;Bordnetz_V;Spule_A;Modul_C;Tempo_kmh;Breite;Laenge;Markierung\n"

    static let folder: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = docs.appendingPathComponent("Fahrten", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()

    private static let fileNameFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    private static let rowTimeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS"
        return f
    }()

    static func csvURL(_ id: String) -> URL { folder.appendingPathComponent(id + ".csv") }
    static func jsonURL(_ id: String) -> URL { folder.appendingPathComponent(id + ".json") }

    init() {
        loadTrips()
    }

    // ── Aufnahme ─────────────────────────────────────────────────
    func start(manual: Bool = true) {
        guard !isRecording else { return }
        let now = Date()
        let id = Self.fileNameFormat.string(from: now)
        let url = Self.csvURL(id)
        FileManager.default.createFile(atPath: url.path, contents: Data(Self.header.utf8))
        handle = try? FileHandle(forWritingTo: url)
        _ = handle?.seekToEndOfFile()
        work = TripSummary(id: id, start: now, end: now)
        current = work
        buffer = ""
        lastLocation = nil
        lastSampleTime = nil
        pendingMarker = nil
        lastSave = now
        autoStarted = !manual
        hold = false
        isRecording = true
        saveSummary()
    }

    func stop(manual: Bool = true) {
        guard isRecording else { return }
        flush()
        try? handle?.close()
        handle = nil
        isRecording = false
        if manual && activeSince != nil { hold = true }
        if let w = work {
            if w.duration < 10 && w.markers.isEmpty {
                // Mini-Aufnahmen verwerfen
                try? FileManager.default.removeItem(at: Self.csvURL(w.id))
                try? FileManager.default.removeItem(at: Self.jsonURL(w.id))
            } else {
                saveSummary()
            }
        }
        work = nil
        current = nil
        loadTrips()
    }

    /// Setzt eine Markierung und startet die Aufnahme, falls sie nicht laeuft. Gibt die Nummer zurueck.
    @discardableResult
    func addMarker() -> Int {
        if !isRecording { start(manual: true) }
        guard var w = work else { return 0 }
        let n = w.markers.count + 1
        w.markers.append(TripMarker(id: n, time: Date()))
        work = w
        current = w
        pendingMarker = n
        saveSummary()
        return n
    }

    /// Automatik: Start nach 5 s Motorlauf, Stopp nach 60 s Motor aus
    func autoCheck(engineRunning: Bool, enabled: Bool, now: Date) {
        if engineRunning {
            inactiveSince = nil
            if activeSince == nil { activeSince = now }
        } else {
            activeSince = nil
            if inactiveSince == nil { inactiveSince = now }
            hold = false
        }
        guard enabled else { return }
        if !isRecording, !hold, let a = activeSince, now.timeIntervalSince(a) >= 5 {
            start(manual: false)
        } else if isRecording, autoStarted, let i = inactiveSince, now.timeIntervalSince(i) >= 60 {
            stop(manual: false)
        }
    }

    /// Eine Zeile schreiben (alle 0,25 s)
    func record(_ s: Sample, location: CLLocation?) {
        guard isRecording, var w = work else { return }
        let dt = lastSampleTime.map { min(1, max(0, s.time.timeIntervalSince($0))) } ?? 0
        lastSampleTime = s.time

        if let l = location {
            if let p = lastLocation {
                let d = l.distance(from: p)
                if d < 200 { w.distanceKm += d / 1000 }    // Spruenge bei schlechtem Empfang ignorieren
            }
            lastLocation = l
        }
        if let v = s.speed { w.maxSpeed = max(w.maxSpeed ?? 0, v) }
        if let r = s.rpm {
            w.maxRPM = max(w.maxRPM ?? 0, r)
            if r >= Limits.rpmWarn { w.secondsOver5000 += dt }
        }
        if let t = s.oilT { w.maxOilT = max(w.maxOilT ?? -100, t) }
        if let p = s.oilP, (s.rpm ?? 0) >= 1200 { w.minOilPRunning = min(w.minOilPRunning ?? 99, p) }
        if let l = s.lambda {
            w.lambdaSum += l
            w.lambdaCount += 1
        }
        w.end = s.time
        work = w

        var cols: [String] = [
            Self.rowTimeFormat.string(from: s.time),
            Self.num(s.time.timeIntervalSince(w.start), 2),
            Self.num(s.lambda, 3),
            Self.num(s.rpm, 0),
            Self.num(s.mapKPa, 0),
            Self.num(s.oilP, 2),
            Self.num(s.oilT, 1),
            Self.num(s.tank, 0),
            Self.num(s.advance, 1),
            Self.num(s.voltage, 1),
            Self.num(s.coil, 2),
            Self.num(s.moduleTemp, 0),
            Self.num(s.speed, 1),
            Self.num(location?.coordinate.latitude, 6),
            Self.num(location?.coordinate.longitude, 6)
        ]
        if let m = pendingMarker {
            cols.append(String(m))
        } else {
            cols.append("")
        }
        pendingMarker = nil
        buffer += cols.joined(separator: ";") + "\n"
        if buffer.utf8.count > 8_000 { flush() }

        if s.time.timeIntervalSince(lastPublish) >= 1 {
            lastPublish = s.time
            current = w
        }
        if s.time.timeIntervalSince(lastSave) >= 30 {
            lastSave = s.time
            flush()
            saveSummary()
        }
    }

    /// Beim Wechsel in den Hintergrund alles auf die Platte schreiben
    func flushNow() {
        flush()
        saveSummary()
    }

    // ── Fahrten verwalten ────────────────────────────────────────
    func loadTrips() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        var list: [TripSummary] = []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let t = try? JSONDecoder().decode(TripSummary.self, from: d) else { continue }
            if t.id != work?.id { list.append(t) }
        }
        trips = list.sorted { $0.start > $1.start }
    }

    func delete(_ trip: TripSummary) {
        try? FileManager.default.removeItem(at: Self.csvURL(trip.id))
        try? FileManager.default.removeItem(at: Self.jsonURL(trip.id))
        loadTrips()
    }

    func setNote(_ note: String, marker: Int, trip id: String) {
        if var w = work, w.id == id {
            if let i = w.markers.firstIndex(where: { $0.id == marker }) { w.markers[i].note = note }
            work = w
            current = w
            saveSummary()
            return
        }
        guard let ti = trips.firstIndex(where: { $0.id == id }) else { return }
        var t = trips[ti]
        if let i = t.markers.firstIndex(where: { $0.id == marker }) { t.markers[i].note = note }
        trips[ti] = t
        if let data = try? JSONEncoder().encode(t) {
            try? data.write(to: Self.jsonURL(id), options: .atomic)
        }
    }

    /// CSV einer Fahrt einlesen (laeuft im Hintergrund)
    static func loadRows(_ id: String) -> [TripRow] {
        guard let text = try? String(contentsOf: csvURL(id), encoding: .utf8) else { return [] }
        var rows: [TripRow] = []
        var first = true
        for line in text.split(separator: "\n") {
            if first { first = false; continue }
            let c = line.split(separator: ";", omittingEmptySubsequences: false)
            guard c.count >= 16 else { continue }
            func d(_ k: Int) -> Double? { Double(c[k].replacingOccurrences(of: ",", with: ".")) }
            guard let t = d(1) else { continue }
            rows.append(TripRow(t: t, lambda: d(2), rpm: d(3), map: d(4), oilP: d(5), oilT: d(6),
                                tank: d(7), advance: d(8), voltage: d(9), coil: d(10), moduleTemp: d(11),
                                speed: d(12), lat: d(13), lon: d(14), marker: Int(String(c[15]))))
        }
        return rows
    }

    // ── intern ───────────────────────────────────────────────────
    private func flush() {
        guard !buffer.isEmpty, let h = handle else { return }
        h.write(Data(buffer.utf8))
        buffer = ""
    }

    private func saveSummary() {
        guard let w = work, let data = try? JSONEncoder().encode(w) else { return }
        try? data.write(to: Self.jsonURL(w.id), options: .atomic)
    }

    private static func num(_ v: Double?, _ digits: Int) -> String {
        guard let v else { return "" }
        return String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }
}
