import SwiftUI

// ── Technische Diagnose ──────────────────────────────────────────
// Fuer die Fehlersuche: Was kommt von Bridge und 123 wirklich an, wie oft,
// mit welchen Rohwerten, und sind die Sensorwerte plausibel. Dazu ein
// Protokoll der Verbindung, das sich teilen laesst.

struct DiagnosticsView: View {
    @ObservedObject var ble: BLEManager
    @ObservedObject var store: DiagnosticsStore
    @ObservedObject var location: LocationManager

    private var checks: [DiagCheck] {
        let d = store.snapshot
        var i = SelfCheckInput()
        i.bridgeLive = ble.bridgeState == .live || ble.bridgeState == .demo
        i.tuneLive = ble.tuneState == .live || ble.tuneState == .demo
        i.reading = ble.shown
        i.tune = ble.tune
        i.engineRunning = ble.engineRunning
        i.bridgeRate = d.bridgeRate
        i.tuneRate = d.tuneRate
        i.skipped = d.tune.skipped
        i.totalFrames = d.tune.total
        i.unknownTypes = d.tuneRates.filter { $0.name == "unbekannt" && $0.char != "B" }.map { "'" + $0.char + "'" }
        if let l = location.location {
            i.gpsAccuracy = l.horizontalAccuracy
            i.gpsAge = Date().timeIntervalSince(l.timestamp)
        }
        i.programComplete = ble.tuneProgram.flatMap { $0.isDemo && ble.tuneState != .demo ? nil : $0.complete }
        return SelfCheck.run(i)
    }

