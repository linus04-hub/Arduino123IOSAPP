import SwiftUI
import Charts

// ── Vergleich: zwei Messreihen oder Zeitraeume gegenueber ────────
// Typisch: vor und nach einer Aenderung am Vergaser.

struct ComparePage: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var app: AppState
    @State private var a: TuningSession?
    @State private var b: TuningSession?
    @State private var busy = false

    struct Option: Identifiable, Hashable {
        var choice: SourceChoice
        var title: String
        var id: String { title }
    }

    private var options: [Option] {
        var out: [Option] = []
        for e in lib.book.entries.sorted(by: { $0.date > $1.date }) {
            out.append(Option(choice: .before(e.id), title: "Vor " + Fmt.day(e.date) + ": " + e.label))
            out.append(Option(choice: .after(e.id), title: "Nach " + Fmt.day(e.date) + ": " + e.label))
        }
        for p in PeriodChoice.allCases {
            out.append(Option(choice: .period(p), title: p.title))
        }
        for s in lib.sessions {
            out.append(Option(choice: .session(s.id), title: "Messreihe " + s.name))
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Vergleich", subtitle: "A gegen B, zum Beispiel vor und nach einer Änderung am Vergaser")
                HStack(spacing: 16) {
                    picker("A", $app.compareA)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    picker("B", $app.compareB)
                }
                if busy {
                    ProgressView("Rechne …").frame(maxWidth: .infinity, minHeight: 120)
                } else if let a, let b {
                    content(a, b)
                } else {
                    EmptyHint(text: "Oben zwei Quellen wählen.", symbol: "arrow.left.arrow.right")
                }
            }
            .padding(20)
        }
        .onAppear(perform: defaults)
        .task(id: key) { await resolveBoth() }
    }

    private var key: String {
        "\(String(describing: app.compareA))|\(String(describing: app.compareB))|\(lib.revision)"
    }

    private func picker(_ label: String, _ sel: Binding<SourceChoice?>) -> some View {
        Picker(label, selection: sel) {
            Text("–").tag(SourceChoice?.none)
            ForEach(options) { o in Text(o.title).tag(SourceChoice?.some(o.choice)) }
        }
        .frame(maxWidth: 420)
    }

    private func defaults() {
        guard app.compareA == nil || app.compareB == nil else { return }
        // Die letzte Aenderung, nach der schon gefahren wurde
        let entries = lib.book.entries.sorted { $0.date > $1.date }
        let stats = lib.allStats
        if let e = entries.first(where: { e in stats.contains { $0.start >= e.date } && stats.contains { $0.start < e.date } }) {
            app.compareA = .before(e.id)
            app.compareB = .after(e.id)
        } else if lib.sessions.count >= 2 {
            app.compareA = .session(lib.sessions[1].id)
            app.compareB = .session(lib.sessions[0].id)
        } else {
            app.compareA = .period(.days90)
            app.compareB = .period(.days30)
        }
    }

    private func resolveBoth() async {
        guard let ca = app.compareA, let cb = app.compareB else {
            a = nil
            b = nil
            return
        }
        busy = true
        a = await resolve(ca)
        b = await resolve(cb)
        busy = false
    }

    private func resolve(_ c: SourceChoice) async -> TuningSession? {
        let title = options.first { $0.choice == c }?.title ?? ""
        switch c {
        case .session(let id):
            return lib.sessions.first { $0.id == id }
        case .period(let p):
            return await lib.aggregate(p.period(lib.book), name: title)
        case .before(let id), .after(let id):
            let sorted = lib.book.entries.sorted { $0.date < $1.date }
            guard let i = sorted.firstIndex(where: { $0.id == id }) else { return nil }
            let e = sorted[i]
            let window = 30.0 * 86_400
            if case .before = c {
                let prev = i > 0 ? sorted[i - 1].date : Date.distantPast
                return await lib.aggregate(Period(from: max(prev, e.date.addingTimeInterval(-window)), to: e.date), name: title)
            } else {
                let next = i + 1 < sorted.count ? sorted[i + 1].date : Date.distantFuture
                return await lib.aggregate(Period(from: e.date, to: min(next, e.date.addingTimeInterval(window))), name: title)
            }
        }
    }

    @ViewBuilder
    private func content(_ a: TuningSession, _ b: TuningSession) -> some View {
        let steady = a.hasSteady && b.hasSteady
        let targets = lib.targets
        let ra = MixtureDiagnosis.collect(a, steady: steady)
        let rb = MixtureDiagnosis.collect(b, steady: steady)
        HStack(alignment: .top, spacing: 14) {
            Card(title: "Gemisch je Bereich", symbol: "chart.bar.doc.horizontal") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    GridRow {
                        Text("Bereich")
                        Text("A").gridColumnAlignment(.trailing)
                        Text("B").gridColumnAlignment(.trailing)
                        Text("B − A").gridColumnAlignment(.trailing)
                        Text("Ziel").gridColumnAlignment(.trailing)
                        Text("B ist")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Regime.judged) { r in
                        let la = ra[r].flatMap { $0.n >= MixtureDiagnosis.fewSamples ? $0.mean : nil }
                        let lb = rb[r].flatMap { $0.n >= MixtureDiagnosis.fewSamples ? $0.mean : nil }
                        let jb = lb.map { MixtureJudge.judge(lambda: $0, regime: r, targets: targets) }
                        GridRow {
                            HStack(spacing: 6) { Circle().fill(r.tint).frame(width: 8, height: 8); Text(r.title) }
                            Text(Fmt.num(la, 3))
                            Text(Fmt.num(lb, 3)).fontWeight(.semibold)
                            Text(la != nil && lb != nil ? Fmt.signed(lb! - la!, 3) : "–")
                                .foregroundStyle(improvement(la, lb, target: targets.target(r)))
                            Text(Fmt.num(targets.target(r), 2)).foregroundStyle(.secondary)
                            if let jb { SeverityChip(text: jb.text, severity: jb.severity) } else { Text("–") }
                        }
                        .monospacedDigit()
                    }
                }
                Text("Grün: B liegt näher am Ziel als A. Rot: weiter weg." + (steady ? " Nur ruhige Fahrt bei warmem Motor." : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "Lambda über Drehzahl", symbol: "chart.xyaxis.line") {
                CompareCurves(a: a, b: b, steady: steady, target: targets.stage2, cruiseTarget: targets.stage1)
                    .frame(height: 260)
            }
        }
        let diff = MapDiff.lambda(a, b, steady: steady)
        Card(title: "Kennfeld: B minus A", symbol: "square.grid.3x3.fill") {
            HeatmapView(values: diff, image: MapData.image(diff, stops: Self.diffStops), stops: Self.diffStops,
                        digits: 2, signed: true, emptyDim: 0.12,
                        tooltip: { r, c in
                            let la = a.lambda(row: r, col: c, steady: steady)
                            let lb = b.lambda(row: r, col: c, steady: steady)
                            return [String(format: "%.0f U/min · %.0f–%.0f kPa", TuningSession.colCenter(c),
                                           TuningSession.rowLow(r), TuningSession.rowLow(r) + 10),
                                    "A: " + Fmt.num(la, 3) + "   B: " + Fmt.num(lb, 3),
                                    "B − A: " + Fmt.signed(la != nil && lb != nil ? lb! - la! : nil, 3)]
                        })
                .frame(height: 340)
            ColorLegend(stops: Self.diffStops, labels: ("B fetter −0.10", "gleich", "B magerer +0.10"))
        }
        HStack(alignment: .top, spacing: 14) {
            CheckCard(diagnosis: diagnose(a), selected: .constant(nil))
            CheckCard(diagnosis: diagnose(b), selected: .constant(nil))
        }
    }

    static let diffStops: [(Double, RGB)] = [
        (-0.10, RGB(70, 100, 255)), (-0.03, RGB(150, 190, 255)), (0, RGB(235, 235, 235)),
        (0.03, RGB(255, 190, 140)), (0.10, RGB(231, 76, 60))
    ]

    private func improvement(_ a: Double?, _ b: Double?, target: Double?) -> Color {
        guard let a, let b, let t = target else { return .secondary }
        let da = abs(a - t), db = abs(b - t)
        if db < da - 0.01 { return .green }
        if db > da + 0.01 { return .red }
        return .secondary
    }

    private func diagnose(_ s: TuningSession) -> Diagnosis {
        var input = DiagnosisInput(session: s)
        input.targets = lib.targets
        input.jets = lib.book.setup.jets
        input.idleTargetRPM = UserDefaults.standard.double(forKey: "idleTargetRPM").nonZero ?? 850
        return MixtureDiagnosis.run(input)
    }
}

