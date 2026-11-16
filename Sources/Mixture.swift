import Foundation

// ── Gemisch: Betriebsbereiche, Ziel-Lambda, Bewertung ────────────
// Ein Vergasermotor soll nicht ueberall Lambda 1 fahren: im Leerlauf und
// bei Vollgas fetter, in der Teillast um 1. Darum bewertet die App Lambda
// gegen ein Ziel je Betriebsbereich. Die Bereiche werden aus Drehzahl und
// Saugrohrdruck der 123 geschaetzt; die Zuordnung zu den Kreisen des
// Registervergasers ist grob.

/// Kreise des Registervergasers (Solex 26/35), grob nach Kennfeld-Zelle
enum CarbCircuit: String, CaseIterable, Identifiable, Codable {
    case idle, stage1, transition, stage2

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle:       return "Leerlauf"
        case .stage1:     return "Teillast · Stufe 1"
        case .transition: return "Übergang zu Stufe 2"
        case .stage2:     return "Last und Vollgas · Stufe 2"
        }
    }

    var jetName: String {
        switch self {
        case .idle:       return "Leerlaufdüse Stufe 1"
        case .stage1:     return "Hauptdüse Stufe 1"
        case .transition: return "Leerlauf-/Übergangsdüse Stufe 2"
        case .stage2:     return "Hauptdüse Stufe 2"
        }
    }

    var area: String {
        switch self {
        case .idle:       return "um 1000 U/min, 30–70 kPa"
        case .stage1:     return "30–70 kPa, dazu 70–90 kPa unter 2250 U/min"
        case .transition: return "70–90 kPa bei 2250–3750 U/min"
        case .stage2:     return "ab 90 kPa, dazu 70–90 kPa ab 3750 U/min"
        }
    }

    var defaultTarget: Double { MixtureTargets.defaults[self] }

    /// Zeile 0 = 20–30 kPa (Schub, keinem Kreis zugeordnet), Spalte 0 = 1000 U/min
    func contains(row: Int, col: Int) -> Bool {
        Regime.of(row: row, col: col).circuit == self
    }

    static func of(row: Int, col: Int) -> CarbCircuit? {
        Regime.of(row: row, col: col).circuit
    }
}

/// Betriebsbereich des Motors
enum Regime: String, CaseIterable, Identifiable, Codable {
    case idle, cruise, transition, fullLow, fullHigh, overrun

    var id: String { rawValue }

    static let overrunKPa = 30.0        // darunter Schiebebetrieb
    static let idleMaxRPM = 1450.0
    static let idleMaxKPa = 70.0
    static let loadKPa = 70.0           // ab hier oeffnet die zweite Stufe
    static let fullKPa = 90.0           // ab hier Vollgas
    static let fullSplitRPM = 3500.0    // Vollgas "unten" / "oben"

    var title: String {
        switch self {
        case .idle:       return "Leerlauf"
        case .cruise:     return "Teillast"
        case .transition: return "Übergang"
        case .fullLow:    return "Vollgas unten"
        case .fullHigh:   return "Vollgas oben"
        case .overrun:    return "Schiebebetrieb"
        }
    }

    var area: String {
        switch self {
        case .idle:       return "unter 1450 U/min, 30–70 kPa"
        case .cruise:     return "30–70 kPa, dazu 70–90 kPa unter 2250 U/min"
        case .transition: return "70–90 kPa bei 2250–3750 U/min"
        case .fullLow:    return "ab 90 kPa unter 3500 U/min"
        case .fullHigh:   return "ab 90 kPa ab 3500 U/min, dazu 70–90 kPa ab 3750 U/min"
        case .overrun:    return "unter 30 kPa"
        }
    }

    var circuit: CarbCircuit? {
        switch self {
        case .idle:               return .idle
        case .cruise:             return .stage1
        case .transition:         return .transition
        case .fullLow, .fullHigh: return .stage2
        case .overrun:            return nil
        }
    }

