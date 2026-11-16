import Foundation

// ── Beduesung und Logbuch ────────────────────────────────────────
// Was im Vergaser steckt, und was wann geaendert wurde. Zu jeder Aenderung
// merkt sich das Logbuch die Messreihe von davor. So laesst sich spaeter
// vergleichen, was ein Umbau gebracht hat.

struct CarbSetup: Codable, Equatable {
    var idleJet1: Double?        // Leerlaufduese Stufe 1
    var main1: Double?           // Hauptduese Stufe 1
    var air1: Double?            // Luftkorrekturduese Stufe 1
    var idleJet2: Double?        // Leerlauf-/Uebergangsduese Stufe 2
    var main2: Double?           // Hauptduese Stufe 2
    var air2: Double?            // Luftkorrekturduese Stufe 2
    var pumpJet: Double?         // Pumpenduese
    var needleValve: Double?     // Schwimmernadelventil
    var mixtureTurns: Double?    // Gemischschraube, Umdrehungen heraus
    var idleRPM: Double?         // eingestellte Leerlaufdrehzahl

    enum Field: String, CaseIterable, Identifiable {
        case idleJet1, main1, air1, idleJet2, main2, air2, pumpJet, needleValve, mixtureTurns, idleRPM

        var id: String { rawValue }

        var title: String {
            switch self {
            case .idleJet1:     return "Leerlaufdüse Stufe 1"
            case .main1:        return "Hauptdüse Stufe 1"
            case .air1:         return "Luftkorrekturdüse Stufe 1"
            case .idleJet2:     return "Leerlauf-/Übergangsdüse Stufe 2"
            case .main2:        return "Hauptdüse Stufe 2"
            case .air2:         return "Luftkorrekturdüse Stufe 2"
            case .pumpJet:      return "Pumpendüse"
            case .needleValve:  return "Schwimmernadelventil"
            case .mixtureTurns: return "Gemischschraube"
            case .idleRPM:      return "Leerlaufdrehzahl"
            }
        }

        var unit: String {
            switch self {
            case .mixtureTurns: return "Umdr. heraus"
            case .idleRPM:      return "U/min"
            default:            return ""
            }
        }

        var hint: String {
            switch self {
            case .mixtureTurns: return "z. B. 1,5"
            case .idleRPM:      return "z. B. 850"
            case .needleValve:  return "z. B. 1,5"
            default:            return "Nummer"
            }
        }

        /// Gruppe in der Ansicht
        var group: Int {
            switch self {
            case .idleJet1, .main1, .air1: return 0
            case .idleJet2, .main2, .air2: return 1
            default:                       return 2
            }
        }

        static let groupTitles = ["Stufe 1", "Stufe 2", "Sonstiges"]

        /// Vergaserkreis, dessen Duese der Duesen-Rechner unter "jet.<Kreis>" ablegt
        var circuit: CarbCircuit? {
            switch self {
            case .idleJet1: return .idle
            case .main1:    return .stage1
            case .idleJet2: return .transition
            case .main2:    return .stage2
            default:        return nil
            }
        }
    }

    subscript(f: Field) -> Double? {
        get {
            switch f {
            case .idleJet1:     return idleJet1
            case .main1:        return main1
            case .air1:         return air1
            case .idleJet2:     return idleJet2
            case .main2:        return main2
            case .air2:         return air2
            case .pumpJet:      return pumpJet
            case .needleValve:  return needleValve
            case .mixtureTurns: return mixtureTurns
            case .idleRPM:      return idleRPM
            }
        }
        set {
            let v = (newValue ?? 0) > 0 ? newValue : nil
            switch f {
            case .idleJet1:     idleJet1 = v
            case .main1:        main1 = v
            case .air1:         air1 = v
            case .idleJet2:     idleJet2 = v
            case .main2:        main2 = v
            case .air2:         air2 = v
            case .pumpJet:      pumpJet = v
            case .needleValve:  needleValve = v
            case .mixtureTurns: mixtureTurns = v
            case .idleRPM:      idleRPM = v
            }
        }
    }

    /// Duese eines Vergaserkreises (fuer die Rechnung im Gemisch-Check)
    func jet(_ c: CarbCircuit) -> Double? {
        switch c {
        case .idle:       return idleJet1
        case .stage1:     return main1
        case .transition: return idleJet2
        case .stage2:     return main2
        }
    }

    var jets: [CarbCircuit: Double] {
        var out: [CarbCircuit: Double] = [:]
        for c in CarbCircuit.allCases { if let j = jet(c) { out[c] = j } }
        return out
    }