    var body: some View {
        let d = store.snapshot
        Form {
            Section {
                ForEach(checks) { c in
                    checkRow(c)
                }
            } header: {
                Text("Selbsttest")
            } footer: {
                Text("Prüft laufend, ob die Werte zusammenpassen. Am meisten sagt der Test bei stehendem Motor mit Zündung an, und dann noch einmal im Leerlauf.")
            }
            .listRowBackground(Theme.surface)

            Section {
                LabeledContent("Zustand", value: stateText(ble.bridgeState))
                LabeledContent("Firmware", value: ble.bridgeVersion ?? "unbekannt")
                LabeledContent("Empfang", value: rssi(d.bridgeRSSI))
                LabeledContent("Pakete", value: "\(d.bridgePackets) · " + String(format: "%.1f /s", d.bridgeRate))
                LabeledContent("Fehlerhafte Pakete", value: "\(d.bridgeBad)")
                LabeledContent("Verbunden", value: "\(d.bridgeConnects)-mal")
                if let r = ble.shown {
                    LabeledContent("Lambda roh", value: String(format: "%.3f", r.lambda) + (r.lambda > 2 ? " (nicht bereit)" : ""))
                    LabeledContent("Öldruck roh", value: String(format: "%.2f bar", r.pressure) + (r.pressure < 0 ? " (Fehler)" : ""))
                    LabeledContent("Öltemperatur roh", value: String(format: "%.1f °C", r.temp) + (r.temp < 0 ? " (Fehler)" : ""))
                    LabeledContent("Tank roh", value: String(format: "%.0f", r.tank) + (r.tank > 100 ? " (kein Wert)" : " %"))
                    LabeledContent("Status-Bits", value: String(format: "0x%02X", r.flags)
                                   + " · Display " + (r.c6Ok ? "ok" : "fehlt") + " · Arduino " + (r.arduinoOk ? "ok" : "fehlt"))
                }
            } header: {
                Text("Anzeige (Bridge)")
            }
            .listRowBackground(Theme.surface)
            .font(.system(size: 14).monospacedDigit())

            Section {
                LabeledContent("Zustand", value: stateText(ble.tuneState))
                LabeledContent("Gerät", value: [d.tuneName, d.tuneVariant].compactMap { $0 }.joined(separator: " · ").ifEmpty("unbekannt"))
                LabeledContent("Empfang", value: rssi(d.tuneRSSI))
                LabeledContent("Frames", value: "\(d.tune.total) · " + String(format: "%.1f /s", d.tuneRate))
                LabeledContent("Bytes", value: "\(d.tune.bytes), davon \(d.tune.skipped) übersprungen")
                LabeledContent("Speicherblöcke", value: "\(d.tune.blocks) gelesen, \(d.tune.versions)-mal Version")
                LabeledContent("Verbunden", value: "\(d.tuneConnects)-mal")
                LabeledContent("Motor", value: ble.engineRunning ? "läuft" : "steht")
                ForEach(d.tuneRates) { r in
                    frameRow(r)
                }
                Button("Zündkurven jetzt lesen") { ble.readTuneProgram(force: true) }
                    .disabled(ble.tuneState != .live && ble.tuneState != .demo || ble.programReading)
            } header: {
                Text("123ignition")
            } footer: {
                Text("Je Frame-Typ: Anzahl, Rate, letztes Rohbyte und was die App daraus macht. Das Lesen der Zündkurven schickt nur Lesebefehle. Was dabei ankommt, steht unten im Protokoll, aber nur als Muster ohne Inhalt.")
            }
            .listRowBackground(Theme.surface)
            .font(.system(size: 14).monospacedDigit())

            Section {
                if let l = location.location {
                    LabeledContent("Genauigkeit", value: String(format: "±%.0f m", l.horizontalAccuracy))
                    LabeledContent("Tempo", value: l.speed >= 0 ? String(format: "%.1f km/h", l.speed * 3.6) : "kein Wert")
                    LabeledContent("Alter", value: String(format: "%.0f s", Date().timeIntervalSince(l.timestamp)))
                } else {
                    Text(location.denied ? "Ortung ist für die App gesperrt." : "Kein GPS-Punkt. GPS läuft nur, solange ein Gerät verbunden ist oder aufgezeichnet wird.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                }
            } header: {
                Text("GPS")
            }
            .listRowBackground(Theme.surface)
            .font(.system(size: 14).monospacedDigit())

            Section {
                ShareLink(item: report(d)) {
                    Label("Protokoll teilen", systemImage: "square.and.arrow.up")
                }
                Button("Zähler zurücksetzen") { store.resetCounters() }
                ForEach(d.log.suffix(60).reversed()) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(LinkDiagnostics.stamp(line.time))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Theme.muted)
                        Text(line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.fg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Protokoll")
            } footer: {
                Text("Neueste zuerst. Empfangene Daten der 123 erscheinen maskiert: h steht für eine Hex-Ziffer, _ für ein Leerzeichen, ¶ für das Zeilenende. So sieht man, ob die Antwort das erwartete Format hat, ohne dass der Pincode der Zündung je lesbar wird.")
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .tint(Theme.accent)
        .navigationTitle("Diagnose")
        .navigationBarTitleDisplayMode(.inline)
        .navBarStyle()
        .onAppear { store.visible = true }
        .onDisappear { store.visible = false }
    }

    private func checkRow(_ c: DiagCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: c.severity.symbol)
                .foregroundColor(c.severity.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(c.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.fg)
                    Spacer(minLength: 6)
                    Text(c.value)
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundColor(c.severity >= .warn ? c.severity.color : Theme.fg)
                }
                if !c.hint.isEmpty {
                    Text(c.hint)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func frameRow(_ r: TypeRate) -> some View {
        HStack {
            Text("'" + r.char + "'")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.accent)
                .frame(width: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.fg)
                Text("\(r.count) · " + String(format: "%.1f /s", r.perSecond))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Theme.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(decoded(r))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundColor(Theme.fg)
                Text(r.raw.map { String(format: "0x%02X", $0) } ?? "–")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.muted)
            }
        }
    }

    /// Rohbyte so umgerechnet, wie es der Parser tut
    private func decoded(_ r: TypeRate) -> String {
        guard let b = r.raw else { return "–" }
        let v = Double(b)
        switch r.type {
        case 0x30: return v * 50 > Tune123.maxPlausibleRPM ? "Platzhalter" : String(format: "%.0f U/min", v * 50)
        case 0x31: return String(format: "%.1f°", v * 0.2)
        case 0x32: return String(format: "%.0f kPa", v)
        case 0x33: return String(format: "%.0f °C", v - 30)
        case 0x34: return b & 0x01 == 0x01 ? "an" : "aus"
        case 0x35: return String(format: "%.2f A", v * 1.85 / 16)
        case 0x41: return String(format: "%.1f V", v * 14.1 / 64)
        default:   return String(format: "%d", Int(b))
        }
    }

    private func stateText(_ s: LinkState) -> String {
        switch s {
        case .searching:    return "sucht"
        case .connecting:   return "verbindet"
        case .live:         return "verbunden"
        case .demo:         return "Demo"
        case .bluetoothOff: return "Bluetooth aus"
        case .unauthorized: return "kein Zugriff"
        }
    }

    private func rssi(_ v: Int?) -> String {
        guard let v else { return "–" }
        let word = v >= -65 ? "gut" : (v >= -80 ? "mittel" : "schwach")
        return "\(v) dBm · " + word
    }

    private func report(_ d: LinkDiagnostics) -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        var head = ["Citroën Anzeige " + v + " (" + b + "), " + Format.dayTime(Date()),
                    "Anzeige: " + stateText(ble.bridgeState) + ", " + (ble.bridgeVersion ?? "Firmware unbekannt") + ", " + rssi(d.bridgeRSSI),
                    "123: " + stateText(ble.tuneState) + ", " + (d.tuneVariant ?? "?") + ", " + rssi(d.tuneRSSI)]
        head.append("")
        head.append("Selbsttest:")
        for c in checks {
            head.append("  " + c.title + ": " + c.value + (c.severity >= .warn ? "  (!)" : ""))
        }
        return d.report(header: head)
    }
}

extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}

