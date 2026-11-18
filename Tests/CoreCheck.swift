// Prueft den Rechenkern ohne Geraet und ohne Oberflaeche. Laeuft im CI vor dem Build:
//   swiftc Sources/{Samples,Mixture,TuningSession,MixtureDiagnosis,TipInDetector,PullDetector,
//          AlertMonitor,CarbSetup,LinkDiagnostics,Tune123}.swift Tests/CoreCheck.swift
// Alle Daten hier sind kuenstlich erzeugt.

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FEHLER: " + what) }
}
func near(_ a: Double?, _ b: Double, _ tol: Double) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tol
}

let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
func at(_ sec: Double) -> Date { t0.addingTimeInterval(sec) }

// ── Betriebsbereiche ──
check(Regime.of(rpm: 900, kPa: 42) == .idle, "Leerlauf")
check(Regime.of(rpm: 3000, kPa: 45) == .cruise, "Teillast")
check(Regime.of(rpm: 3000, kPa: 80) == .transition, "Uebergang")
check(Regime.of(rpm: 2500, kPa: 97) == .fullLow, "Vollgas unten")
check(Regime.of(rpm: 4800, kPa: 97) == .fullHigh, "Vollgas oben")
check(Regime.of(rpm: 3000, kPa: 22) == .overrun, "Schub")
check(CarbCircuit.of(row: 7, col: 8) == .stage2 && CarbCircuit.of(row: 0, col: 3) == nil, "Kreis je Zelle")

// ── Bewertung gegen das Ziel ──
let targets = MixtureTargets()
check(MixtureJudge.judge(lambda: 0.88, regime: .fullHigh, targets: targets).severity == .ok, "0,88 bei Vollgas passt")
check(MixtureJudge.judge(lambda: 0.88, regime: .cruise, targets: targets).severity == .crit, "0,88 in Teillast ist fett")
check(MixtureJudge.judge(lambda: 1.02, regime: .fullHigh, targets: targets).severity == .crit, "1,02 bei Vollgas zu mager")
check(MixtureJudge.judge(lambda: 1.01, regime: .cruise, targets: targets).severity == .ok, "1,01 in Teillast passt")
check(MixtureJudge.live(lambda: 0.9, rpm: nil, kPa: 50, targets: targets) == nil, "ohne Drehzahl kein Urteil")
check(near(JetMath.newSize(old: 115, lambdaNow: 0.97, lambdaTarget: 1.0), 113.26, 0.05), "Duesenformel")

// ── Messreihe mit ruhiger Fahrt ──
// Leerlauf mager und unruhig, Teillast fett, Vollgas oben mager
func drive() -> TuningSession {
    var s = TuningSession(name: "Test")
    var tr = SteadyTracker()
    var t = 0.0
    func run(_ seconds: Double, rpm: Double, map: Double, lambda: Double, jitter: Double = 0.01,
             oilT: Double = 85, speed: Double = 50) {
        var i = 0
        while Double(i) * 0.25 < seconds {
            let l = lambda + (i % 2 == 0 ? jitter : -jitter)
            let steady = tr.push(t: t, rpm: rpm, map: map)
            s.add(SessionPoint(lambda: l, rpm: rpm, map: map, advance: 20, oilT: oilT, speed: speed, steady: steady))
            t += 0.25
            i += 1
        }
    }
    run(60, rpm: 1100, map: 45, lambda: 1.15, jitter: 0.08, speed: 0)
    run(60, rpm: 2500, map: 50, lambda: 0.93)
    run(60, rpm: 3500, map: 55, lambda: 0.90)
    run(60, rpm: 4500, map: 55, lambda: 0.86)
    run(40, rpm: 3000, map: 80, lambda: 0.95)
    run(40, rpm: 2500, map: 97, lambda: 0.87)
    run(40, rpm: 4000, map: 97, lambda: 0.97)
    run(40, rpm: 4500, map: 97, lambda: 1.04)
    run(30, rpm: 2500, map: 45, lambda: 1.08, oilT: 30)       // kalt
    return s
}
let s = drive()
check(s.hasSteady, "ruhige Fahrt erfasst")
check(s.steadyCount < s.lambdaCount, "kalte und unruhige Werte fehlen im ruhigen Kennfeld")
check((s.idleLambda?.count ?? 0) > 100 && near(s.idleRPM?.mean, 1100, 1), "Leerlauf-Statistik")
check(s.warmup?.first?.count ?? 0 > 50, "Kaltlauf erfasst")
check((s.hist?["cruise"]?.reduce(0, +) ?? 0) > 400, "Lambda-Verteilung")