    var isEmpty: Bool { Field.allCases.allSatisfy { self[$0] == nil } }

    static func text(_ v: Double?, _ f: Field) -> String {
        guard let v else { return "–" }
        let n = v == v.rounded() ? String(format: "%.0f", v)
            : String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",")
        return f.unit.isEmpty || f == .mixtureTurns ? n : n + " " + f.unit
    }

    /// "Hauptdüse Stufe 2: 85 → 90"
    static func changes(from old: CarbSetup, to new: CarbSetup) -> [String] {
        var out: [String] = []
        for f in Field.allCases where old[f] != new[f] {
            out.append(f.title + ": " + text(old[f], f) + " → " + text(new[f], f))
        }
        return out
    }

    /// Duesen, die der Duesen-Rechner bisher in den Einstellungen abgelegt hat
    static func fromDefaults(_ d: UserDefaults = .standard) -> CarbSetup {
        var s = CarbSetup()
        for f in Field.allCases {
            if let c = f.circuit {
                let v = d.double(forKey: "jet." + c.rawValue)
                if v > 0 { s[f] = v }
            }
        }
        return s
    }
}

struct LogEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var note = ""
    var changes: [String] = []           // was sich an der Beduesung geaendert hat
    var setup = CarbSetup()              // Stand nach der Aenderung
    var sessionID: UUID?                 // Messreihe von vor der Aenderung
    var sessionName: String?

    var title: String {
        if let first = changes.first {
            return changes.count == 1 ? first : first + " (+\(changes.count - 1))"
        }
        return note.isEmpty ? "Eintrag" : note
    }
}

struct CarbBook: Codable, Equatable {
    var setup = CarbSetup()
    var entries: [LogEntry] = []         // neueste zuerst

    /// Aenderung eintragen. Ohne Unterschied und ohne Notiz passiert nichts.
    @discardableResult
    mutating func commit(_ new: CarbSetup, note: String, session: (id: UUID, name: String)?,
                         date: Date = Date()) -> LogEntry? {
        let changes = CarbSetup.changes(from: setup, to: new)
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !changes.isEmpty || !text.isEmpty else { return nil }
        let e = LogEntry(date: date, note: text, changes: changes, setup: new,
                         sessionID: session?.id, sessionName: session?.name)
        setup = new
        entries.insert(e, at: 0)
        return e
    }
}

// ── Tankbuch ─────────────────────────────────────────────────────
// Verbrauch von Volltanken zu Volltanken. Die Strecke kommt vom
// Kilometerstand, wenn er eingetragen ist, sonst aus den GPS-Kilometern
// der aufgezeichneten Fahrten dazwischen.

struct FuelEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var liters: Double
    var odometer: Double?        // km
    var full = true              // vollgetankt
    var price: Double?           // Euro gesamt
    var note = ""
}

struct FuelResult: Equatable {
    var liters: Double           // seit dem letzten Volltanken
    var km: Double
    var gps: Bool                // Strecke aus den Fahrten statt vom Kilometerstand

    var per100: Double { liters / km * 100 }
}

enum FuelMath {
    /// Verbrauch je Volltank-Eintrag. `gpsKm` liefert die gefahrenen Kilometer zwischen zwei Zeitpunkten.
    static func results(_ entries: [FuelEntry], gpsKm: (Date, Date) -> Double) -> [UUID: FuelResult] {
        let sorted = entries.sorted { $0.date < $1.date }
        var out: [UUID: FuelResult] = [:]
        var lastFull: FuelEntry?
        var liters = 0.0
        for e in sorted {
            liters += e.liters
            guard e.full else { continue }
            if let prev = lastFull {
                var km: Double?
                var gps = false
                if let a = prev.odometer, let b = e.odometer, b > a {
                    km = b - a
                } else {
                    let g = gpsKm(prev.date, e.date)
                    if g >= 20 {
                        km = g
                        gps = true
                    }
                }
                if let k = km, k >= 20, liters > 0 {
                    out[e.id] = FuelResult(liters: liters, km: k, gps: gps)
                }
            }
            lastFull = e
            liters = 0
        }
        return out
    }

    /// Schnitt ueber alle auswertbaren Tankfuellungen
    static func average(_ r: [FuelResult]) -> Double? {
        let km = r.reduce(0) { $0 + $1.km }
        guard km > 0 else { return nil }
        return r.reduce(0) { $0 + $1.liters } / km * 100
    }
}
