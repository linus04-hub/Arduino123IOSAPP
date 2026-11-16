import SwiftUI

// ── Duesen-Rechner ───────────────────────────────────────────────
// Rechenweg und Vergaserkreise stehen in Mixture.swift.

// ── Ansicht ──────────────────────────────────────────────────────
struct JetCalcView: View {
    let sessions: [TuningSession]        // erste = "Aktuell"
    var cell: MapCell? = nil             // aus dem Kennfeld angetippt
    var steady = false                   // die Zelle aus dem Kennfeld "nur ruhige Fahrt"
    var preset: CarbCircuit? = nil       // aus dem Gemisch-Check

    @State private var sessionID: UUID?
    @State private var circuit: CarbCircuit = .stage1
    @State private var onlyCell = true
    @State private var jet: Double = 0
    @State private var target: Double = 1.0
    @State private var loaded = false

    private var session: TuningSession? {
        sessions.first { $0.id == sessionID } ?? sessions.first
    }

    /// Gemessenes Lambda und Anzahl Werte fuer die gewaehlte Quelle
    private var measured: (lambda: Double, count: Int)? {
        guard let s = session else { return nil }
        if onlyCell, let c = cell, let l = s.lambda(row: c.row, col: c.col, steady: steady) {
            return (l, s.count(row: c.row, col: c.col, steady: steady))
        }
        // wenn vorhanden, nur ruhige Fahrt: Gasstoesse verfaelschen den Mittelwert
        guard let st = s.stats(circuit, steady: s.hasSteady) else { return nil }
        return (st.lambda, st.count)
    }

    var body: some View {
        Form {
            Section {
                if sessions.count > 1 {
                    Picker("Messreihe", selection: $sessionID) {
                        ForEach(sessions) { s in
                            Text(s.id == sessions.first?.id ? "Aktuell" : s.name).tag(UUID?.some(s.id))
                        }
                    }
                }
                Picker("Bereich", selection: $circuit) {
                    ForEach(CarbCircuit.allCases) { c in
                        Text(c.title).tag(c)
                    }
                }
                if cell != nil {
                    Toggle("Nur die angetippte Stelle", isOn: $onlyCell)
                }
                LabeledContent("Lambda gemessen", value: measuredText)
            } header: {
                Text("Messung")
            } footer: {
                Text(sourceFooter)
            }
            .listRowBackground(Theme.surface)

            Section {
                LabeledContent(circuit.jetName) {
                    TextField("z. B. 115", value: $jet, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                }
                LabeledContent("Ziel-Lambda") {
                    TextField("1,00", value: $target, format: .number.precision(.fractionLength(2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                }
            } header: {
                Text("Deine Bedüsung")
            } footer: {
                Text("Düsengröße so eingeben, wie sie auf der Düse steht (Durchmesser in 1/100 mm). Die App merkt sich die Werte je Bereich.")
            }
            .listRowBackground(Theme.surface)

            Section {
                resultRows
            } header: {
                Text("Vorschlag")
            } footer: {
                Text("Faustregel: Der Sprit durch eine Düse wächst etwa mit ihrem Querschnitt. Luftkorrekturdüse, Schwimmerstand und Zündung spielen mit. Immer nur eine Sache ändern und neu messen. Im Leerlauf zuerst die Gemischschraube nutzen.")
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .tint(Theme.accent)
        .navigationTitle("Düsen-Rechner")
        .navigationBarTitleDisplayMode(.inline)
        .navBarStyle()
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if sessionID == nil { sessionID = sessions.first?.id }
            if let c = cell, let k = CarbCircuit.of(row: c.row, col: c.col) { circuit = k }
            if let p = preset { circuit = p }
            loadInputs()
        }
        .onChange(of: circuit) { _ in loadInputs() }
        .onChange(of: jet) { v in UserDefaults.standard.set(v, forKey: "jet." + circuit.rawValue) }
        .onChange(of: target) { v in UserDefaults.standard.set(v, forKey: "target." + circuit.rawValue) }
    }

    @ViewBuilder
    private var resultRows: some View {
        if let m = measured, let new = JetMath.newSize(old: jet, lambdaNow: m.lambda, lambdaTarget: target) {
            let diff = (m.lambda / target - 1) * 100
            LabeledContent("Abweichung", value: deviationText(diff))
            LabeledContent("Rechnerisch", value: String(format: "%.1f", new))
            LabeledContent("Vorschlag") {
                Text(suggestion(new))
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundColor(Theme.accent)
            }
        } else if measured == nil {
            Text("Noch zu wenige Werte in diesem Bereich. Ein paar Minuten so fahren, dann füllt sich das Kennfeld.")
                .font(.system(size: 13))
                .foregroundColor(Theme.muted)
        } else {
            Text("Düsengröße und Ziel-Lambda eingeben.")
                .font(.system(size: 13))
                .foregroundColor(Theme.muted)
        }
    }

    private var measuredText: String {
        guard let m = measured else { return "keine Daten" }
        return String(format: "%.3f", m.lambda) + " · \(m.count) Werte"
    }

    private var sourceFooter: String {
        if onlyCell, let c = cell {
            let lo = TuningSession.rowLow(c.row)
            return String(format: "Nur die Zelle %.0f U/min, %.0f–%.0f kPa. Gehört zu: ", TuningSession.colCenter(c.col), lo, lo + 10) + circuit.title + "."
        }
        return circuit.area + ". Die Zuordnung zum Vergaserkreis ist grob."
            + ((session?.hasSteady ?? false) ? " Gerechnet wird mit ruhiger Fahrt bei warmem Motor." : "")
    }

    private func deviationText(_ percent: Double) -> String {
        if abs(percent) < 1 { return "passt (unter 1 %)" }
        return percent < 0 ? String(format: "%.0f %% zu fett", -percent) : String(format: "%.0f %% zu mager", percent)
    }

    private func suggestion(_ new: Double) -> String {
        let rounded = new.rounded()
        if abs(new - jet) < 0.5 { return "Düse passt" }
        let dir = new < jet ? "kleiner, magerer" : "größer, fetter"
        return String(format: "%.0f", rounded) + " (" + dir + ")"
    }

    private func loadInputs() {
        let d = UserDefaults.standard
        jet = d.double(forKey: "jet." + circuit.rawValue)
        target = d.object(forKey: "target." + circuit.rawValue) as? Double ?? circuit.defaultTarget
    }
}