// Sprung im Saugrohrdruck gilt nicht als ruhig
var trk = SteadyTracker()
var calm = false
for i in 0..<8 { calm = trk.push(t: Double(i) * 0.25, rpm: 2500, map: 50) }
check(calm, "ruhig nach 1,5 s")
check(!trk.push(t: 2.0, rpm: 2550, map: 90), "Gasstoss ist nicht ruhig")

var input = DiagnosisInput(session: s)
input.jets = [.stage2: 85]
input.idleTargetRPM = 850
let d = MixtureDiagnosis.run(input)
check(d.steady, "Diagnose nutzt ruhige Fahrt")
check(d.worst == .crit, "schlimmster Befund kritisch")
if let f = d.finding(.idle) {
    check(f.severity >= .warn && f.verdict.contains("mager"), "Leerlauf mager: " + f.verdict)
    check(f.causes.contains { $0.contains("Auspuff") }, "Hinweis auf Luft im Auspuff")
    check(f.actions.first?.contains("Leerlaufdrehzahl") == true, "erst Drehzahl senken")
    check(f.tool == .idleAssistant, "Werkzeug Leerlauf")
} else { check(false, "Leerlauf-Befund fehlt") }
if let f = d.finding(.cruise) {
    check(f.severity >= .warn && f.verdict.contains("fett"), "Teillast fett: " + f.verdict)
    check(f.actions.first?.contains("Luftkorrekturdüse Stufe 1") == true, "oben fetter: Luftkorrektur zuerst")
    check(f.actions.contains { $0.contains("Erst das magere Vollgas") }, "Reihenfolge-Warnung")
} else { check(false, "Teillast-Befund fehlt") }
check(d.finding(.transition)?.severity == .ok, "Uebergang passt")
check(d.finding(.fullLow)?.severity == .ok, "Vollgas unten passt")
if let f = d.finding(.fullHigh) {
    check(f.severity == .crit, "Vollgas oben kritisch")
    check(f.jet?.old == 85 && (f.jet?.new ?? 0) > 88 && (f.jet?.new ?? 99) < 94, "Duesenvorschlag groesser")
    check(f.actions.contains { $0.contains("Luftkorrekturdüse Stufe 2") }, "unten passt: Luftkorrektur nennen")
} else { check(false, "Vollgas-oben-Befund fehlt") }
check(d.finding(.warmup)?.verdict == "kalt mager", "Kaltlauf mager")
check(d.plan.first?.hasPrefix("Vollgas oben") == true, "Plan beginnt mit dem Gefaehrlichen")
check(d.finding(.tipIn)?.severity == Severity.none, "Gasstoss ohne Daten")

// leere Messreihe
let empty = MixtureDiagnosis.run(DiagnosisInput(session: TuningSession(name: "leer")))
check(empty.worst == .none && empty.plan.isEmpty, "leere Messreihe ohne Urteil")

// alte Messreihe (ohne die neuen Felder) bleibt lesbar
let enc = try! JSONEncoder().encode(s)
var obj = try! JSONSerialization.jsonObject(with: enc) as! [String: Any]
for k in ["steadyCells", "idleLambda", "idleRPM", "hist", "warmup", "advanceCells"] { obj.removeValue(forKey: k) }
let old = try? JSONDecoder().decode(TuningSession.self, from: JSONSerialization.data(withJSONObject: obj))
check(old != nil && old?.hasSteady == false && old?.lambdaCount == s.lambdaCount, "alte Messreihe lesbar")
if let o = old { check(!MixtureDiagnosis.run(DiagnosisInput(session: o)).steady, "alte Messreihe: alle Werte") }

