// Prueft den Rechenkern der Mac-App ohne Mac. Laeuft im CI:
//   swiftc <Kern-Dateien> Mac/MacCore.swift Mac/DemoData.swift Tests/MacCheck.swift

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FEHLER: " + what) }
}
func near(_ a: Double?, _ b: Double, _ tol: Double) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tol
}

let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
let demo = DemoData.make(now: now)
check(demo.trips.count >= 18 && demo.trips.count <= 40, "Beispielfahrten: \(demo.trips.count)")
check(demo.book.entries.count == 3 && demo.fuel.count >= 2, "Logbuch und Tankbuch: \(demo.book.entries.count) / \(demo.fuel.count)")
check(demo.sessions.count == 2 && demo.sessions[0].hasSteady, "Messreihen")

// Kennzahlen je Fahrt
var stats: [TripStats] = []
for t in demo.trips { stats.append(TripStats.compute(summary: t.summary, rows: t.rows)) }
let totals = Aggregate.totals(stats)
check(totals.km > 300 && totals.engineHours > 5, "Summen: \(Int(totals.km)) km")
check(totals.pulls >= 5, "Zuege erkannt: \(totals.pulls)")
check(totals.tipIns >= 5, "Gasstoesse erkannt: \(totals.tipIns)")
check(stats.allSatisfy { $0.regimes["cruise"] != nil }, "Teillast in jeder Fahrt")
check(stats.contains { $0.warmupMinutes != nil }, "Warmlaufzeit")
check(stats.contains { $0.oilPIdleWarm != nil && $0.oilP3000Warm != nil }, "Oeldruck warm")

// Wirkung der Duesenaenderung
let fx = LogAnalysis.effects(entries: demo.book.entries, stats: stats, target: 0.88, vehicle: Vehicle())
check(fx.count == 3, "drei Logbuch-Wirkungen")
if let jet = fx.first(where: { $0.entry.changes.contains { $0.contains("Hauptdüse Stufe 2") } }) {
    check(jet.beforeTrips >= 3 && jet.afterTrips >= 3, "Fahrten vor/nach: \(jet.beforeTrips)/\(jet.afterTrips)")
    let d = jet.delta(.fullHigh)
    check(d != nil && d! < -0.08, "Vollgas oben nach der Aenderung fetter: \(d ?? 99)")
    check(abs(jet.delta(.cruise) ?? 1) < 0.02, "Teillast unveraendert")
} else { check(false, "Eintrag Hauptduese fehlt") }

// Trends
let trend = Trend.lambda(stats)
check(trend.contains { $0.series == Regime.fullHigh.title }, "Trend Vollgas oben")
let power = Trend.power(stats.flatMap { $0.pulls }, target: 0.88, vehicle: Vehicle())
check(!power.isEmpty && power.allSatisfy { $0.value > 3 && $0.value < 40 }, "Leistung plausibel")

// Gesamtauswertung = Messreihe ueber alle Fahrten
var all = TuningSession(name: "Alle")
for t in demo.trips { all.add(rows: t.rows) }
var input = DiagnosisInput(session: all)
input.idleTargetRPM = 850
let diag = MixtureDiagnosis.run(input)
check(diag.finding(.cruise)?.verdict.contains("fett") == true, "Teillast fett: \(diag.finding(.cruise)?.verdict ?? "-")")

// Nur die Zeit nach der Aenderung
let jetDate = demo.book.entries.sorted { $0.date < $1.date }[1].date
var after = TuningSession(name: "Nach")
for t in demo.trips where t.summary.start >= jetDate { after.add(rows: t.rows) }
let dAfter = MixtureDiagnosis.run(DiagnosisInput(session: after))
check((dAfter.finding(.fullHigh)?.severity ?? .crit) <= .ok, "Vollgas oben passt nachher: \(dAfter.finding(.fullHigh)?.verdict ?? "-")")
var before = TuningSession(name: "Vor")
for t in demo.trips where t.summary.start < jetDate { before.add(rows: t.rows) }
let diff = MapDiff.lambda(before, after, steady: true)
check(diff.joined().compactMap { $0 }.count >= 6, "Kennfeld-Differenz")

