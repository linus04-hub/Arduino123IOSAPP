import Foundation

// ── Gemisch-Check: was sagt die Messreihe ueber den Vergaser? ────
// Wertet das Lambda-Kennfeld je Betriebsbereich gegen das Ziel-Lambda
// aus und macht daraus Befunde: Wert, Einstufung, Belege, wahrscheinliche
// Ursachen und was zu tun ist. Gerechnet wird, wenn vorhanden, nur mit
// ruhiger Fahrt bei warmem Motor. Die Regeln sind Werkstatt-Faustregeln
// fuer einen Registervergaser, keine Messung am Pruefstand.

enum DiagArea: String, CaseIterable, Identifiable {
    case idle, cruise, transition, fullLow, fullHigh, tipIn, warmup, overrun

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle:       return "Leerlauf"
        case .cruise:     return "Teillast"
        case .transition: return "Übergang zur 2. Stufe"
        case .fullLow:    return "Vollgas unten"
        case .fullHigh:   return "Vollgas oben"
        case .tipIn:      return "Gasstoß"
        case .warmup:     return "Kaltlauf"
        case .overrun:    return "Schiebebetrieb"
        }
    }

    var symbol: String {
        switch self {
        case .idle:       return "tortoise.fill"
        case .cruise:     return "road.lanes"
        case .transition: return "arrow.triangle.branch"
        case .fullLow:    return "gauge.with.dots.needle.33percent"
        case .fullHigh:   return "gauge.with.dots.needle.67percent"
        case .tipIn:      return "waveform.path.ecg"
        case .warmup:     return "thermometer.snowflake"
        case .overrun:    return "arrow.down.right"
        }
    }

    var regime: Regime? {
        switch self {
        case .idle:       return .idle
        case .cruise:     return .cruise
        case .transition: return .transition
        case .fullLow:    return .fullLow
        case .fullHigh:   return .fullHigh
        case .overrun:    return .overrun
        case .tipIn, .warmup: return nil
        }
    }

    /// Diese stehen immer in der Uebersicht, die uebrigen nur mit Daten
    static let main: [DiagArea] = [.idle, .cruise, .transition, .fullLow, .fullHigh, .tipIn]
}

enum DiagTool: Equatable {
    case idleAssistant
    case jetCalc(CarbCircuit)
    case tipIns
    case pulls
}

struct RPMValue: Identifiable, Equatable {
    var rpm: Double
    var lambda: Double
    var count: Int
    var id: Double { rpm }
}

struct Finding: Identifiable {
    var area: DiagArea
    var severity: Severity = .none
    var value = ""               // "λ 1.09"
    var verdict = ""             // "zu mager"
    var lambda: Double?
    var target: Double?
    var seconds = 0.0            // Messzeit in diesem Bereich
    var preliminary = false      // erst wenig Daten
    var summary = ""
    var evidence: [String] = []
    var causes: [String] = []
    var actions: [String] = []
    var jet: JetAdvice?
    var tool: DiagTool?
    var byRPM: [RPMValue] = []
    var spread: Double?

    var id: String { area.rawValue }
}

struct TipInSummary: Equatable {
    var count = 0
    var lean = 0
    var rich = 0
    var ok = 0
    var avgLeanSpike = 0.0
}

struct PullSummary: Equatable {
    var count = 0
    var leanTop = 0              // Zuege, die oben mager werden
    var starving = 0             // Zuege, bei denen Lambda mit der Zeit wegläuft
}

struct DiagnosisInput {
    var session: TuningSession
    var targets = MixtureTargets()
    var jets: [CarbCircuit: Double] = [:]
    var idleTargetRPM = 850.0
    var tipIns: TipInSummary?
    var pulls: PullSummary?
}

struct Diagnosis {
    var findings: [Finding] = []
    var headline = ""
    var plan: [String] = []
    var seconds = 0.0            // ausgewertete Messzeit
    var steady = false           // nur ruhige Fahrt ausgewertet
    var worst: Severity = .none

    func finding(_ a: DiagArea) -> Finding? { findings.first { $0.area == a } }
}

enum MixtureDiagnosis {
    static let minSamples = 40           // 10 s: ab hier gibt es ein Urteil
    static let fewSamples = 12           // darunter keine Aussage
    static let step = 0.25               // Sekunden je Messwert

