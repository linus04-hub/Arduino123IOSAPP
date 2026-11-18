import Foundation

// ── Beispieldaten ────────────────────────────────────────────────
// Kuenstliche Fahrten eines 2CV6 ueber acht Wochen, damit sich die Mac-App
// ohne iPhone-Daten ausprobieren laesst (und fuer die Bildschirmfotos).
// Die Geschichte dahinter: Vollgas oben ist anfangs zu mager. Vor vier Wochen
// kommt eine groessere Hauptduese Stufe 2 rein (85 -> 90), danach passt es.
// Vor zehn Tagen wird das magere Leerlaufgemisch korrigiert. Die Teillast
// bleibt durchgehend etwas fett, als offene Baustelle.

struct DemoBundle {
    var trips: [(summary: TripSummary, rows: [TripRow])] = []
    var sessions: [TuningSession] = []
    var book = CarbBook()
    var fuel: [FuelEntry] = []
}

/// Reproduzierbarer Zufall
struct DemoRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((state >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
    }

    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    mutating func chance(_ p: Double) -> Bool { next() < p }
    mutating func noise(_ amp: Double) -> Double { (next() - 0.5) * 2 * amp }
}

enum DemoData {
    static let changeJetDay = -28.0       // Hauptduese Stufe 2: 85 -> 90
    static let changeIdleDay = -10.0      // Gemischschraube

    // Strecke: Runde um Paris (Breite, Laenge)
    static let route: [(Double, Double)] = [
        (48.8566, 2.3522), (48.8738, 2.2950), (48.8867, 2.3431), (48.8800, 2.3920),
        (48.8530, 2.4110), (48.8320, 2.3760), (48.8330, 2.3220), (48.8462, 2.2870),
        (48.8566, 2.3522)
    ]

    static func make(now: Date = Date()) -> DemoBundle {
        var rnd = DemoRandom(seed: 2_602)
        var bundle = DemoBundle()
        let today = Calendar.current.startOfDay(for: now)

        // Fahrten: im Schnitt jeden zweiten Tag, eine am Tag
        var day = -56.0
        var odometer = 48_210.0
        var tank = 80.0
        var lastEnd: Date?
        var n = 0
        while day <= -0.5 {
            let hour = rnd.range(7.5, 19.0)
            let start = today.addingTimeInterval(day * 86_400 + hour * 3600)
            let warm = lastEnd.map { start.timeIntervalSince($0) < 2 * 3600 } ?? false
            let minutes = rnd.range(12, 38)
            let trip = simulate(id: n, start: start, minutes: minutes, day: day, warm: warm,
                                tank: &tank, rnd: &rnd)
            bundle.trips.append(trip)
            odometer += trip.summary.distanceKm
            lastEnd = trip.summary.end
            if tank < 25 {
                let liters = (78 - tank) / 100 * 20
                bundle.fuel.append(FuelEntry(date: trip.summary.end.addingTimeInterval(600), liters: (liters * 10).rounded() / 10,
                                             odometer: odometer.rounded(), full: true,
                                             price: (liters * 1.82 * 100).rounded() / 100))
                tank = 78
            }
            n += 1
            day += rnd.range(1.0, 3.2)
        }

        // Messreihen: vor und nach der Duesenaenderung
        let jetDate = today.addingTimeInterval(changeJetDay * 86_400)
        var before = TuningSession(name: "HD 85 (vorher)")
        var after = TuningSession(name: "Aktuell")
        for t in bundle.trips {
            if t.summary.start < jetDate { before.add(rows: t.rows) } else { after.add(rows: t.rows) }
        }
        before.created = bundle.trips.first?.summary.start ?? jetDate
        after.created = jetDate
        bundle.sessions = [after, before]

        // Logbuch
        var setup = CarbSetup()
        setup[.idleJet1] = 45
        setup[.main1] = 112.5
        setup[.air1] = 165
        setup[.idleJet2] = 50
        setup[.main2] = 85
        setup[.air2] = 160
        setup[.pumpJet] = 50
        setup[.mixtureTurns] = 1.5
        setup[.idleRPM] = 850
        var book = CarbBook()
        book.commit(setup, note: "Ausgangsstand nach dem Reinigen", session: nil,
                    date: today.addingTimeInterval(-57 * 86_400))
        setup[.main2] = 90
        book.commit(setup, note: "Vollgas oben war zu mager", session: (before.id, before.name),
                    date: jetDate.addingTimeInterval(9 * 3600))
        setup[.mixtureTurns] = 1.75
        book.commit(setup, note: "Leerlauf etwas fetter", session: nil,
                    date: today.addingTimeInterval(changeIdleDay * 86_400 + 8 * 3600))
        bundle.book = book
        return bundle
    }