// Diagramm-Punkte
let rows = demo.trips[0].rows
let full = 0...(rows.last?.t ?? 1)
let pts = Downsample.series(rows, range: full, buckets: 300) { Channel.lambda.value($0) }
check(pts.count > 100 && pts.count <= 620, "Min/Max-Eimer: \(pts.count)")
check(zip(pts, pts.dropFirst()).allSatisfy { $0.t <= $1.t }, "zeitlich sortiert")
let small = Downsample.series(rows, range: 10...20, buckets: 300) { $0.rpm }
check(small.count >= 64 && small.count <= 66, "kleines Fenster ungekuerzt, mit Rand: \(small.count)")
var gappy = rows.prefix(40).map { $0 }
for i in 20..<40 { gappy[i].t += 60 }
let g = Downsample.series(gappy, range: 0...100, buckets: 300) { $0.rpm }
check(Set(g.map { $0.seg }).count == 2, "Luecke trennt die Linie")
check(TripIndex.nearest(rows, 10.1).map { rows[$0].t } == 10.0, "naechste Zeile")
let st = RangeStats.of(rows, .rpm, range: 0...30)
check(st != nil && st!.n == 121 && st!.max >= st!.mean, "Statistik im Fenster")
check(RangeStats.slice(rows, 10...11).count == 5, "Ausschnitt")

// CSV hin und zurueck
let text = DemoData.csv(Array(rows.prefix(50)), start: now)
let back = TripCSV.parse(text)
check(back.count == 50 && near(back[10].lambda, rows[10].lambda ?? 0, 0.0006), "CSV-Rundreise")

// Zusammenfassung und Kurven
let sum0 = TripSummary.from(id: "x", start: now, rows: rows)
check(abs(sum0.distanceKm - demo.trips[0].summary.distanceKm) < 0.2 && sum0.lambdaCount > 100, "Zusammenfassung aus Zeilen")
let fl = CurveData.byRPM(after, rows: CurveData.fullLoad, steady: true)
check(fl.count >= 3 && fl.allSatisfy { $0.lambda < 0.95 }, "Vollgas-Kurve nachher: \(fl.map { String(format: "%.2f", $0.lambda) })")

// Zeitraeume
check(Period.last(days: 7, now: now).contains(now.addingTimeInterval(-86_400)), "Zeitraum enthalten")
check(!Period(from: now, to: nil).contains(now.addingTimeInterval(-1)), "Zeitraum nicht enthalten")
check(TimeText.duration(3720) == "1:02 h" && TimeText.clock(75) == "1:15", "Zeit als Text")

if CommandLine.arguments.contains("-v") {
    print("Fahrten", demo.trips.count, "km", Int(totals.km), "h", totals.engineHours, "Zuege", totals.pulls, "Gasstoesse", totals.tipIns, "Warnungen", totals.alerts)
    for e in fx { print(e.entry.title, e.beforeTrips, e.afterTrips, Regime.allCases.map { r in "\(r.rawValue) \(e.lambda(r, after: false).map { String(format: "%.3f", $0) } ?? "-")→\(e.lambda(r, after: true).map { String(format: "%.3f", $0) } ?? "-")" }.joined(separator: "  "), e.beforePower ?? -1, e.afterPower ?? -1) }
    print(diag.headline); for f in diag.findings { print(" ", f.area.title, f.value, f.verdict) }
    let fr = FuelMath.results(demo.fuel) { _, _ in 0 }; print("Verbrauch", fr.values.map { String(format: "%.1f", $0.per100) })
}
if failures == 0 {
    print("Mac-Kern: alle Pruefungen bestanden")
} else {
    print("\(failures) Pruefung(en) fehlgeschlagen")
    exit(1)
}
