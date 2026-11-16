import Foundation

// ── Warnungen waehrend der Fahrt ─────────────────────────────────
// Prueft alle 0,25 s die Werte. Eine Warnung kommt erst, wenn die
// Bedingung eine Weile anhaelt, und geht erst wieder, wenn sie eine Weile
// weg ist. So flackert nichts. Jede neue Warnung wird einmal gemeldet
// (Vibration, Ton, Markierung in der Fahrt), danach fruehestens nach 60 s
// wieder.

enum AlertKind: String, CaseIterable, Identifiable, Codable {
    case oilPressure, oilTemp, leanLoad, overRev, voltageLow, voltageHigh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oilPressure: return "Öldruck zu niedrig"
        case .oilTemp:     return "Öl zu heiß"
        case .leanLoad:    return "Mager unter Last"
        case .overRev:     return "Drehzahl zu hoch"
        case .voltageLow:  return "Lichtmaschine lädt nicht"
        case .voltageHigh: return "Bordspannung zu hoch"
        }
    }

    /// Fuer die Einstellungen
    var explanation: String {
        switch self {
        case .oilPressure: return "unter 1.0 bar ab 1500 U/min, länger als 2 s"
        case .oilTemp:     return "ab 145 °C"
        case .leanLoad:    return "Lambda ab 1.05 bei viel Gas ab 2500 U/min, länger als 2 s"
        case .overRev:     return "ab 5750 U/min"
        case .voltageLow:  return "unter 12.4 V bei laufendem Motor, länger als 10 s"
        case .voltageHigh: return "über 15.2 V"
        }
    }

    var advice: String {
        switch self {
        case .oilPressure: return "Gas weg, anhalten, Ölstand prüfen."
        case .oilTemp:     return "Last rausnehmen, ruhiger fahren."
        case .leanLoad:    return "Gas zurücknehmen. Mager unter Last macht den Motor heiß."
        case .overRev:     return "Hochschalten."
        case .voltageLow:  return "Regler, Keilriemen und Kabel prüfen."
        case .voltageHigh: return "Regler prüfen."
        }
    }

    var severity: Severity {
        switch self {
        case .oilPressure, .oilTemp, .leanLoad: return .crit
        case .overRev, .voltageLow, .voltageHigh: return .warn
        }
    }

    /// So lange muss die Bedingung anhalten (Sekunden)
    var raiseAfter: Double {
        switch self {
        case .oilPressure, .leanLoad: return 2
        case .oilTemp:                return 3
        case .overRev:                return 0.5
        case .voltageLow:             return 10
        case .voltageHigh:            return 3
        }
    }

    var clearAfter: Double { self == .overRev ? 1 : 3 }

    static func key(_ k: AlertKind) -> String { "alert." + k.rawValue }
}

struct AlertSettings: Equatable {
    var enabled: Set<AlertKind> = Set(AlertKind.allCases)
    var sound = true

    static let soundKey = "alert.sound"

    static func load(from d: UserDefaults = .standard) -> AlertSettings {
        var s = AlertSettings()
        for k in AlertKind.allCases where (d.object(forKey: AlertKind.key(k)) as? Bool) == false {
            s.enabled.remove(k)
        }
        s.sound = d.object(forKey: soundKey) as? Bool ?? true
        return s
    }
}

struct ActiveAlert: Identifiable, Equatable {
    var kind: AlertKind
    var since: Date
    var detail: String           // "0,6 bar bei 2400 U/min"

    var id: String { kind.rawValue }
}

struct AlertMonitor {
    static let renotify = 60.0

    private struct Track {
        var trueSince: Date?
        var falseSince: Date?
        var active = false
        var lastNotified = Date.distantPast
    }

    private var tracks: [AlertKind: Track] = [:]
    private(set) var active: [ActiveAlert] = []

    /// Wichtigste aktive Warnung
    var top: ActiveAlert? {
        active.max { ($0.kind.severity, $1.since) < ($1.kind.severity, $0.since) }
    }

    mutating func reset() {
        tracks = [:]
        active = []
    }

