import Foundation

// ── Technische Diagnose der Verbindungen ─────────────────────────
// Zaehlt, was von Bridge und 123 ankommt, und fuehrt ein kurzes Protokoll.
// Empfangene Rohdaten der 123 stehen im Protokoll nur maskiert (Aufbau,
// kein Inhalt), siehe Tune123.mask.

struct DiagLogLine: Identifiable, Equatable {
    var id: Int
    var time: Date
    var text: String
}

struct TypeRate: Identifiable, Equatable {
    var type: UInt8
    var name: String
    var count: Int
    var perSecond: Double
    var raw: UInt8?

    var id: UInt8 { type }
    var char: String { String(UnicodeScalar(type)) }
}

struct LinkDiagnostics: Equatable {
    static let maxLog = 200
    static let rateWindow = 5.0

    // Bridge
    var bridgePackets = 0
    var bridgeBad = 0                    // Pakete mit falscher Laenge
    var bridgeRate = 0.0                 // Pakete je Sekunde
    var bridgeRSSI: Int?
    var bridgeConnects = 0
    // 123
    var tune = Tune123Stats()
    var tuneRates: [TypeRate] = []
    var tuneRate = 0.0                   // Frames je Sekunde
    var tuneRSSI: Int?
    var tuneConnects = 0
    var tuneVariant: String?             // "BRSP" oder "Nordic UART"
    var tuneName: String?

    private(set) var log: [DiagLogLine] = []
    private var nextID = 0
    private var marks: [(time: Date, bridge: Int, frames: [UInt8: Int])] = []

    static func == (a: LinkDiagnostics, b: LinkDiagnostics) -> Bool {
        a.bridgePackets == b.bridgePackets && a.bridgeBad == b.bridgeBad && a.bridgeRSSI == b.bridgeRSSI
            && a.tune == b.tune && a.tuneRSSI == b.tuneRSSI && a.nextID == b.nextID
            && a.bridgeConnects == b.bridgeConnects && a.tuneConnects == b.tuneConnects
            && a.tuneVariant == b.tuneVariant && a.tuneName == b.tuneName
            && a.bridgeRate == b.bridgeRate && a.tuneRate == b.tuneRate
    }

    mutating func note(_ text: String, at time: Date = Date()) {
        log.append(DiagLogLine(id: nextID, time: time, text: text))
        nextID += 1
        if log.count > Self.maxLog { log.removeFirst(log.count - Self.maxLog) }
    }

    /// Einmal je Sekunde: Raten ueber die letzten 5 s
    mutating func tick(now: Date) {
        marks.append((now, bridgePackets, tune.frames))
        while let f = marks.first, now.timeIntervalSince(f.time) > Self.rateWindow + 0.5 { marks.removeFirst() }
        guard let first = marks.first, now.timeIntervalSince(first.time) >= 0.9 else { return }
        let dt = now.timeIntervalSince(first.time)
        bridgeRate = Double(bridgePackets - first.bridge) / dt
        var rates: [TypeRate] = []
        var sum = 0.0
        for type in tune.frames.keys.sorted() {
            let n = tune.frames[type] ?? 0
            let r = Double(n - (first.frames[type] ?? 0)) / dt
            sum += r
            rates.append(TypeRate(type: type, name: Tune123.typeName(type), count: n,
                                  perSecond: max(0, r), raw: tune.raw[type]))
        }
        tuneRates = rates
        tuneRate = max(0, sum)
    }

    mutating func resetCounters() {
        bridgePackets = 0
        bridgeBad = 0
        tune = Tune123Stats()
        tuneRates = []
        marks = []
        bridgeRate = 0
        tuneRate = 0
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func stamp(_ d: Date) -> String { clock.string(from: d) }

    /// Protokoll als Text zum Teilen
    func report(header: [String]) -> String {
        var lines = header
        lines.append("")
        lines.append("Bridge: \(bridgePackets) Pakete, " + String(format: "%.1f", bridgeRate) + "/s, \(bridgeBad) fehlerhaft")
        lines.append("123: \(tune.total) Frames, " + String(format: "%.1f", tuneRate) + "/s, \(tune.bytes) Bytes, "
                     + "\(tune.skipped) übersprungen, \(tune.blocks) Blöcke, \(tune.versions) Version")
        for r in tuneRates {
            let raw = r.raw.map { String(format: "0x%02X", $0) } ?? "–"
            lines.append("  '" + r.char + "' " + r.name + ": \(r.count), " + String(format: "%.1f", r.perSecond) + "/s, zuletzt " + raw)
        }
        lines.append("")
        for l in log { lines.append(Self.stamp(l.time) + "  " + l.text) }
        return lines.joined(separator: "\n")
    }
}

// ── Selbsttest: sind die Werte plausibel? ────────────────────────
struct DiagCheck: Identifiable, Equatable {
    var title: String
    var value: String
    var severity: Severity
    var hint: String = ""

