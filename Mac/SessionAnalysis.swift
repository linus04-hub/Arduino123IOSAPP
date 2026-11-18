import SwiftUI
import Charts

// ── Auswertung einer Messreihe ───────────────────────────────────
// Fuer Messreihen, die Gesamtauswertung und einzelne Fahrten:
// Gemisch-Check, Kennfeld, Verteilung je Bereich, Lambda ueber Drehzahl.

struct SessionAnalysisView: View {
    let session: TuningSession
    var pulls: PullSummary? = nil
    var tipIns: TipInSummary? = nil
    var compact = false

    @EnvironmentObject var lib: Library
    @State private var selected: DiagArea?

    private var diagnosis: Diagnosis {
        var input = DiagnosisInput(session: session)
        input.targets = lib.targets
        input.jets = lib.book.setup.jets
        input.idleTargetRPM = UserDefaults.standard.double(forKey: "idleTargetRPM").nonZero ?? 850
        input.pulls = pulls
        input.tipIns = tipIns
        return MixtureDiagnosis.run(input)
    }

    var body: some View {
        let d = diagnosis
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CheckCard(diagnosis: d, selected: $selected)
                    .frame(width: 400)
                KennfeldCard(session: session)
            }
            if let f = d.findings.first(where: { $0.area == selected }) ?? d.findings.first(where: { $0.severity >= .warn }) {
                FindingDetailCard(finding: f, session: session)
            }
            if !d.plan.isEmpty {
                Card(title: "In dieser Reihenfolge", symbol: "list.number") {
                    ForEach(Array(d.plan.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(i + 1)")
                                .font(.caption.weight(.heavy))
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(.orange))
                                .foregroundStyle(.black)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !compact {
                HStack(alignment: .top, spacing: 14) {
                    Card(title: "Verteilung je Bereich", symbol: "chart.bar.xaxis") {
                        DistributionChart(session: session, targets: lib.targets)
                            .frame(height: 230)
                    }
                    Card(title: "Lambda über Drehzahl", symbol: "circle.grid.cross") {
                        ScatterChart(session: session)
                            .frame(height: 230)
                    }
                }
            }
        }
        .onChange(of: session.id) { _, _ in selected = nil }
    }
}

extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

// ── Liste der Befunde ──
struct CheckCard: View {
    let diagnosis: Diagnosis
    @Binding var selected: DiagArea?