    // ── Daten je Bereich ──
    struct Bucket {
        var sum = 0.0
        var n = 0
        var vSum = 0.0
        var vSq = 0.0
        var vN = 0
        var cols: [Int: (sum: Double, n: Int)] = [:]

        var mean: Double? { n > 0 ? sum / Double(n) : nil }

        var spread: Double? {
            guard vN >= 8 else { return nil }
            let k = Double(vN)
            let m = vSum / k
            return max(0, vSq / k - m * m).squareRoot()
        }

        mutating func add(_ c: TuneCell, col: Int) {
            sum += c.sum
            n += c.count
            vSum += c.vSum
            vSq += c.vSq
            vN += c.vCount
            let old = cols[col] ?? (0, 0)
            cols[col] = (old.sum + c.sum, old.n + c.count)
        }

        var byRPM: [RPMValue] {
            cols.keys.sorted().compactMap { c in
                guard let v = cols[c], v.n >= 8 else { return nil }
                return RPMValue(rpm: TuningSession.colCenter(c), lambda: v.sum / Double(v.n), count: v.n)
            }
        }

        /// Aenderung von Lambda je 1000 U/min (gewichtete Ausgleichsgerade), nil bei zu schmalem Bereich
        var slope: Double? {
            let pts = byRPM
            guard pts.count >= 3, let lo = pts.first?.rpm, let hi = pts.last?.rpm, hi - lo >= 1000 else { return nil }
            var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for p in pts {
                let w = Double(p.count)
                let x = p.rpm / 1000
                sw += w
                sx += w * x
                sy += w * p.lambda
                sxx += w * x * x
                sxy += w * x * p.lambda
            }
            let den = sw * sxx - sx * sx
            guard den > 1e-9 else { return nil }
            return (sw * sxy - sx * sy) / den
        }
    }

    static func collect(_ s: TuningSession, steady: Bool) -> [Regime: Bucket] {
        let grid = s.cells(steady: steady)
        var out: [Regime: Bucket] = [:]
        for r in 0..<TuningSession.rows {
            for c in 0..<TuningSession.cols where grid[r][c].count >= TuningSession.minCount {
                let regime = Regime.of(row: r, col: c)
                var b = out[regime] ?? Bucket()
                b.add(grid[r][c], col: c)
                out[regime] = b
            }
        }
        return out
    }