    /// Bedingung je Warnung: (trifft zu, Detailtext). nil = Wert fehlt.
    static func condition(_ k: AlertKind, _ s: Sample) -> (Bool, String)? {
        func f(_ v: Double, _ d: Int) -> String {
            String(format: "%.\(d)f", v)
        }
        switch k {
        case .oilPressure:
            guard let p = s.oilP, let r = s.rpm else { return nil }
            return (p < 1.0 && r >= 1500, f(p, 1) + " bar bei " + f(r, 0) + " U/min")
        case .oilTemp:
            guard let t = s.oilT else { return nil }
            return (t >= 145, f(t, 0) + " °C")
        case .leanLoad:
            guard let l = s.lambda, let r = s.rpm, let m = s.mapKPa else { return nil }
            return (l >= 1.05 && m >= 80 && r >= 2500, "λ " + f(l, 2) + " bei " + f(r, 0) + " U/min")
        case .overRev:
            guard let r = s.rpm else { return nil }
            return (r >= 5750, f(r, 0) + " U/min")
        case .voltageLow:
            guard let v = s.voltage, let r = s.rpm else { return nil }
            return (v < 12.4 && r >= 1500, f(v, 1) + " V")
        case .voltageHigh:
            guard let v = s.voltage else { return nil }
            return (v > 15.2, f(v, 1) + " V")
        }
    }

    /// Gibt die Warnungen zurueck, die gerade neu dazugekommen sind
    mutating func update(_ s: Sample, settings: AlertSettings) -> [ActiveAlert] {
        var raised: [ActiveAlert] = []
        for k in AlertKind.allCases {
            var t = tracks[k] ?? Track()
            let c = settings.enabled.contains(k) ? Self.condition(k, s) : nil
            let on = c?.0 ?? false
            if on {
                t.falseSince = nil
                if t.trueSince == nil { t.trueSince = s.time }
                if !t.active, let since = t.trueSince, s.time.timeIntervalSince(since) >= k.raiseAfter {
                    t.active = true
                    let a = ActiveAlert(kind: k, since: s.time, detail: c?.1 ?? "")
                    active.append(a)
                    if s.time.timeIntervalSince(t.lastNotified) >= Self.renotify {
                        t.lastNotified = s.time
                        raised.append(a)
                    }
                } else if t.active, let i = active.firstIndex(where: { $0.kind == k }) {
                    active[i].detail = c?.1 ?? active[i].detail
                }
            } else {
                t.trueSince = nil
                if t.falseSince == nil { t.falseSince = s.time }
                if t.active, let since = t.falseSince, s.time.timeIntervalSince(since) >= k.clearAfter {
                    t.active = false
                    active.removeAll { $0.kind == k }
                }
            }
            tracks[k] = t
        }
        return raised
    }
}

// ── Bewertung von Oeldruck und Bordnetz je nach Motorlauf ────────
// Bei stehendem Motor sind 0 bar und 12 V normal und sollen nicht rot sein.
enum ContextJudge {
    /// `running`: true/false, nil = unbekannt (keine 123 verbunden)
    static func pressure(_ p: Double, rpm: Double?) -> (Severity, String) {
        if p < 0 { return (.none, "Sensor / Kabel prüfen") }
        guard let r = rpm else {
            if p < 1.0 { return (.crit, "zu niedrig") }
            if p < 2.0 { return (.warn, "niedrig") }
            return (.ok, "normal")
        }
        if r < 300 { return (.info, "Motor steht") }
        if r < 1500 {
            // warmes Oel im Leerlauf: wenig Druck ist normal
            if p < 0.5 { return (.crit, "zu niedrig") }
            if p < 1.0 { return (.warn, "niedrig (Leerlauf)") }
            return (.ok, "normal")
        }
        if p < 1.0 { return (.crit, "zu niedrig") }
        if p < 2.0 { return (.warn, "niedrig") }
        return (.ok, "normal")
    }

    static func voltage(_ v: Double, rpm: Double?) -> (Severity, String) {
        if v > 15.2 { return (.crit, "zu hoch") }
        if v > 14.8 { return (.warn, "hoch") }
        if let r = rpm, r < 300 {
            if v < 11.6 { return (.crit, "Batterie leer") }
            if v < 12.1 { return (.warn, "Batterie schwach") }
            return (.info, "Motor steht")
        }
        if v < 11.8 { return (.crit, "niedrig") }
        if v < 12.4 { return (.warn, "lädt nicht?") }
        if (rpm ?? 0) >= 1500 && v < 13.2 { return (.warn, "lädt schwach") }
        return (.ok, rpm == nil ? "" : "lädt")
    }
}
