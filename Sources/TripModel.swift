import Foundation

// ── Fahrten: Datenmodell und CSV ─────────────────────────────────
// Gemeinsam fuer iPhone und Mac. Jede Fahrt = eine CSV (alle Werte, 4 Zeilen/s)
// plus eine JSON mit Zusammenfassung und Markierungen. Die CSV nutzt ";" und
// Dezimalkomma, damit sie direkt in Excel aufgeht.

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

enum TripCSV {
    /// Zeilen einer Fahrt-CSV. Unlesbare Zeilen werden uebersprungen.
    static func parse(_ text: String) -> [TripRow] {
        var rows: [TripRow] = []
        var first = true
        for line in text.split(separator: "\n") {
            if first { first = false; continue }
            let c = line.split(separator: ";", omittingEmptySubsequences: false)
            guard c.count >= 16 else { continue }
            func d(_ k: Int) -> Double? {
                let s = c[k].trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : Double(s.replacingOccurrences(of: ",", with: "."))
            }
            guard let t = d(1) else { continue }
            rows.append(TripRow(t: t, lambda: d(2), rpm: d(3), map: d(4), oilP: d(5), oilT: d(6),
                                tank: d(7), advance: d(8), voltage: d(9), coil: d(10), moduleTemp: d(11),
                                speed: d(12), lat: d(13), lon: d(14),
                                marker: Int(c[15].trimmingCharacters(in: .whitespacesAndNewlines))))
        }
        return rows
    }
}

extension TripRow {
    /// Lambda nur, wenn die Sonde bereit war (4.5 = nicht bereit)
    var lambdaValid: Double? { lambda.flatMap { $0 <= 2 && $0 > 0.5 ? $0 : nil } }

    /// Als Messwert fuer die Erkenner (Zuege, Gasstoesse, Warnungen)
    func sample(start: Date) -> Sample {
        Sample(time: start.addingTimeInterval(t), lambda: lambdaValid, rpm: rpm, mapKPa: map,
               oilP: oilP, oilT: oilT, tank: tank, advance: advance, voltage: voltage, coil: coil,
               moduleTemp: moduleTemp, speed: speed)
    }
}

extension TuningSession {
    /// Zeilen einer Fahrt einrechnen. Ruhige Fahrt wird wie live erkannt,
    /// je Fahrt mit eigenem Zaehler.
    mutating func add(rows: [TripRow]) {
        var steady = SteadyTracker()
        var lastT = -1.0
        for r in rows {
            // Luecke in der Aufzeichnung: ruhige Fahrt neu beginnen
            if r.t - lastT > 2 { steady.reset() }
            lastT = r.t
            let calm = steady.push(t: r.t, rpm: r.rpm, map: r.map)
            add(SessionPoint(lambda: r.lambdaValid, rpm: r.rpm, map: r.map, advance: r.advance,
                             oilT: r.oilT, speed: r.speed, steady: calm))
        }
    }

    /// Messreihe aus einer oder mehreren Fahrten
    static func from(rows: [TripRow], name: String) -> TuningSession {
        var s = TuningSession(name: name)
        s.add(rows: rows)
        return s
    }
}