// ── Gasstoss ──
func tipIn(lambdaAfter: [Double], mapAfter: Double = 90) -> TipInEvent? {
    var det = TipInDetector()
    var out: TipInEvent?
    var t = 0.0
    for _ in 0..<16 {      // 4 s ruhig
        var x = Sample(time: at(t)); x.lambda = 1.0; x.rpm = 2000; x.mapKPa = 45
        if let e = det.add(x) { out = e }
        t += 0.25
    }
    for i in 0..<20 {      // 5 s danach
        var x = Sample(time: at(t))
        x.lambda = i < lambdaAfter.count ? lambdaAfter[i] : (lambdaAfter.last ?? 1)
        x.rpm = 2000 + Double(i) * 60
        x.mapKPa = mapAfter
        if let e = det.add(x) { out = e }
        t += 0.25
    }
    return out
}
let leanHole = tipIn(lambdaAfter: [1.0, 1.12, 1.18, 1.10, 0.95, 0.88])
check(leanHole?.verdict == .lean && near(leanHole?.leanSpike, 0.18, 0.01), "Magerloch erkannt")
check(near(leanHole?.mapBefore, 45, 1) && near(leanHole?.mapAfter, 90, 1), "Saugrohrdruck vor/nach")
let clean = tipIn(lambdaAfter: [1.0, 0.97, 0.92, 0.88, 0.87])
check(clean?.verdict == .ok, "sauberer Gasstoss zaehlt als sauber, nicht als fett")
check(tipIn(lambdaAfter: [1.0, 0.85, 0.74, 0.72, 0.75])?.verdict == .rich, "ueberfettet")
check(tipIn(lambdaAfter: [1.0, 1.0], mapAfter: 50) == nil, "ohne Drucksprung kein Gasstoss")
let sum = [leanHole, clean].compactMap { $0 }.summary
check(sum?.count == 2 && sum?.lean == 1 && sum?.ok == 1, "Zusammenfassung")

// ── Zuege unter Last ──
func feedPull(_ make: (Double) -> Sample?) -> [Pull] {
    var det = PullDetector()
    var out: [Pull] = []
    var t = 0.0
    while t < 40 {
        if let x = make(t), let p = det.add(x) { out.append(p) }
        t += 0.25
    }
    return out
}
// 3. Gang: 2000 → 5000 U/min in 15 s, 17 km/h je 1000 U/min, oben mager
let pulls = feedPull { t in
    var x = Sample(time: at(t))
    if t < 2 { x.rpm = 2000; x.mapKPa = 45; x.lambda = 1.0; x.speed = 34; return x }
    if t <= 17 {
        let r = 2000 + (t - 2) * 200
        x.rpm = r; x.mapKPa = 96; x.speed = r / 1000 * 17
        x.lambda = r < 4200 ? 0.88 : 1.02
        return x
    }
    x.rpm = 3000; x.mapKPa = 30; x.lambda = 1.1; x.speed = 60
    return x
}
check(pulls.count == 1 && pulls.first?.kind == .pull, "ein Zug erkannt (\(pulls.count))")
if let p = pulls.first {
    let a = PullAnalysis(p, target: 0.88)
    check(near(a.duration, 15, 0.6) && near(a.rpmFrom, 2000, 60) && near(a.rpmTo, 5000, 60), "Dauer und Drehzahlen")
    check(a.verdict == .leanTop && near(a.leanFrom, 4500, 300), "oben mager ab etwa 4500")
    check(near(a.ratio, 17, 0.2), "Uebersetzung")
    // 700 kg, 0,94 m/s²: etwa 12–20 kW am Rad
    check((a.peak?.kW ?? 0) > 10 && (a.peak?.kW ?? 99) < 25, "Leistung plausibel: \(a.peak?.kW ?? 0)")
    check(near(PullAnalysis.time(p, from: 3000, to: 4000), 5, 0.3), "Zeit 3000–4000")
    check([p].summary(target: 0.88)?.leanTop == 1, "Zusammenfassung der Zuege")
}
// Dauervollgas, Lambda laeuft weg
let hold = feedPull { t in
    var x = Sample(time: at(t))
    guard t < 30 else { x.rpm = 2500; x.mapKPa = 40; x.lambda = 1; return x }
    x.rpm = 4600 + (t.truncatingRemainder(dividingBy: 1) < 0.5 ? 30 : -30)
    x.mapKPa = 97
    x.lambda = 0.88 + t * 0.006
    return x
}
check(hold.first?.kind == .steady, "Dauervollgas erkannt")
if let p = hold.first {
    let a = PullAnalysis(p, target: 0.88)
    check(a.verdict == .starving && near(a.drift, 0.06, 0.01), "Lambda laeuft weg")
}
check(feedPull { t in
    var x = Sample(time: at(t)); x.rpm = 3000; x.mapKPa = 60; x.lambda = 1; return x
}.isEmpty, "Teillast ist kein Zug")