    /// Eine Fahrt: Leerlauf, Anfahren durch die Gaenge, Stadt, Landstrasse, ab und zu Vollgas
    static func simulate(id n: Int, start: Date, minutes: Double, day: Double, warm: Bool,
                         tank: inout Double, rnd: inout DemoRandom) -> (summary: TripSummary, rows: [TripRow]) {
        let afterJet = day >= changeJetDay
        let afterIdle = day >= changeIdleDay
        let ratios = [0.0, 7.0, 13.0, 19.5, 25.5]       // km/h je 1000 U/min, Gang 1–4
        let duration = minutes * 60
        let dt = 0.25

        var rows: [TripRow] = []
        var t = 0.0
        var rpm = 900.0
        var map = 42.0
        var lam = 1.0
        var oilT = warm ? rnd.range(70, 85) : rnd.range(8, 16)
        var gear = 0
        var dist = 0.0
        var tipSpike = 0.0
        var markerNext = rnd.chance(0.3) ? rnd.range(120, duration - 60) : -1
        var markerNo = 0

        // Ablauf als Folge von Abschnitten: (Art, Dauer)
        enum Phase { case idle, launch, cruise, pull, overrun, hold }
        var plan: [(Phase, Double)] = [(.idle, rnd.range(40, 90))]
        var total = plan[0].1
        while total < duration - 40 {
            let r = rnd.next()
            let p: (Phase, Double)
            if r < 0.18 { p = (.pull, rnd.range(30, 36) * (afterJet ? 0.95 : 1.05)) }
            else if r < 0.28 && day > -40 { p = (.hold, rnd.range(12, 30)) }
            else if r < 0.42 { p = (.idle, rnd.range(15, 50)) }
            else { p = (.cruise, rnd.range(60, 220)) }
            if p.0 == .idle || plan.last?.0 == .idle { plan.append((.launch, 14)) }
            plan.append(p)
            plan.append((.overrun, rnd.range(4, 9)))
            total += p.1 + 18
        }
        plan.append((.idle, 30))

        var cruiseRPM = 3200.0
        for (phase, len) in plan {
            var pt = 0.0
            let startRPM = rpm
            if phase == .cruise { cruiseRPM = rnd.range(2600, 3900) }
            while pt < len {
                // ── Soll fuer Drehzahl und Last ──
                var wantRPM = rpm
                var wantMAP = map
                switch phase {
                case .idle:
                    gear = 0
                    wantRPM = afterIdle ? 860 : 1150
                    wantMAP = 42
                case .launch:
                    // Anfahren: 1. bis 3. Gang, jeweils hochdrehen
                    let g = min(3, 1 + Int(pt / 4.7))
                    gear = g
                    let within = pt.truncatingRemainder(dividingBy: 4.7) / 4.7
                    wantRPM = 1400 + within * 2300
                    wantMAP = 72 + rnd.noise(4)
                case .cruise:
                    gear = 4
                    wantRPM = cruiseRPM + 120 * sin(pt / 9)
                    wantMAP = 46 + 7 * sin(pt / 13) + rnd.noise(1.5)
                    // gelegentlich zuegig Gas geben
                    if rnd.chance(0.003) {
                        wantMAP = 88
                        tipSpike = (afterJet ? 0.06 : 0.10) + rnd.range(0, 0.06)
                    }
                case .pull:
                    // Durchziehen im 3. Gang von 2000 bis 4600 U/min
                    gear = 3
                    wantRPM = 2000 + min(1, pt / len) * 2600
                    wantMAP = 97
                case .hold:
                    // Autobahn bergauf, Dauervollgas: im 4. Gang zieht er nur langsam hoch
                    gear = 4
                    wantRPM = min(4300, startRPM + pt * 35)
                    wantMAP = 95
                case .overrun:
                    wantRPM = max(1600, rpm - 220)
                    wantMAP = 24
                }
                rpm += (wantRPM - rpm) * (phase == .pull ? 0.9 : 0.35) + rnd.noise(phase == .idle ? 25 : 40)
                map += (wantMAP - map) * 0.5
                rpm = max(700, min(5400, rpm))

                // ── Gemisch ──
                let regime = Regime.of(rpm: rpm, kPa: map)
                var goal: Double
                switch regime {
                case .idle:       goal = afterIdle ? 0.96 : 1.12
                case .cruise:     goal = 0.93
                case .transition: goal = 0.98
                case .fullLow:    goal = afterJet ? 0.88 : 0.95
                case .fullHigh:   goal = afterJet ? 0.89 : 1.03
                case .overrun:    goal = 0.90
                }
                if oilT < 40 { goal -= 0.05 }                 // Choke
                if phase == .hold { goal += afterJet ? 0.004 * min(20, pt) / 10 : 0.03 * min(20, pt) / 10 }
                lam += (goal - lam) * 0.35
                if tipSpike > 0.005 {
                    lam += tipSpike
                    tipSpike *= 0.35
                }
                let jitter = regime == .idle && !afterIdle ? 0.05 : 0.012
                let lamOut = lam + rnd.noise(jitter)

                // ── Rest ──
                let speed = gear == 0 ? 0 : rpm / 1000 * ratios[gear]
                dist += speed / 3600 * dt
                let heat = 0.0035 + 0.000004 * rpm * (map / 100)
                oilT += (min(118, 70 + rpm / 120 + map / 6) - oilT) * heat * dt * 4
                let oilP = max(0.2, min(4.6, (0.55 + rpm / 1000 * 0.95) * (1.35 - oilT / 260)))
                let centrifugal = min(30, max(0, (rpm - 900) / 3100 * 30))
                let vacuum = map < 75 ? min(12, (75 - map) / 4) : 0
                let adv = 8 + centrifugal + vacuum
                let volt = rpm >= 1500 ? 14.0 + rnd.noise(0.15) : 13.3 + rnd.noise(0.15)
                tank = max(5, tank - (0.00065 + 0.0000002 * rpm * map / 50))
                let s = (dist / 9.5).truncatingRemainder(dividingBy: 1)
                let pos = routePoint(s)
                var marker: Int?
                if markerNext > 0 && t >= markerNext {
                    markerNo += 1
                    marker = markerNo
                    markerNext = -1
                }
                rows.append(TripRow(t: t, lambda: lamOut, rpm: rpm.rounded(), map: map.rounded(),
                                    oilP: oilP, oilT: oilT, tank: tank.rounded(), advance: adv,
                                    voltage: volt, coil: 3.7, moduleTemp: (oilT * 0.45 + 18).rounded(),
                                    speed: speed, lat: pos.0 + rnd.noise(0.00002), lon: pos.1 + rnd.noise(0.00002),
                                    marker: marker))
                t += dt
                pt += dt
            }
        }

        // Zusammenfassung wie auf dem iPhone
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "de_DE")
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var sum = TripSummary.from(id: fmt.string(from: start), start: start, rows: rows)
        sum.distanceKm = dist
        for i in sum.markers.indices {
            sum.markers[i].note = n % 3 == 0 ? "Ruckeln beim Gasgeben" : "Geräusch prüfen"
        }
        return (sum, rows)
    }

    /// Punkt auf der Runde, s von 0 bis 1
    static func routePoint(_ s: Double) -> (Double, Double) {
        let segs = route.count - 1
        let x = max(0, min(0.999_999, s)) * Double(segs)
        let i = Int(x)
        let f = x - Double(i)
        let a = route[i]
        let b = route[i + 1]
        return (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f)
    }

    /// Fahrten als CSV, wie sie das iPhone schreibt (fuer Import-Tests)
    static func csv(_ rows: [TripRow], start: Date) -> String {
        func num(_ v: Double?, _ d: Int) -> String {
            guard let v else { return "" }
            return String(format: "%.\(d)f", v).replacingOccurrences(of: ".", with: ",")
        }
        var out = "Zeit;Sekunden;Lambda;Drehzahl;Saugrohr_kPa;Oeldruck_bar;Oeltemp_C;Tank_Prozent;"
            + "Zuendwinkel_Grad;Bordnetz_V;Spule_A;Modul_C;Tempo_kmh;Breite;Laenge;Markierung\n"
        for r in rows {
            let cols = ["", num(r.t, 2), num(r.lambda, 3), num(r.rpm, 0), num(r.map, 0), num(r.oilP, 2),
                        num(r.oilT, 1), num(r.tank, 0), num(r.advance, 1), num(r.voltage, 1), num(r.coil, 2),
                        num(r.moduleTemp, 0), num(r.speed, 1), num(r.lat, 6), num(r.lon, 6),
                        r.marker.map { String($0) } ?? ""]
            out += cols.joined(separator: ";") + "\n"
        }
        return out
    }
}