    var isFull: Bool { self == .fullLow || self == .fullHigh }

    static func of(rpm: Double, kPa: Double) -> Regime {
        if kPa < overrunKPa { return .overrun }
        if rpm < idleMaxRPM && kPa < idleMaxKPa { return .idle }
        if kPa >= fullKPa { return rpm < fullSplitRPM ? .fullLow : .fullHigh }
        if kPa >= loadKPa {
            if rpm < 2250 { return .cruise }
            if rpm < 3750 { return .transition }
            return .fullHigh
        }
        return .cruise
    }

    /// Bereich einer Kennfeld-Zelle (nach deren Mitte)
    static func of(row: Int, col: Int) -> Regime {
        of(rpm: TuningSession.colCenter(col), kPa: TuningSession.rowLow(row) + 5)
    }
}

/// Ziel-Lambda je Vergaserkreis. Liegt in den Einstellungen unter
/// "target.<Kreis>", dieselben Schluessel nutzt der Duesen-Rechner.
struct MixtureTargets: Equatable {
    var idle = 0.95
    var stage1 = 1.00
    var transition = 0.95
    var stage2 = 0.88

    static let defaults = MixtureTargets()
    static let range = 0.75...1.15

    subscript(c: CarbCircuit) -> Double {
        get {
            switch c {
            case .idle:       return idle
            case .stage1:     return stage1
            case .transition: return transition
            case .stage2:     return stage2
            }
        }
        set {
            let v = min(Self.range.upperBound, max(Self.range.lowerBound, newValue))
            switch c {
            case .idle:       idle = v
            case .stage1:     stage1 = v
            case .transition: transition = v
            case .stage2:     stage2 = v
            }
        }
    }

    func target(_ r: Regime) -> Double? { r.circuit.map { self[$0] } }

    func target(rpm: Double, kPa: Double) -> Double? { target(Regime.of(rpm: rpm, kPa: kPa)) }

    static func key(_ c: CarbCircuit) -> String { "target." + c.rawValue }

    static func load(from d: UserDefaults = .standard) -> MixtureTargets {
        var t = MixtureTargets()
        for c in CarbCircuit.allCases {
            if let v = d.object(forKey: key(c)) as? Double, range.contains(v) { t[c] = v }
        }
        return t
    }

    func save(to d: UserDefaults = .standard) {
        for c in CarbCircuit.allCases { d.set(self[c], forKey: Self.key(c)) }
    }
}

/// Einstufung, unabhaengig von der Oberflaeche
enum Severity: Int, Comparable, Codable {
    case none = 0      // keine Aussage (zu wenig Daten)
    case info = 1      // nur zur Kenntnis
    case ok = 2
    case warn = 3
    case crit = 4

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

struct MixtureJudgement: Equatable {
    var severity: Severity
    var text: String             // "passt", "leicht fett" …
    var regime: Regime?
    var target: Double?
    var deviation: Double?       // Lambda minus Ziel; + = magerer als gewollt
}

enum MixtureJudge {
    /// So weit darf Lambda vom Ziel weg sein und gilt noch als passend
    static func tolerance(_ r: Regime) -> Double {
        switch r {
        case .idle, .transition: return 0.045
        case .cruise:            return 0.035
        default:                 return 0.04
        }
    }

    static let wide = 0.09       // bis hierhin "leicht", danach deutlich daneben

    static func judge(lambda: Double, regime: Regime, targets: MixtureTargets) -> MixtureJudgement {
        guard let t = targets.target(regime) else {
            return MixtureJudgement(severity: .info, text: "Schub", regime: regime, target: nil, deviation: nil)
        }
        let d = lambda - t
        func make(_ s: Severity, _ text: String) -> MixtureJudgement {
            MixtureJudgement(severity: s, text: text, regime: regime, target: t, deviation: d)
        }
        // Mager unter Vollgas ist das, was dem Motor schadet
        if regime.isFull && lambda >= 1.0 { return make(.crit, "zu mager") }
        if abs(d) <= tolerance(regime) { return make(.ok, "passt") }
        if d > 0 {
            return abs(d) <= wide ? make(.warn, "leicht mager") : make(.crit, "mager")
        }
        if abs(d) <= wide { return make(.warn, "leicht fett") }
        // fett bei Vollgas kostet nur Leistung
        if regime.isFull && abs(d) <= 0.14 { return make(.warn, "fett") }
        return make(.crit, "fett")
    }