    var id: String { title }
}

struct SelfCheckInput {
    var bridgeLive = false
    var tuneLive = false
    var reading: Reading?
    var tune: TuneReading?
    var engineRunning = false
    var bridgeRate = 0.0
    var tuneRate = 0.0
    var skipped = 0
    var totalFrames = 0
    var unknownTypes: [String] = []
    var gpsAccuracy: Double?
    var gpsAge: Double?
    var programComplete: Bool?
}

enum SelfCheck {
    private static func f(_ v: Double, _ d: Int) -> String {
        String(format: "%.\(d)f", v)
    }

    static func run(_ i: SelfCheckInput) -> [DiagCheck] {
        var out: [DiagCheck] = []

        // ── Bridge ──
        if i.bridgeLive {
            let ok = i.bridgeRate >= 7
            out.append(DiagCheck(title: "Datenrate Anzeige", value: f(i.bridgeRate, 1) + " /s",
                                 severity: ok ? .ok : (i.bridgeRate >= 3 ? .warn : .crit),
                                 hint: ok ? "" : "Erwartet werden etwa 10 Pakete je Sekunde. Abstand oder Störungen?"))
            if let r = i.reading {
                out.append(DiagCheck(title: "Kette Arduino → Display → Bridge",
                                     value: !r.c6Ok ? "Display fehlt" : (!r.arduinoOk ? "Arduino fehlt" : "vollständig"),
                                     severity: r.c6Ok && r.arduinoOk ? .ok : .crit,
                                     hint: !r.c6Ok ? "Kabel vom Display-ESP32 zur Bridge prüfen."
                                        : (!r.arduinoOk ? "Signalleitung vom Arduino zum Display prüfen." : "")))
                if r.lambda > 2 {
                    out.append(DiagCheck(title: "Lambdasonde", value: "nicht bereit", severity: .info,
                                         hint: "Die Sonde heizt etwa 30 s auf. Bleibt es so: Controller und Stecker prüfen."))
                } else if !i.engineRunning && i.tuneLive {
                    let air = r.lambda >= 1.25
                    out.append(DiagCheck(title: "Lambdasonde bei stehendem Motor", value: "λ " + f(r.lambda, 2),
                                         severity: air ? .ok : .info,
                                         hint: air ? "" : "An der Luft zeigt die Sonde sehr mager. Kurz nach dem Abstellen ist ein kleinerer Wert normal."))
                } else {
                    out.append(DiagCheck(title: "Lambdasonde", value: "λ " + f(r.lambda, 3), severity: .ok))
                }
                out.append(DiagCheck(title: "Öldrucksensor", value: r.pressure < 0 ? "Fehler" : f(r.pressure, 2) + " bar",
                                     severity: r.pressure < 0 ? .crit
                                        : (!i.engineRunning && i.tuneLive && r.pressure > 0.4 ? .warn : .ok),
                                     hint: r.pressure < 0 ? "Sensor oder Kabel: Der Arduino meldet einen Wert außerhalb des Bereichs."
                                        : (!i.engineRunning && i.tuneLive && r.pressure > 0.4
                                           ? "Bei stehendem Motor sollten es etwa 0 bar sein. Nullpunkt des Sensors prüfen." : "")))
                out.append(DiagCheck(title: "Öltemperatursensor", value: r.temp < 0 ? "Fehler" : f(r.temp, 1) + " °C",
                                     severity: r.temp < 0 ? .crit : .ok,
                                     hint: r.temp < 0 ? "Sensor oder Kabel prüfen." : ""))
                out.append(DiagCheck(title: "Tankgeber", value: r.tankValue.map { f($0, 0) + " %" } ?? "kein Wert",
                                     severity: r.tankValue == nil ? .info : .ok))
            }
        } else {
            out.append(DiagCheck(title: "Anzeige (Bridge)", value: "nicht verbunden", severity: .info))
        }

        // ── 123 ──
        if i.tuneLive {
            let ok = i.tuneRate >= 2
            out.append(DiagCheck(title: "Datenrate 123", value: f(i.tuneRate, 1) + " /s",
                                 severity: ok ? .ok : (i.tuneRate > 0 ? .warn : .crit),
                                 hint: ok ? "" : "Die 123 schickt sonst mehrere Frames je Sekunde."))
            if i.totalFrames >= 50 {
                let share = Double(i.skipped) / Double(max(1, i.skipped + i.totalFrames * 5))
                out.append(DiagCheck(title: "Übersprungene Bytes", value: "\(i.skipped) (" + f(share * 100, 1) + " %)",
                                     severity: share < 0.1 ? .ok : .warn,
                                     hint: share < 0.1 ? "Etwas ist normal: Die 123 schickt die eigenen Befehle als Echo zurück."
                                        : "Viele Bytes passen nicht zum bekannten Format. Das Protokoll unten hilft bei der Suche."))
            }
            if !i.unknownTypes.isEmpty {
                out.append(DiagCheck(title: "Unbekannte Frame-Typen", value: i.unknownTypes.joined(separator: " "),
                                     severity: .info, hint: "Mit gültiger Prüfsumme, aber ohne bekannte Bedeutung."))
            }
            if let t = i.tune {
                if let m = t.mapKPa, !i.engineRunning {
                    let ok = m >= 93 && m <= 104
                    out.append(DiagCheck(title: "Saugrohrdruck bei stehendem Motor", value: f(m, 0) + " kPa",
                                         severity: ok ? .ok : .warn,
                                         hint: ok ? "Entspricht dem Luftdruck, der Sensor stimmt."
                                            : "Erwartet wird der Luftdruck, etwa 95–102 kPa. Schlauch zur 123 prüfen."))
                } else if let m = t.mapKPa, i.engineRunning, (t.rpm ?? 0) < 1500 {
                    let ok = m <= 60
                    out.append(DiagCheck(title: "Saugrohrdruck im Leerlauf", value: f(m, 0) + " kPa",
                                         severity: ok ? .ok : .warn,
                                         hint: ok ? "" : "Im Leerlauf sind 30–50 kPa üblich. Hoher Wert: Schlauch undicht, abgezogen, oder Falschluft."))
                } else if t.mapKPa == nil {
                    out.append(DiagCheck(title: "Saugrohrdruck", value: "kein Wert", severity: .warn,
                                         hint: "Ohne Saugrohrdruck gibt es kein Kennfeld und keinen Gemisch-Check."))
                }
                if let v = t.voltage {
                    let j = ContextJudge.voltage(v, rpm: t.rpm)
                    out.append(DiagCheck(title: "Bordspannung", value: f(v, 1) + " V", severity: j.0, hint: j.1))
                }
                if let c = t.moduleTemp {
                    out.append(DiagCheck(title: "Temperatur der 123", value: f(c, 0) + " °C",
                                         severity: c >= 100 ? .crit : (c >= 85 ? .warn : .ok)))
                }
                if t.tuningMode == true {
                    out.append(DiagCheck(title: "Tuning-Modus", value: "aktiv", severity: .warn,
                                         hint: "Der Zündwinkel weicht von der gespeicherten Kurve ab."))
                }
            }
            if let p = i.programComplete {
                out.append(DiagCheck(title: "Zündkurven gelesen", value: p ? "vollständig" : "unvollständig",
                                     severity: p ? .ok : .warn,
                                     hint: p ? "" : "Nicht alle Speicherblöcke kamen an. Im Protokoll steht, welcher fehlt."))
            } else {
                out.append(DiagCheck(title: "Zündkurven gelesen", value: "noch nicht", severity: .info,
                                     hint: "Abstimmung › Zündung › Lesen, bei stehendem Motor."))
            }
        } else {
            out.append(DiagCheck(title: "123ignition", value: "nicht verbunden", severity: .info))
        }

        // ── GPS ──
        if let a = i.gpsAccuracy, let age = i.gpsAge {
            let ok = a <= 20 && age <= 3
            out.append(DiagCheck(title: "GPS", value: "±" + f(a, 0) + " m, " + f(age, 0) + " s alt",
                                 severity: ok ? .ok : .warn,
                                 hint: ok ? "" : "Ungenau oder alt: Tempo und Strecke sind dann unzuverlässig."))
        } else {
            out.append(DiagCheck(title: "GPS", value: "kein Empfang oder aus", severity: .info))
        }
        return out
    }
}
