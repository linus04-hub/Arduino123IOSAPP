import Foundation
import CoreLocation

// ── Fahrtenschreiber ─────────────────────────────────────────────
// Jede Fahrt = eine CSV (alle Werte, 4 Zeilen/s) plus eine JSON mit
// Zusammenfassung und Markierungen, beide in Dokumente/Fahrten.
// Die CSV nutzt ";" und Dezimalkomma, damit sie direkt in Excel aufgeht.

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
    func addMarker(note: String = "") -> Int {
        if !isRecording { start(manual: true) }
        guard var w = work else { return 0 }
        let n = w.markers.count + 1
        w.markers.append(TripMarker(id: n, time: Date(), note: note))
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

        // Strecke nur aus neuen GPS-Punkten und nur in Bewegung. Im Stand wandert
        // die Position um ein paar Meter, das wuerde sich sonst zu Kilometern summieren.
        if let l = location, l.timestamp != lastLocation?.timestamp {
            if let p = lastLocation {
                let d = l.distance(from: p)
                let dt = l.timestamp.timeIntervalSince(p.timestamp)
                let moving = l.speed >= 1.4 || (l.speed < 0 && d > max(15, l.horizontalAccuracy))
                // Spruenge bei schlechtem Empfang ignorieren (mehr als 180 km/h)
                if moving, dt > 0, dt <= 120, d <= 50 * dt { w.distanceKm += d / 1000 }
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
        return TripCSV.parse(text)
    }

    // ── intern ───────────────────────────────────────────────────
    private func flush() {
        guard !buffer.isEmpty, let h = handle else { return }
        do {
            try h.write(contentsOf: Data(buffer.utf8))
            buffer = ""
        } catch {
            // Speicher voll oder Datei weg: Zeilen behalten und spaeter noch einmal versuchen,
            // aber nicht unbegrenzt sammeln
            if buffer.utf8.count > 400_000 { buffer = "" }
        }
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