// ── Einstellungen: Gemisch, Warnungen, Fahrzeug ──────────────────
struct MixtureSettingsView: View {
    @AppStorage(SettingKey.lambdaByTarget) private var byTarget = true
    @AppStorage(MixtureTargets.key(.idle)) private var idle = MixtureTargets.defaults.idle
    @AppStorage(MixtureTargets.key(.stage1)) private var stage1 = MixtureTargets.defaults.stage1
    @AppStorage(MixtureTargets.key(.transition)) private var transition = MixtureTargets.defaults.transition
    @AppStorage(MixtureTargets.key(.stage2)) private var stage2 = MixtureTargets.defaults.stage2
    @AppStorage(SettingKey.idleTargetRPM) private var idleRPM = 850.0

    var body: some View {
        Form {
            Section {
                Toggle("Lambda gegen das Ziel bewerten", isOn: $byTarget)
            } footer: {
                Text("An: Die Farbe der Lambda-Anzeige richtet sich nach dem Ziel des aktuellen Betriebsbereichs. Vollgas mit Lambda 0.88 ist dann grün, nicht rot. Dafür braucht es Drehzahl und Saugrohrdruck der 123. Aus, oder ohne 123: feste Grenzen um 1.00 wie auf dem Display im Auto.")
            }
            .listRowBackground(Theme.surface)

            Section {
                targetRow("Leerlauf", $idle)
                targetRow("Teillast", $stage1)
                targetRow("Übergang zur 2. Stufe", $transition)
                targetRow("Vollgas", $stage2)
                Button("Auf Standard zurücksetzen") {
                    let d = MixtureTargets.defaults
                    idle = d.idle
                    stage1 = d.stage1
                    transition = d.transition
                    stage2 = d.stage2
                }
            } header: {
                Text("Ziel-Lambda")
            } footer: {
                Text("Übliche Werte für einen luftgekühlten Vergasermotor: Leerlauf leicht fett für runden Lauf, Teillast um 1.00 für sparsames Fahren, Vollgas 0.86–0.90 für Leistung und kühle Brennräume. Gemisch-Check, Kennfeld „Δ Ziel“ und Düsen-Rechner nutzen dieselben Ziele.")
            }
            .listRowBackground(Theme.surface)

            Section {
                Stepper(value: $idleRPM, in: 700...1200, step: 50) {
                    LabeledContent("Leerlaufdrehzahl soll", value: String(format: "%.0f U/min", idleRPM))
                }
            } footer: {
                Text("Der Gemisch-Check meldet, wenn der Leerlauf deutlich darüber oder darunter liegt. Beim 2CV6 üblich: 800–850 U/min.")
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .tint(Theme.accent)
        .navigationTitle("Gemisch")
        .navigationBarTitleDisplayMode(.inline)
        .navBarStyle()
    }

    private func targetRow(_ title: String, _ value: Binding<Double>) -> some View {
        Stepper(value: value, in: MixtureTargets.range, step: 0.01) {
            LabeledContent(title, value: String(format: "%.2f", value.wrappedValue))
        }
    }
}

struct AlertSettingsView: View {
    @AppStorage(AlertSettings.soundKey) private var sound = true
    @AppStorage(Vehicle.massKey) private var mass = 700.0

    var body: some View {
        Form {
            Section {
                ForEach(AlertKind.allCases) { k in
                    AlertToggle(kind: k)
                }
            } header: {
                Text("Warnen bei")
            } footer: {
                Text("Eine Warnung erscheint groß über den Anzeigen, das iPhone vibriert, und in der laufenden Aufnahme wird eine Markierung gesetzt.")
            }
            .listRowBackground(Theme.surface)

            Section {
                Toggle("Ton", isOn: $sound)
            } footer: {
                Text("Kurzer Warnton zusätzlich zur Vibration. Der Stummschalter des iPhones gilt auch hier.")
            }
            .listRowBackground(Theme.surface)

            Section {
                Stepper(value: $mass, in: 500...1100, step: 10) {
                    LabeledContent("Masse mit Fahrer", value: String(format: "%.0f kg", mass))
                }
            } header: {
                Text("Fahrzeug")
            } footer: {
                Text("Für die geschätzte Leistung unter „Züge unter Last“. 2CV6 leer etwa 600 kg, dazu Fahrer, Tank und Gepäck.")
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .tint(Theme.accent)
        .navigationTitle("Warnungen und Fahrzeug")
        .navigationBarTitleDisplayMode(.inline)
        .navBarStyle()
    }
}

struct AlertToggle: View {
    let kind: AlertKind
    @AppStorage private var on: Bool

    init(kind: AlertKind) {
        self.kind = kind
        _on = AppStorage(wrappedValue: true, AlertKind.key(kind))
    }

    var body: some View {
        Toggle(isOn: $on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(kind.explanation)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
            }
        }
    }
}