// ── Warnungen ──
var mon = AlertMonitor()
let settings = AlertSettings()
var raised: [AlertKind] = []
func feedAlert(_ sec: Double, _ set: (inout Sample) -> Void) {
    var x = Sample(time: at(sec))
    set(&x)
    raised += mon.update(x, settings: settings).map { $0.kind }
}
var clock = 0.0
for _ in 0..<12 { feedAlert(clock) { $0.oilP = 0.6; $0.rpm = 900 }; clock += 0.25 }
check(raised.isEmpty, "wenig Oeldruck im Leerlauf warnt nicht")
for _ in 0..<12 { feedAlert(clock) { $0.oilP = 0.6; $0.rpm = 2500 }; clock += 0.25 }
check(raised == [.oilPressure] && mon.top?.kind == .oilPressure, "Oeldruck-Warnung nach 2 s")
for _ in 0..<16 { feedAlert(clock) { $0.oilP = 3.0; $0.rpm = 2500 }; clock += 0.25 }
check(mon.active.isEmpty, "Warnung geht wieder weg")
for _ in 0..<12 { feedAlert(clock) { $0.oilP = 0.6; $0.rpm = 2500 }; clock += 0.25 }
check(raised == [.oilPressure] && !mon.active.isEmpty, "zweite Meldung erst nach 60 s")
for _ in 0..<12 { feedAlert(clock) { $0.lambda = 1.08; $0.rpm = 4000; $0.mapKPa = 95; $0.oilP = 3 }; clock += 0.25 }
check(raised.contains(.leanLoad), "mager unter Last")
var off = AlertSettings()
off.enabled.remove(.overRev)
var mon2 = AlertMonitor()
var x6 = Sample(time: at(0)); x6.rpm = 6000
_ = mon2.update(x6, settings: off)
x6 = Sample(time: at(1)); x6.rpm = 6000
check(mon2.update(x6, settings: off).isEmpty, "abgeschaltete Warnung bleibt still")
check(ContextJudge.pressure(0.0, rpm: 0).0 == .info, "0 bar bei stehendem Motor ist kein Fehler")
check(ContextJudge.pressure(0.6, rpm: 3000).0 == .crit, "0,6 bar bei 3000 kritisch")
check(ContextJudge.voltage(12.2, rpm: 0).0 == .info && ContextJudge.voltage(12.2, rpm: 2500).0 == .warn, "Bordnetz je nach Motorlauf")

// ── Beduesung, Logbuch, Tankbuch ──
var book = CarbBook()
var setup = CarbSetup()
setup[.main2] = 85
check(book.commit(setup, note: "Ausgangsstand", session: nil) != nil, "erster Eintrag")
check(book.commit(setup, note: " ", session: nil) == nil, "ohne Aenderung kein Eintrag")
setup[.main2] = 90
setup[.air2] = 0
let sid = UUID()
let e = book.commit(setup, note: "", session: (sid, "vor Umbau"))
check(e?.changes == ["Hauptdüse Stufe 2: 85 → 90"] && e?.sessionID == sid, "Aenderung beschrieben")
check(book.entries.count == 2 && book.setup.jet(.stage2) == 90 && book.setup.jets.count == 1, "Stand uebernommen")
let bookData = try! JSONEncoder().encode(book)
check((try? JSONDecoder().decode(CarbBook.self, from: bookData)) == book, "Logbuch speicherbar")

let f1 = FuelEntry(date: at(0), liters: 20, odometer: 1000)
let f2 = FuelEntry(date: at(86_400), liters: 10, odometer: nil, full: false)
let f3 = FuelEntry(date: at(2 * 86_400), liters: 8, odometer: 1300)
let f4 = FuelEntry(date: at(3 * 86_400), liters: 12, odometer: nil)
let res = FuelMath.results([f3, f1, f4, f2]) { _, _ in 200 }
check(near(res[f3.id]?.per100, 6.0, 0.001) && res[f3.id]?.gps == false, "Verbrauch aus Kilometerstand")
check(near(res[f4.id]?.per100, 6.0, 0.001) && res[f4.id]?.gps == true, "Verbrauch aus GPS-Kilometern")
check(res[f1.id] == nil && near(FuelMath.average(Array(res.values)), 6.0, 0.001), "Schnitt")