struct CompareCurves: View {
    let a: TuningSession
    let b: TuningSession
    let steady: Bool
    let target: Double
    let cruiseTarget: Double

    struct P: Identifiable {
        var rpm: Double
        var lambda: Double
        var series: String
        var id: String { series + String(rpm) }
    }

    var body: some View {
        var pts: [P] = []
        for (s, name) in [(a, "A"), (b, "B")] {
            for v in CurveData.byRPM(s, rows: CurveData.fullLoad, steady: steady) {
                pts.append(P(rpm: v.rpm, lambda: v.lambda, series: name + " Vollgas"))
            }
            for v in CurveData.byRPM(s, rows: CurveData.partLoad, steady: steady) {
                pts.append(P(rpm: v.rpm, lambda: v.lambda, series: name + " Teillast"))
            }
        }
        return Chart {
            RuleMark(y: .value("Ziel Vollgas", target))
                .foregroundStyle(.red.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            RuleMark(y: .value("Ziel Teillast", cruiseTarget))
                .foregroundStyle(.green.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ForEach(pts) { p in
                LineMark(x: .value("U/min", p.rpm), y: .value("λ", p.lambda))
                    .foregroundStyle(by: .value("Reihe", p.series))
                    .lineStyle(StrokeStyle(lineWidth: p.series.hasPrefix("B") ? 2.5 : 1.5,
                                           dash: p.series.hasPrefix("A") ? [5, 3] : []))
                PointMark(x: .value("U/min", p.rpm), y: .value("λ", p.lambda))
                    .foregroundStyle(by: .value("Reihe", p.series))
                    .symbolSize(16)
            }
        }
        .chartForegroundStyleScale(domain: ["A Vollgas", "B Vollgas", "A Teillast", "B Teillast"],
                                   range: [Color.red.opacity(0.55), Color.red, Color.green.opacity(0.55), Color.green])
        .chartYScale(domain: 0.8...1.15)
        .chartXScale(domain: 750.0...6250.0)
        .rpmAxis()
        .chartLegend(position: .bottom)
    }
}