    var body: some View {
        Card(title: "Gemisch-Check", symbol: "stethoscope") {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: diagnosis.worst.icon)
                    .foregroundStyle(diagnosis.worst.tint)
                    .font(.title3)
                Text(diagnosis.headline)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(String(format: "%.0f min ausgewertet", diagnosis.seconds / 60)
                 + (diagnosis.steady ? ", nur ruhige Fahrt bei warmem Motor" : ", alle Werte"))
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(diagnosis.findings) { f in
                    Divider()
                    Button {
                        selected = f.area
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: f.severity.icon)
                                .foregroundStyle(f.severity.tint)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.area.title).fontWeight(.medium)
                                Text(sub(f)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(f.value).fontWeight(.semibold).monospacedDigit()
                                Text(f.verdict).font(.caption).foregroundStyle(f.severity.tint)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selected == f.area ? Color.accentColor.opacity(0.15) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sub(_ f: Finding) -> String {
        var p: [String] = []
        if let t = f.target { p.append(String(format: "Ziel %.2f", t)) }
        if f.seconds > 0 { p.append(f.seconds < 30 ? "<1 min" : TimeText.duration(f.seconds)) }
        if f.preliminary { p.append("vorläufig") }
        return p.isEmpty ? (f.area.regime?.area ?? "") : p.joined(separator: " · ")
    }
}

// ── Einzelheiten zu einem Befund ──
struct FindingDetailCard: View {
    let finding: Finding
    let session: TuningSession
    @EnvironmentObject var lib: Library

    var body: some View {
        let f = finding
        Card(title: f.area.title, symbol: f.area.symbol,
             trailing: AnyView(SeverityChip(text: f.verdict, severity: f.severity))) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(f.summary).font(.body).fixedSize(horizontal: false, vertical: true)
                    if !f.actions.isEmpty {
                        Text("Was du tun kannst").font(.subheadline.weight(.semibold))
                        ForEach(Array(f.actions.enumerated()), id: \.offset) { i, a in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(i + 1).").monospacedDigit().foregroundStyle(.orange)
                                Text(a).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if let j = f.jet {
                        HStack(spacing: 6) {
                            Image(systemName: "function")
                            if let o = j.old, let n = j.new {
                                Text(j.circuit.jetName + ": " + JetAdvice.num(o) + " → " + JetAdvice.num(n.rounded()))
                                    .fontWeight(.semibold)
                            } else {
                                Text(String(format: "%+.0f %% Kraftstoff im Kreis ", j.fuelPercent) + j.circuit.jetName)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                    }
                    if !f.causes.isEmpty {
                        Text("Mögliche Ursachen").font(.subheadline.weight(.semibold))
                        ForEach(Array(f.causes.enumerated()), id: \.offset) { _, c in
                            Label(c, systemImage: "questionmark.circle")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(f.evidence.enumerated()), id: \.offset) { _, e in
                        Text(e).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if f.byRPM.count >= 2 {
                        Chart {
                            if let t = f.target {
                                RectangleMark(xStart: .value("U/min", 750.0), xEnd: .value("U/min", 6250.0),
                                              yStart: .value("λ", t - 0.04), yEnd: .value("λ", t + 0.04))
                                    .foregroundStyle(.green.opacity(0.12))
                                RuleMark(y: .value("Ziel", t))
                                    .foregroundStyle(.green)
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            }
                            ForEach(f.byRPM) { p in
                                LineMark(x: .value("U/min", p.rpm), y: .value("λ", p.lambda))
                                    .foregroundStyle(.primary)
                                PointMark(x: .value("U/min", p.rpm), y: .value("λ", p.lambda))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .chartYScale(domain: 0.75...1.25)
                        .chartXScale(domain: 750.0...6250.0)
                        .rpmAxis()
                        .frame(height: 170)
                    }
                }
                .frame(width: 380, alignment: .leading)
            }
        }
    }
}

// ── Kennfeld mit Umschalter ──
struct KennfeldCard: View {
    let session: TuningSession
    @EnvironmentObject var lib: Library
    @AppStorage("mac.mapMode") private var mode: MapMode = .delta
    @AppStorage("mac.mapSteady") private var steadyOnly = true

    var body: some View {
        let steady = steadyOnly && session.steadyCells != nil
        let targets = lib.targets
        let data = MapData(session: session, mode: mode, steady: steady, targets: targets)
        let counts = (0..<TuningSession.rows).map { r in
            (0..<TuningSession.cols).map { c in session.count(row: r, col: c, steady: steady) }
        }
        let labels: [[String?]]? = mode == .count
            ? counts.map { row in row.map { $0 > 0 ? "\($0)" : nil } }
            : nil
        Card(title: "Kennfeld", symbol: "square.grid.3x3.fill") {
            ViewThatFits(in: .horizontal) {
                HStack {
                    modePicker
                    Spacer(minLength: 12)
                    steadyToggle
                }
                VStack(alignment: .leading, spacing: 8) {
                    modePicker
                    steadyToggle
                }
            }
            HeatmapView(values: data.values, image: data.image, stops: mode.stops, digits: mode.digits,
                        signed: mode == .delta, counts: mode == .count ? nil : counts, labels: labels,
                        tooltip: { r, c in tooltip(r, c, steady: steady, targets: targets) })
                .frame(minHeight: 330)
            ColorLegend(stops: mode.stops, labels: mode.legend)
            Text("Waagrecht Drehzahl, senkrecht Saugrohrdruck in kPa (oben Vollgas). Gestrichelt: Grenzen der Betriebsbereiche. Kleine Zahl: Anzahl Messwerte.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modePicker: some View {
        Picker("Ansicht", selection: $mode) {
            ForEach(MapMode.allCases) { m in Text(m.title).tag(m) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder private var steadyToggle: some View {
        if session.steadyCells != nil {
            Toggle("Nur ruhige Fahrt, Motor warm", isOn: $steadyOnly)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Nur Werte bei gleichmäßiger Fahrt und warmem Motor. Gasstöße, Schub und Kaltlauf fallen raus.")
        }
    }

    private func tooltip(_ r: Int, _ c: Int, steady: Bool, targets: MixtureTargets) -> [String] {
        let regime = Regime.of(row: r, col: c)
        let lo = TuningSession.rowLow(r)
        var out = [String(format: "%.0f U/min · %.0f–%.0f kPa", TuningSession.colCenter(c), lo, lo + 10),
                   regime.title]
        let n = session.count(row: r, col: c, steady: steady)
        if let l = session.lambda(row: r, col: c, steady: steady) {
            out.append(String(format: "λ %.3f aus %d Werten", l, n))
            if let s = session.spread(row: r, col: c, steady: steady) { out.append(String(format: "Streuung ±%.3f", s)) }
            if let t = targets.target(regime) {
                let j = MixtureJudge.judge(lambda: l, regime: regime, targets: targets)
                out.append(String(format: "Ziel %.2f, %+.3f: ", t, l - t) + j.text)
            }
        } else {
            out.append(n > 0 ? "\(n) Werte, zu wenige" : "keine Werte")
        }
        if let a = session.advance(row: r, col: c) { out.append(String(format: "Zündung %.1f°", a)) }
        return out
    }
}

// ── Verteilung von Lambda je Bereich ──
struct DistributionChart: View {
    let session: TuningSession
    let targets: MixtureTargets

    struct Bin: Identifiable {
        var regime: Regime
        var lambda: Double
        var share: Double
        var id: String { regime.rawValue + String(lambda) }
    }

    var body: some View {
        let bins = makeBins()
        if bins.isEmpty {
            EmptyHint(text: "Noch keine Verteilung. Sie wird ab App-Version 2.0 mitgeschrieben.", symbol: "chart.bar")
        } else {
            Chart(bins) { b in
                LineMark(x: .value("λ", b.lambda), y: .value("Anteil", b.share))
                    .foregroundStyle(by: .value("Bereich", b.regime.title))
                    .interpolationMethod(.catmullRom)
            }
            .chartForegroundStyleScale(domain: Regime.judged.map { $0.title }, range: Regime.judged.map { $0.tint })
            .chartXScale(domain: 0.70...1.30)
            .chartYAxis {
                AxisMarks { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.0f %%", d * 100)) } }
                }
            }
        }
    }

    private func makeBins() -> [Bin] {
        guard let hist = session.hist else { return [] }
        var out: [Bin] = []
        for r in Regime.judged {
            guard let h = hist[r.rawValue], h.count == TuningSession.histBins else { continue }
            let total = h.reduce(0, +)
            guard total >= 40 else { continue }
            for (i, n) in h.enumerated() {
                out.append(Bin(regime: r, lambda: TuningSession.histLow + (Double(i) + 0.5) * TuningSession.histStep,
                               share: Double(n) / Double(total)))
            }
        }
        return out
    }
}

// ── Punktewolke ──
struct ScatterChart: View {
    let session: TuningSession

    struct Dot: Identifiable {
        var id: Int
        var rpm: Double
        var lambda: Double
        var load: String
    }

    static let loads = ["unter 40 kPa", "40–70 kPa", "70–90 kPa", "ab 90 kPa"]
    static let loadColors: [Color] = [Color(red: 0.3, green: 0.55, blue: 0.95), .teal, .orange, .red]

    var body: some View {
        let dots = session.lambdaPoints.enumerated().compactMap { i, p -> Dot? in
            guard p.v > 0.6, p.v < 1.4 else { return nil }
            let m = Double(p.m ?? 0)
            let load = m < 40 ? Self.loads[0] : (m < 70 ? Self.loads[1] : (m < 90 ? Self.loads[2] : Self.loads[3]))
            return Dot(id: i, rpm: Double(p.r), lambda: Double(p.v), load: load)
        }
        if dots.isEmpty {
            EmptyHint(text: "Keine Einzelwerte in dieser Messreihe.", symbol: "circle.grid.cross")
        } else {
            Chart(dots) { d in
                PointMark(x: .value("U/min", d.rpm), y: .value("λ", d.lambda))
                    .foregroundStyle(by: .value("Last", d.load))
                    .symbolSize(10)
                    .opacity(0.6)
            }
            .chartForegroundStyleScale(domain: Self.loads, range: Self.loadColors)
            .chartYScale(domain: 0.7...1.3)
            .chartXScale(domain: 500.0...6000.0)
            .rpmAxis()
        }
    }
}