    private static func f2(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func f3(_ v: Double) -> String { String(format: "%.3f", v) }
    private static func f0(_ v: Double) -> String { String(format: "%.0f", v) }

    private static func timeText(_ seconds: Double) -> String {
        seconds < 90 ? f0(seconds) + " s" : f0(seconds / 60) + " min"
    }

    // ── Auswertung ──
    static func run(_ input: DiagnosisInput) -> Diagnosis {
        let s = input.session
        let steady = s.hasSteady
        let buckets = collect(s, steady: steady)
        var d = Diagnosis()
        d.steady = steady
        d.seconds = Double(steady ? s.steadyCount : s.lambdaCount) * step

        func dev(_ r: Regime) -> Double? {
            guard let b = buckets[r], b.n >= fewSamples, let m = b.mean, let t = input.targets.target(r) else { return nil }
            return m - t
        }
        let cruiseDev = dev(.cruise)
        let fullHighDev = dev(.fullHigh)
        let fullLowDev = dev(.fullLow)

        var idle = idleFinding(input, bucket: buckets[.idle], cruiseRich: (cruiseDev ?? 0) < -0.04)
        var cruise = cruiseFinding(input, bucket: buckets[.cruise],
                                   fullLean: (fullHighDev ?? 0) > 0.04 || (fullLowDev ?? 0) > 0.04)
        var transition = transitionFinding(input, bucket: buckets[.transition])
        var fullLow = fullFinding(input, area: .fullLow, bucket: buckets[.fullLow], otherDev: fullHighDev)
        var fullHigh = fullFinding(input, area: .fullHigh, bucket: buckets[.fullHigh], otherDev: fullLowDev)
        let tip = tipInFinding(input.tipIns)

        // Muster ueber alle Bereiche
        let devs = [dev(.idle), cruiseDev, dev(.transition), fullLowDev, fullHighDev].compactMap { $0 }
        var global: String?
        if devs.count >= 3 {
            if devs.allSatisfy({ $0 < -0.05 }) {
                global = "Überall zu fett: Das liegt selten an einer einzelnen Düse. Zuerst Schwimmerstand, Schwimmernadelventil, Choke und Luftfilter prüfen."
            } else if devs.allSatisfy({ $0 > 0.05 }) {
                global = "Überall zu mager: Zuerst Falschluft, Schwimmerstand und Benzinversorgung (Pumpe, Filter) prüfen, erst dann Düsen tauschen."
            }
        }
        if let g = global {
            for i in [0, 1, 2, 3, 4] {
                switch i {
                case 0: if idle.severity >= .warn { idle.causes.insert(g, at: 0) }
                case 1: if cruise.severity >= .warn { cruise.causes.insert(g, at: 0) }
                case 2: if transition.severity >= .warn { transition.causes.insert(g, at: 0) }
                case 3: if fullLow.severity >= .warn { fullLow.causes.insert(g, at: 0) }
                default: if fullHigh.severity >= .warn { fullHigh.causes.insert(g, at: 0) }
                }
            }
        }

        d.findings = [idle, cruise, transition, fullLow, fullHigh, tip]
        if let w = warmupFinding(s) { d.findings.append(w) }
        if let o = overrunFinding(buckets[.overrun]) { d.findings.append(o) }

        d.worst = d.findings.map { $0.severity }.max() ?? .none
        d.headline = headline(d)
        d.plan = plan(d, global: global, input: input)
        return d
    }

    /// Grundgeruest eines Befunds aus den Kennfeld-Zellen; nil-Lambda = keine Aussage
    private static func base(_ area: DiagArea, _ input: DiagnosisInput, _ bucket: Bucket?,
                             lambda: Double? = nil, count: Int? = nil, spread: Double? = nil) -> Finding {
        var f = Finding(area: area)
        f.target = area.regime.flatMap { input.targets.target($0) }
        let n = count ?? bucket?.n ?? 0
        f.seconds = Double(n) * step
        f.byRPM = bucket?.byRPM ?? []
        guard n >= fewSamples, let l = lambda ?? bucket?.mean else {
            f.verdict = "zu wenig Daten"
            f.summary = "Noch " + (n == 0 ? "keine" : "zu wenige") + " Werte in diesem Bereich (" + (area.regime?.area ?? "") + ")."
            return f
        }
        f.lambda = l
        f.value = "λ " + f2(l)
        f.spread = spread ?? bucket?.spread
        f.preliminary = n < minSamples
        var line = "λ " + f3(l) + " im Mittel aus " + timeText(f.seconds)
        if let t = f.target { line += ", Ziel " + f2(t) }
        f.evidence.append(line)
        if f.preliminary { f.evidence.append("Erst wenige Werte, das Urteil ist noch unsicher.") }
        return f
    }

    // ── Leerlauf ──
    private static func idleFinding(_ input: DiagnosisInput, bucket: Bucket?, cruiseRich: Bool) -> Finding {
        let s = input.session
        // im Stand gemessener Leerlauf geht vor, sonst die Kennfeld-Zellen
        let own = (s.idleLambda?.count ?? 0) >= fewSamples
        var f = own
            ? base(.idle, input, bucket, lambda: s.idleLambda?.mean, count: s.idleLambda?.count,
                   spread: s.idleLambda?.spread)
            : base(.idle, input, bucket)
        f.tool = .idleAssistant
        guard let l = f.lambda, let t = f.target else { return f }

        let rpm = own ? s.idleRPM?.mean : nil
        let want = input.idleTargetRPM
        let rpmHigh = (rpm ?? want) > want + 150
        let rpmLow = (rpm ?? want) < want - 150
        if let r = rpm {
            var line = "Leerlaufdrehzahl " + f0(r) + " U/min"
            if let sp = s.idleRPM?.spread { line += " ±" + f0(sp) }
            f.evidence.append(line + ", eingestellt sein sollten etwa " + f0(want))
        }
        let unstable = (f.spread ?? 0) >= 0.06
        if let sp = f.spread {
            f.evidence.append("Lambda schwankt um ±" + f3(sp) + (unstable ? ": unruhig" : ""))
        }

        let j = MixtureJudge.judge(lambda: l, regime: .idle, targets: input.targets)
        f.severity = j.severity
        f.verdict = j.text
        let d = l - t
        let speedStep = "Zuerst die Leerlaufdrehzahl an der Anschlagschraube auf etwa " + f0(want)
            + " U/min senken. Bei " + f0(rpm ?? 0) + " U/min steht die Drosselklappe schon über den Übergangsbohrungen, dann wirkt die Gemischschraube kaum."

        if d > MixtureJudge.tolerance(.idle) {
            f.summary = "Im Leerlauf zu mager."
            if rpmHigh { f.actions.append(speedStep) }
            f.actions.append("Gemischschraube in kleinen Schritten herausdrehen (fetter), am besten mit dem Leerlauf-Assistenten.")
            f.actions.append("Reagiert Lambda kaum auf die Schraube: Falschluft suchen und die Leerlaufdüse reinigen.")
            if cruiseRich {
                f.causes.append("Luft im Auspuff vor der Sonde (undichte Schelle oder Krümmerdichtung). Das täuscht bei wenig Abgas mager vor und passt dazu, dass es unter Last fett ist. Vor dem Einstellen prüfen.")
            }
            f.causes.append("Falschluft: Vergaserflansch, Ansaugrohr, Unterdruckschlauch zur 123, Drosselklappenwelle")
            f.causes.append("Leerlaufdüse oder Leerlaufkanal teilweise verstopft")
        } else if d < -MixtureJudge.tolerance(.idle) {
            f.summary = "Im Leerlauf zu fett."
            if rpmHigh { f.actions.append(speedStep) }
            f.actions.append("Gemischschraube in kleinen Schritten hineindrehen (magerer), am besten mit dem Leerlauf-Assistenten.")
            f.actions.append("Bleibt es fett: Choke und Schwimmerstand prüfen.")
            f.causes.append("Choke öffnet nicht ganz")
            f.causes.append("Schwimmerstand zu hoch oder Schwimmernadelventil undicht")
            f.causes.append("Leerlaufdüse zu groß, Luftfilter zugesetzt")
        } else {
            f.summary = "Leerlaufgemisch passt."
            if rpmHigh {
                f.severity = max(f.severity, .warn)
                f.verdict = "Drehzahl hoch"
                f.summary = "Gemisch passt, aber die Leerlaufdrehzahl ist hoch."
                f.actions.append("Leerlaufdrehzahl an der Anschlagschraube auf etwa " + f0(want) + " U/min senken, danach das Gemisch noch einmal prüfen.")
            } else if rpmLow {
                f.severity = max(f.severity, .warn)
                f.verdict = "Drehzahl niedrig"
                f.summary = "Gemisch passt, aber die Leerlaufdrehzahl ist niedrig."
                f.actions.append("Leerlaufdrehzahl an der Anschlagschraube auf etwa " + f0(want) + " U/min anheben.")
            }
        }
        if unstable {
            f.severity = max(f.severity, .warn)
            if f.verdict == "passt" { f.verdict = "unruhig" }
            f.causes.append("Unruhiger Leerlauf: Zündaussetzer (Kerzen, Kerzenstecker, Zündkabel) oder Falschluft")
        }
        return f
    }

    // ── Teillast (Stufe 1) ──
    private static func cruiseFinding(_ input: DiagnosisInput, bucket: Bucket?, fullLean: Bool) -> Finding {
        var f = base(.cruise, input, bucket)
        guard let l = f.lambda, let t = f.target, let b = bucket else { return f }
        let j = MixtureJudge.judge(lambda: l, regime: .cruise, targets: input.targets)
        f.severity = j.severity
        f.verdict = j.text
        let d = l - t
        let slope = b.slope
        if let sl = slope, abs(sl) >= 0.02 {
            f.evidence.append("Mit steigender Drehzahl wird es " + (sl < 0 ? "fetter" : "magerer")
                              + " (" + String(format: "%+.2f", sl) + " je 1000 U/min)")
        }
        if abs(d) <= MixtureJudge.tolerance(.cruise) {
            f.summary = "Teillast passt."
            return f
        }
        f.tool = .jetCalc(.stage1)
        f.jet = JetAdvice.make(circuit: .stage1, lambdaNow: l, lambdaTarget: t, jet: input.jets[.stage1])
        if d < 0 {
            f.summary = "In der Teillast zu fett. Das kostet Sprit, verrußt die Kerzen und verdünnt auf Dauer das Öl."
            // Kurven der Gemischaufbereitung: Hauptduese wirkt ueberall, Luftkorrektur vor allem oben,
            // das Leerlaufsystem vor allem unten
            if let sl = slope, sl <= -0.02 {
                f.actions.append("Wird nach oben hin fetter: zuerst die Luftkorrekturdüse Stufe 1 eine Nummer größer nehmen. Sie magert vor allem bei hoher Drehzahl ab.")
                f.actions.append("Reicht das nicht: " + (f.jet?.text ?? "Hauptdüse Stufe 1 kleiner") + ".")
            } else if let sl = slope, sl >= 0.02 {
                f.actions.append("Unten fetter als oben: Das kommt eher vom Leerlaufsystem als von der Hauptdüse. Leerlaufgemisch einstellen, sonst Leerlaufdüse Stufe 1 eine Nummer kleiner.")
            } else {
                f.actions.append("Über den ganzen Bereich ähnlich fett: " + (f.jet?.text ?? "Hauptdüse Stufe 1 kleiner") + ".")
            }
            if fullLean {
                f.actions.append("Erst das magere Vollgas beheben. Stufe 1 läuft bei Vollgas mit: Magerst du sie zuerst ab, wird Vollgas noch magerer.")
            }
            f.causes.append("Hauptdüse Stufe 1 zu groß oder Luftkorrekturdüse zu klein")
            f.causes.append("Schwimmerstand zu hoch")
            f.causes.append("Choke hängt, Luftfilter zugesetzt")
        } else {
            f.summary = "In der Teillast zu mager. Das gibt Ruckeln und Löcher beim Gasgeben, der Motor wird heißer."
            if let sl = slope, sl >= 0.02 {
                f.actions.append("Wird nach oben hin magerer: zuerst die Luftkorrekturdüse Stufe 1 eine Nummer kleiner nehmen. Sie fettet vor allem bei hoher Drehzahl an.")
                f.actions.append("Reicht das nicht: " + (f.jet?.text ?? "Hauptdüse Stufe 1 größer") + ".")
            } else if let sl = slope, sl <= -0.02 {
                f.actions.append("Unten magerer als oben: Das kommt eher vom Leerlaufsystem. Leerlaufgemisch einstellen, sonst Leerlaufdüse Stufe 1 eine Nummer größer.")
            } else {
                f.actions.append("Über den ganzen Bereich ähnlich mager: " + (f.jet?.text ?? "Hauptdüse Stufe 1 größer") + ".")
            }
            f.causes.append("Hauptdüse Stufe 1 zu klein oder verschmutzt")
            f.causes.append("Falschluft am Ansaugrohr")
            f.causes.append("Schwimmerstand zu niedrig")
        }
        return f
    }

    // ── Uebergang zur zweiten Stufe ──
    private static func transitionFinding(_ input: DiagnosisInput, bucket: Bucket?) -> Finding {
        var f = base(.transition, input, bucket)
        guard let l = f.lambda, let t = f.target else { return f }
        let j = MixtureJudge.judge(lambda: l, regime: .transition, targets: input.targets)
        f.severity = j.severity
        f.verdict = j.text
        let d = l - t
        if let sp = f.spread, sp >= 0.06 {
            f.evidence.append("Lambda schwankt hier um ±" + f3(sp) + ". Das ist typisch, solange die zweite Stufe gerade öffnet.")
        }
        if abs(d) <= MixtureJudge.tolerance(.transition) {
            f.summary = "Der Übergang zur zweiten Stufe passt."
            return f
        }
        f.tool = .jetCalc(.transition)
        f.jet = JetAdvice.make(circuit: .transition, lambdaNow: l, lambdaTarget: t, jet: input.jets[.transition])
        if d > 0 {
            f.summary = "Beim Öffnen der zweiten Stufe wird es mager. Das spürst du als Loch beim Durchbeschleunigen."
            f.actions.append((f.jet?.text ?? "Übergangsdüse Stufe 2 größer") + ".")
            f.actions.append("Prüfen, ob die zweite Stufe sauber und nicht zu früh öffnet (Gestänge, Anschlag).")
            f.causes.append("Leerlauf-/Übergangsdüse Stufe 2 zu klein oder verstopft")
            f.causes.append("Zweite Stufe öffnet zu früh")
        } else {
            f.summary = "Beim Öffnen der zweiten Stufe wird es fett."
            f.actions.append((f.jet?.text ?? "Übergangsdüse Stufe 2 kleiner") + ".")
            f.causes.append("Leerlauf-/Übergangsdüse Stufe 2 zu groß")
            f.causes.append("Stufe 1 schon zu fett (siehe Teillast)")
        }
        return f
    }

    // ── Vollgas unten / oben ──
    private static func fullFinding(_ input: DiagnosisInput, area: DiagArea, bucket: Bucket?,
                                    otherDev: Double?) -> Finding {
        var f = base(area, input, bucket)
        guard let l = f.lambda, let t = f.target, let b = bucket else { return f }
        let top = area == .fullHigh
        let cols = b.byRPM.filter { $0.count >= 20 }
        if cols.count >= 2 {
            f.evidence.append(cols.map { f0($0.rpm) + ": " + f2($0.lambda) }.joined(separator: " · "))
        }
        let leanCols = cols.filter { $0.lambda >= t + 0.04 }
        let dangerCols = cols.filter { $0.lambda >= 1.0 }
        // Fuer die Duese zaehlt die magere Stelle, nicht der Schnitt ueber alles
        var ref = l
        if !leanCols.isEmpty {
            let n = leanCols.reduce(0) { $0 + $1.count }
            ref = leanCols.reduce(0.0) { $0 + $1.lambda * Double($1.count) } / Double(n)
        }
        let d = ref - t

        if l >= 1.0 || !dangerCols.isEmpty {
            f.severity = .crit
            f.verdict = "zu mager"
        } else if d > 0.04 {
            f.severity = .warn
            f.verdict = "mager"
        } else if l - t < -0.06 {
            f.severity = .warn
            f.verdict = "fett"
        } else {
            f.severity = .ok
            f.verdict = "passt"
            f.summary = top ? "Vollgas oben passt." : "Vollgas unten passt."
            return f
        }
        f.tool = .jetCalc(.stage2)

        if f.verdict == "fett" {
            f.jet = JetAdvice.make(circuit: .stage2, lambdaNow: l, lambdaTarget: t, jet: input.jets[.stage2])
            f.summary = "Bei Vollgas fetter als nötig. Das schadet nicht, kostet aber etwas Leistung und Sprit."
            if (otherDev ?? -1) > 0.04 {
                f.actions.append("Vorsicht: " + (top ? "unten" : "oben") + " ist es mager. Eine kleinere Hauptdüse würde das verschlimmern. Hier hilft eher die Luftkorrekturdüse Stufe 2.")
            } else {
                f.actions.append((f.jet?.text ?? "Hauptdüse Stufe 2 kleiner") + ". In kleinen Schritten, Vollgas darf nie mager werden.")
            }
            f.causes.append("Hauptdüse Stufe 2 zu groß")
            return f
        }

        // mager
        f.jet = JetAdvice.make(circuit: .stage2, lambdaNow: ref, lambdaTarget: t, jet: input.jets[.stage2])
        if let first = (dangerCols.first ?? leanCols.first)?.rpm {
            f.evidence.append("Mager ab etwa " + f0(first - 250) + " U/min")
        }
        if let p = input.pulls, p.count > 0 {
            f.evidence.append("\(p.count) Züge unter Last aufgezeichnet, \(p.leanTop) davon werden oben mager"
                              + (p.starving > 0 ? ", bei \(p.starving) läuft Lambda mit der Zeit weg" : ""))
        }
        f.summary = f.severity == .crit
            ? "Zu mager bei Vollgas. Der Motor wird heißer als nötig und verschenkt Leistung. Bis das behoben ist: kein Dauervollgas" + (top ? " bei hoher Drehzahl." : ".")
            : "Bei Vollgas magerer als das Ziel. Für volle Leistung und kühlere Brennräume etwas anfetten."
        f.actions.append((f.jet?.text ?? "Hauptdüse Stufe 2 größer") + ".")
        if let o = otherDev, o < 0.02 {
            f.actions.append((top ? "Unten" : "Oben") + " passt es schon oder ist fett: Dann fettet eine kleinere Luftkorrekturdüse Stufe 2 gezielt "
                             + (top ? "oben" : "über den ganzen Bereich") + " an, ohne den Rest zu verändern.")
        }
        if (input.pulls?.starving ?? 0) > 0 {
            f.actions.append("Lambda läuft bei langen Zügen weg: Das spricht für die Benzinversorgung. Pumpe, Filter, Schwimmernadelventil, Schwimmerstand und Tankentlüftung prüfen, bevor du Düsen tauschst.")
        } else {
            f.actions.append("Mit einem langen Zug unter Vollgas gegenprüfen (Werkzeuge › Züge unter Last): Wird Lambda dabei immer magerer, fehlt Sprit von der Pumpe, nicht von der Düse.")
        }
        f.causes.append("Hauptdüse Stufe 2 zu klein")
        f.causes.append("Luftkorrekturdüse Stufe 2 zu groß")
        f.causes.append("Benzinversorgung knapp: Pumpe, Filter, Schwimmernadelventil, Schwimmerstand zu niedrig")
        return f
    }

    // ── Gasstoss ──
    private static func tipInFinding(_ t: TipInSummary?) -> Finding {
        var f = Finding(area: .tipIn)
        f.tool = .tipIns
        guard let t, t.count >= 3 else {
            f.verdict = "zu wenig Daten"
            f.summary = "Noch zu wenige Gasstöße erkannt. Im zweiten oder dritten Gang bei 1500–2500 U/min ein paar Mal zügig Gas geben."
            return f
        }
        let n = Double(t.count)
        f.value = "\(t.count)×"
        f.preliminary = t.count < 5
        f.evidence.append("\(t.count) Gasstöße: \(t.lean) mager, \(t.ok) sauber, \(t.rich) fett")
        f.evidence.append("Im Mittel wird es kurz um " + f3(t.avgLeanSpike) + " magerer")
        if Double(t.lean) / n >= 0.5 {
            f.severity = .warn
            f.verdict = "Magerloch"
            f.summary = "Beim Gasgeben wird das Gemisch meist kurz mager. Das fühlt sich wie ein Verschlucker an."
            f.actions.append("Beschleunigerpumpe prüfen: Beim Gasgeben muss sofort ein kräftiger Strahl kommen (bei stehendem Motor in den Vergaser schauen).")
            f.actions.append("Pumpenmembran, Pumpenhub am Gestänge und die Pumpendüse prüfen.")
            f.causes.append("Pumpenmembran hart oder rissig")
            f.causes.append("Zu wenig Pumpenhub, Pumpendüse verstopft, Rückschlagventil klemmt")
        } else if Double(t.rich) / n >= 0.5 {
            f.severity = .warn
            f.verdict = "zu fett"
            f.summary = "Beim Gasgeben wird das Gemisch meist deutlich zu fett."
            f.actions.append("Pumpenhub etwas zurücknehmen oder eine kleinere Pumpendüse einsetzen.")
            f.causes.append("Beschleunigerpumpe fördert zu viel")
        } else {
            f.severity = .ok
            f.verdict = "sauber"
            f.summary = "Beim Gasgeben bleibt Lambda meist im Rahmen."
        }
        return f
    }

    // ── Kaltlauf: Lambda ueber der Oeltemperatur ──
    private static func warmupFinding(_ s: TuningSession) -> Finding? {
        guard let w = s.warmup, w.count == TuningSession.warmEdges.count + 1 else { return nil }
        let labels = ["unter 40 °C", "40–60 °C", "60–80 °C", "ab 80 °C"]
        let have = w.enumerated().filter { $0.element.count >= 20 }
        guard have.count >= 2, let cold = have.first, let warm = have.last,
              cold.offset <= 1, let lc = cold.element.mean, let lw = warm.element.mean else { return nil }
        var f = Finding(area: .warmup)
        f.severity = .info
        f.lambda = lc
        f.value = "λ " + f2(lc)
        f.seconds = Double(cold.element.count) * step
        f.evidence.append(have.map { labels[$0.offset] + ": " + f2($0.element.mean ?? 0) }.joined(separator: " · "))
        if lc > lw + 0.05 && lc > 1.03 {
            f.severity = .warn
            f.verdict = "kalt mager"
            f.summary = "Kalt läuft der Motor magerer als warm. Dann ruckelt er nach dem Start und nimmt schlecht Gas an."
            f.actions.append("Choke prüfen: Schließt die Starterklappe ganz, und bleibt der Zug stehen?")
            f.causes.append("Choke schließt nicht ganz oder wird zu früh zurückgenommen")
        } else if lc < 0.80 {
            f.verdict = "kalt sehr fett"
            f.summary = "Kalt sehr fett. Das ist mit Choke normal, den Choke aber so früh wie möglich zurücknehmen."
        } else {
            f.severity = .ok
            f.verdict = "unauffällig"
            f.summary = "Kalt und warm liegen nah beieinander."
        }
        return f
    }

    // ── Schiebebetrieb: nur zur Kenntnis ──
    private static func overrunFinding(_ bucket: Bucket?) -> Finding? {
        guard let b = bucket, b.n >= minSamples, let l = b.mean else { return nil }
        var f = Finding(area: .overrun)
        f.severity = .info
        f.lambda = l
        f.value = "λ " + f2(l)
        f.seconds = Double(b.n) * step
        f.byRPM = b.byRPM
        f.verdict = l < 0.97 ? "fett, normal" : (l > 1.15 ? "sehr mager" : "unauffällig")
        f.evidence.append("λ " + f3(l) + " im Mittel aus " + timeText(f.seconds))
        f.summary = "Im Schub zieht der hohe Unterdruck Sprit über das Leerlaufsystem, fett ist hier bei einem Vergaser normal. Sehr mager oder Knallen im Auspuff deutet auf Falschluft am Auspuff."
        return f
    }

    private static func headline(_ d: Diagnosis) -> String {
        let main = d.findings.filter { DiagArea.main.contains($0.area) }
        let judged = main.filter { $0.severity >= .ok }
        if judged.isEmpty {
            return "Noch zu wenig Daten. Ein paar Minuten warm fahren, dann füllt sich der Check."
        }
        let bad = main.filter { $0.severity >= .warn }
        if bad.isEmpty {
            return judged.count == main.count ? "Alles im Rahmen." : "Bisher alles im Rahmen, einige Bereiche fehlen noch."
        }
        let crit = bad.filter { $0.severity == .crit }
        let names = (crit.isEmpty ? bad : crit).map { $0.area.title + " " + $0.verdict }
        return (bad.count == 1 ? "Eine Baustelle: " : "\(bad.count) Baustellen, zuerst: ") + names.prefix(2).joined(separator: ", ") + "."
    }

    /// Reihenfolge, in der es sich lohnt
    private static func plan(_ d: Diagnosis, global: String?, input: DiagnosisInput) -> [String] {
        var steps: [String] = []
        func first(_ a: DiagArea) -> String? {
            guard let f = d.finding(a), f.severity >= .warn, let act = f.actions.first else { return nil }
            return f.area.title + ": " + act
        }
        // 1. was dem Motor schadet
        for a in [DiagArea.fullHigh, .fullLow] {
            if let f = d.finding(a), f.severity == .crit, let s = first(a) { steps.append(s) }
        }
        // 2. Grundlagen
        if let g = global { steps.append(g) }
        // 3. der Rest, von unten nach oben
        for a in [DiagArea.idle, .cruise, .transition, .fullLow, .fullHigh, .tipIn] {
            if let f = d.finding(a), f.severity == .crit, a == .fullHigh || a == .fullLow { continue }
            if let s = first(a) { steps.append(s) }
        }
        if !steps.isEmpty {
            steps.append("Immer nur eine Sache ändern, im Logbuch eintragen, neue Messreihe fahren und vergleichen.")
        }
        return steps
    }
}