// ── 123: Statistik und Maskierung ──
var parser = Tune123Parser()
var bytes = Tune123Parser.encode(type: 0x30, byte: 0x14) + Tune123Parser.encode(type: 0x32, byte: 0x2D)
bytes += Array("$".utf8) + Tune123Parser.encode(type: 0x43, byte: 0x10)
let frames = parser.feed(Data(bytes))
check(frames.count == 3 && frames.first == .rpm(1000), "Frames mit Echo dazwischen")
check(parser.stats.skipped == 1 && parser.stats.frames[0x30] == 1 && parser.stats.raw[0x32] == 0x2D, "Parser-Statistik")
check(frames.last == .other(0x43), "unbekannter Typ wird gezaehlt")
let masked = Tune123.mask(Array("11@\r5A A5 37 38 33 32 11883\r".utf8))
check(masked == "hh@¶hh_hh_hh_hh_hh_hh_hhhhh¶", "Maskierung: " + masked)
check(!Tune123.mask(Array("PIN7832xyz".utf8)).contains { $0.isNumber || $0 == "P" || $0 == "x" }, "Maskierung laesst nichts durch")

var diag = LinkDiagnostics()
diag.tune = parser.stats
diag.tick(now: at(0))
diag.bridgePackets = 50
diag.tune.frames[0x30] = 16
diag.tick(now: at(5))
check(near(diag.bridgeRate, 10, 0.01) && near(diag.tuneRate, 3, 0.01), "Raten")
for i in 0..<250 { diag.note("Zeile \(i)") }
check(diag.log.count == LinkDiagnostics.maxLog && diag.log.last?.text == "Zeile 249", "Protokoll begrenzt")

var sc = SelfCheckInput()
sc.tuneLive = true
sc.tuneRate = 3
sc.tune = TuneReading(rpm: 0, advance: 0, mapKPa: 70, moduleTemp: 30, tuningMode: false, coilCurrent: 0, voltage: 12.5)
let checks = SelfCheck.run(sc)
check(checks.first { $0.title.hasPrefix("Saugrohrdruck") }?.severity == .warn, "Saugrohrdruck 70 kPa bei stehendem Motor faellt auf")

// ── Fahrt-CSV ──
let csv = "Zeit;Sekunden;Lambda;Drehzahl;Saugrohr_kPa;Oeldruck_bar;Oeltemp_C;Tank_Prozent;Zuendwinkel_Grad;Bordnetz_V;Spule_A;Modul_C;Tempo_kmh;Breite;Laenge;Markierung\n"
    + "2026-11-18 10:00:00.00;0,00;4,500;;;0,00;20,5;55;;;;;;;;\n"
    + "2026-11-18 10:00:00.25;0,25;0,987;2500;45;3,10;85,0;55;22,4;13,9;3,70;40;52,3;49,487000;8,466000;1\n"
    + "kaputte Zeile\n"
let rowsCSV = TripCSV.parse(csv)
check(rowsCSV.count == 2, "CSV: zwei Zeilen")
check(rowsCSV.first?.lambdaValid == nil && rowsCSV.first?.rpm == nil, "CSV: Sonde nicht bereit, leere Felder")
check(near(rowsCSV.last?.lambda, 0.987, 1e-9) && rowsCSV.last?.marker == 1 && near(rowsCSV.last?.lon, 8.466, 1e-9), "CSV: Werte mit Komma")
var tripRows: [TripRow] = []
for i in 0..<400 {
    tripRows.append(TripRow(t: Double(i) * 0.25, lambda: 0.95, rpm: 2500, map: 50, oilP: 3, oilT: 85,
                            tank: nil, advance: 25, voltage: 14, coil: nil, moduleTemp: nil, speed: 50,
                            lat: nil, lon: nil, marker: nil))
}
let fromTrip = TuningSession.from(rows: tripRows, name: "Fahrt")
check(fromTrip.lambdaCount == 400 && fromTrip.steadyCount > 350, "Messreihe aus Fahrt mit ruhiger Fahrt")
check(tripRows[3].sample(start: at(0)).time == at(0.75), "Zeile als Messwert")

if failures == 0 {
    print("Rechenkern: alle Pruefungen bestanden")
} else {
    print("\(failures) Pruefung(en) fehlgeschlagen")
    exit(1)
}