    /// Bewertung des aktuellen Werts; nil ohne Drehzahl/Last (dann gelten die festen Zonen um 1,00)
    static func live(lambda: Double?, rpm: Double?, kPa: Double?, targets: MixtureTargets) -> MixtureJudgement? {
        guard let l = lambda, l <= 2, let r = rpm, r >= 300, let k = kPa else { return nil }
        return judge(lambda: l, regime: Regime.of(rpm: r, kPa: k), targets: targets)
    }
}

// ── Duesen ───────────────────────────────────────────────────────
// Durch eine Duese fliesst grob proportional zu ihrem Querschnitt Sprit,
// also zum Quadrat des Durchmessers. Duesennummern sind beim Solex/Weber
// der Durchmesser in 1/100 mm. Daraus:  d_neu ≈ d_alt × √(λ_ist / λ_soll)
// Beispiel: Hauptduese 115 bei λ 0,97, Ziel 1,00  →  etwa 113.
// Faustregel: Luftkorrektur, Schwimmerstand und Zuendung spielen mit.
enum JetMath {
    /// Neue Duesengroesse; nil, wenn eine Angabe fehlt
    static func newSize(old: Double, lambdaNow: Double, lambdaTarget: Double) -> Double? {
        guard old > 0, lambdaNow > 0, lambdaTarget > 0 else { return nil }
        return old * (lambdaNow / lambdaTarget).squareRoot()
    }

    /// So viel Prozent mehr (+) oder weniger (−) Kraftstoff braucht es bis zum Ziel
    static func fuelPercent(lambdaNow: Double, lambdaTarget: Double) -> Double {
        guard lambdaTarget > 0 else { return 0 }
        return (lambdaNow / lambdaTarget - 1) * 100
    }
}

struct JetAdvice: Equatable {
    var circuit: CarbCircuit
    var old: Double?             // eingetragene Duese, nil = unbekannt
    var new: Double?             // rechnerisch
    var fuelPercent: Double      // + = mehr Kraftstoff noetig

    static func make(circuit: CarbCircuit, lambdaNow: Double, lambdaTarget: Double, jet: Double?) -> JetAdvice {
        let old = (jet ?? 0) > 0 ? jet : nil
        return JetAdvice(circuit: circuit, old: old,
                         new: old.flatMap { JetMath.newSize(old: $0, lambdaNow: lambdaNow, lambdaTarget: lambdaTarget) },
                         fuelPercent: JetMath.fuelPercent(lambdaNow: lambdaNow, lambdaTarget: lambdaTarget))
    }

    /// "von 85 auf 88" oder "etwa 6 % mehr Kraftstoff, also die Düse rund 3 % größer"
    var text: String {
        if let o = old, let n = new {
            if abs(n - o) < 0.5 { return "\(circuit.jetName) \(Self.num(o)) passt rechnerisch" }
            return "\(circuit.jetName): rechnerisch von \(Self.num(o)) auf \(Self.num(n.rounded()))"
        }
        let p = abs(fuelPercent)
        let dir = fuelPercent > 0 ? "mehr" : "weniger"
        let size = fuelPercent > 0 ? "größer" : "kleiner"
        return circuit.jetName + ": etwa " + String(format: "%.0f", p) + " % " + dir
            + " Kraftstoff, also rund " + String(format: "%.0f", p / 2) + " % " + size + " im Durchmesser"
    }

    static func num(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}
