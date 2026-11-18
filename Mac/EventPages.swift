import SwiftUI
import Charts

// ── Zuege unter Last und Gasstoesse ──────────────────────────────

struct PullItem: Identifiable {
    let pull: Pull
    let a: PullAnalysis
    var id: UUID { pull.id }
    static let leanVerdicts: [PullAnalysis.Verdict] = [.lean, .leanTop, .starving]
    var label: String { Fmt.day(pull.time) + " " + String(Fmt.time(pull.time).prefix(5)) }
}

struct PullsPage: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var app: AppState
    @State private var kind = 0       // 0 Zuege, 1 Dauervollgas

    var body: some View {
        let target = lib.targets.stage2
        let vehicle = lib.vehicle
        let all = lib.allPulls.map { PullItem(pull: $0, a: PullAnalysis($0, target: target, vehicle: vehicle)) }
        let items = all.filter { kind == 0 ? $0.pull.kind == .pull : $0.pull.kind == .steady }
        let chosen = items.filter { app.pullSelection.contains($0.id) }
        let shown = chosen.isEmpty ? Array(items.prefix(4)) : chosen
        let peaks = all.compactMap { PowerSanity.ok($0.a.peak?.kW) }
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .bottom) {
                        PageHeader(title: "Züge unter Last",
                                   subtitle: "Vollgas ab 80 kPa: Lambda über der Drehzahl und geschätzte Radleistung")
                        Picker("", selection: $kind) {
                            Text("Züge").tag(0)
                            Text("Dauervollgas").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        StatTile(title: "Aufgezeichnet", value: "\(all.count)",
                                 detail: "\(all.filter { $0.pull.kind == .steady }.count) davon Dauervollgas")
                        let lean = all.filter { PullItem.leanVerdicts.contains($0.a.verdict) }.count
                        StatTile(title: "Mager", value: "\(lean)", detail: "Züge mit Lambda über dem Ziel",
                                 tint: lean > 0 ? .red : .green)
                        StatTile(title: "Leistung, bester Zug", value: peaks.max().map { String(format: "%.0f kW", $0) } ?? "–",
                                 detail: peaks.max().map { String(format: "≈ %.0f PS am Rad", $0 * 1.36) } ?? "")
                        StatTile(title: "Leistung, Schnitt", value: peaks.isEmpty ? "–" : String(format: "%.1f kW", peaks.reduce(0, +) / Double(peaks.count)),
                                 detail: String(format: "%.0f kg angenommen", vehicle.mass))
                    }
                    Card(title: "Leistung über die Zeit", symbol: "bolt.fill") {
                        PowerTrend(points: Trend.power(lib.allPulls, target: target, vehicle: vehicle), entries: lib.book.entries)
                            .frame(height: 220)
                        Text("Höchste geschätzte Radleistung je Zug. Nur vergleichbar bei ähnlicher Strecke, gleichem Gang und ohne Wind.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if shown.isEmpty {
                        EmptyHint(text: "Noch keine Züge erkannt. Im dritten Gang ab 2000 U/min mit Vollgas durchziehen.", symbol: "gauge.with.dots.needle.67percent")
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            Card(title: kind == 0 ? "Lambda über Drehzahl" : "Lambda über die Zeit", symbol: "chart.xyaxis.line") {
                                PullLambdaChart(items: shown, overTime: kind == 1, target: target)
                                    .frame(height: 260)
                            }
                            if kind == 0 {
                                Card(title: "Leistung über Drehzahl", symbol: "bolt") {
                                    PullPowerChart(items: shown)
                                        .frame(height: 260)
                                }
                            }
                        }
                        Text(chosen.isEmpty ? "Gezeigt: die letzten \(shown.count). Unten in der Tabelle auswählen (⌘-Klick für mehrere)." : "Gezeigt: \(chosen.count) ausgewählt.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: .infinity)
            Divider()
            Table(items, selection: $app.pullSelection) {
                TableColumn("Datum") { i in Text(Fmt.date(i.pull.time)) }
                    .width(min: 150, ideal: 170)
                TableColumn("Drehzahl") { i in
                    Text(String(format: "%.0f – %.0f", i.a.rpmFrom, i.a.rpmTo)).monospacedDigit()
                }
                TableColumn("Dauer") { i in Text(String(format: "%.1f s", i.a.duration)).monospacedDigit() }
                TableColumn("Saugrohr") { i in Text(Fmt.num(i.a.mapMean, 0, unit: "kPa")).monospacedDigit() }
                TableColumn("Ø λ") { i in Text(Fmt.num(i.a.lambdaMean, 3)).monospacedDigit() }
                TableColumn("mager ab") { i in Text(i.a.leanFrom.map { String(format: "%.0f", $0) } ?? "–").monospacedDigit() }
                TableColumn("Leistung") { i in Text(PowerSanity.ok(i.a.peak?.kW).map { String(format: "%.1f kW", $0) } ?? "–").monospacedDigit() }
                TableColumn("Gang") { i in Text(i.a.ratio.map { String(format: "%.1f km/h je 1000", $0) } ?? "–").monospacedDigit() }
                TableColumn("Urteil") { i in
                    let v = PullVerdictText.of(i.a.verdict)
                    SeverityChip(text: v.0, severity: v.1)
                }
            }
            .frame(height: 240)
        }
    }
}

struct PowerTrend: View {
    let points: [TrendPoint]
    let entries: [LogEntry]

    var body: some View {
        if points.isEmpty {
            EmptyHint(text: "Noch keine Leistungswerte. Dafür braucht es GPS-Tempo während des Zugs.", symbol: "bolt")
        } else {
            Chart {
                ForEach(entries) { e in
                    RuleMark(x: .value("Datum", e.date))
                        .foregroundStyle(Color.orange.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text(e.shortLabel).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                        }
                }
                ForEach(points) { p in
                    PointMark(x: .value("Datum", p.date), y: .value("kW", p.value))
                        .foregroundStyle(.orange)
                        .symbolSize(30)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .padding(.top, 14)
        }
    }
}

struct PullLambdaChart: View {
    let items: [PullItem]
    let overTime: Bool
    let target: Double

    struct P: Identifiable {
        var x: Double
        var y: Double
        var series: String
        var id: String
    }

    var body: some View {
        var pts: [P] = []
        for it in items {
            let s = it.pull.samples
            for i in s.indices {
                guard let l = s[i].lambda, l < 2 else { continue }
                // Lambda dem Punkt davor zuordnen (Laufzeit bis zur Sonde)
                let ref = s[max(0, i - 1)]
                pts.append(P(x: overTime ? Double(s[i].t) : Double(ref.rpm), y: Double(l), series: it.label,
                             id: it.id.uuidString + "\(i)"))
            }
        }
        return Chart {
            RuleMark(y: .value("Ziel", target))
                .foregroundStyle(.green.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            ForEach(pts) { p in
                LineMark(x: .value(overTime ? "s" : "U/min", p.x), y: .value("λ", p.y))
                    .foregroundStyle(by: .value("Zug", p.series))
            }
        }
        .chartYScale(domain: 0.75...1.20)
        .chartLegend(position: .bottom)
    }
}

struct PullPowerChart: View {
    let items: [PullItem]

    struct P: Identifiable {
        var rpm: Double
        var kW: Double
        var series: String
        var id: String { series + String(rpm) }
    }

    var body: some View {
        let pts = items.flatMap { it in it.a.power.filter { PowerSanity.ok($0.kW) != nil }.map { P(rpm: $0.rpm, kW: $0.kW, series: it.label) } }
        if pts.isEmpty {
            EmptyHint(text: "Ohne GPS-Tempo keine Leistung.", symbol: "bolt.slash")
        } else {
            Chart(pts) { p in
                LineMark(x: .value("U/min", p.rpm), y: .value("kW", p.kW))
                    .foregroundStyle(by: .value("Zug", p.series))
                    .interpolationMethod(.catmullRom)
            }
            .rpmAxis()
            .chartLegend(position: .bottom)
        }
    }
}

// ── Gasstoesse ──
struct TipInsPage: View {
    @EnvironmentObject var lib: Library

    struct Item: Identifiable {
        let e: TipInEvent
        var id: UUID { e.id }
    }

    var body: some View {
        let events = lib.allTipIns
        let sum = events.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Gasstöße", subtitle: "Wie das Gemisch beim schnellen Gasgeben reagiert. Zeigt, ob die Beschleunigerpumpe passt.")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    StatTile(title: "Erkannt", value: "\(events.count)")
                    StatTile(title: "Mit Magerloch", value: sum.map { String(format: "%.0f %%", Double($0.lean) / Double(max(1, $0.count)) * 100) } ?? "–",
                             detail: "kurz mindestens 0.08 magerer",
                             tint: (sum.map { Double($0.lean) / Double(max(1, $0.count)) } ?? 0) >= 0.4 ? .orange : .primary)
                    StatTile(title: "Zu fett", value: "\(sum?.rich ?? 0)", detail: "unter λ 0.80")
                    StatTile(title: "Ø Ausschlag", value: sum.map { String(format: "+%.3f", $0.avgLeanSpike) } ?? "–")
                }
                if events.isEmpty {
                    EmptyHint(text: "Noch keine Gasstöße erkannt.", symbol: "waveform.path.ecg")
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        Card(title: "Ausschlag über die Zeit", symbol: "chart.dots.scatter") {
                            TipSpikeChart(events: events, entries: lib.book.entries)
                                .frame(height: 240)
                        }
                        Card(title: "Die letzten 20 übereinander", symbol: "waveform") {
                            TipTraceChart(events: Array(events.prefix(20)))
                                .frame(height: 240)
                            Text("Lambda ab 1 s vor dem Gasstoß. Bleibt die Kurve flach oder geht nach unten, arbeitet die Pumpe.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Card(title: "Liste", symbol: "list.bullet") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            GridRow {
                                Text("Zeit"); Text("vorher"); Text("magerster"); Text("fettester"); Text("Drehzahl"); Text("Saugrohr"); Text("")
                            }
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(events.prefix(60)) { e in
                                GridRow {
                                    Text(Fmt.date(e.time))
                                    Text(String(format: "%.3f", e.baseLambda))
                                    Text(String(format: "%.3f (+%.3f)", e.peakLambda, e.leanSpike))
                                    Text(String(format: "%.3f", e.minLambda))
                                    Text(String(format: "%.0f → %.0f", e.rpmBefore, e.rpmAfter))
                                    Text(e.mapAfter.map { String(format: "%.0f → %.0f kPa", e.mapBefore ?? 0, $0) } ?? "–")
                                    verdict(e)
                                }
                                .font(.callout.monospacedDigit())
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func verdict(_ e: TipInEvent) -> some View {
        switch e.verdict {
        case .lean: return SeverityChip(text: "Magerloch", severity: .warn)
        case .rich: return SeverityChip(text: "zu fett", severity: .warn)
        case .ok:   return SeverityChip(text: "sauber", severity: .ok)
        }
    }
}

struct TipSpikeChart: View {
    let events: [TipInEvent]
    let entries: [LogEntry]

    var body: some View {
        Chart {
            ForEach(entries) { e in
                RuleMark(x: .value("Datum", e.date))
                    .foregroundStyle(Color.orange.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            RuleMark(y: .value("Grenze", 0.08))
                .foregroundStyle(.red.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(events) { e in
                PointMark(x: .value("Datum", e.time), y: .value("Ausschlag", e.leanSpike))
                    .foregroundStyle(by: .value("Urteil", e.verdict == .lean ? "Magerloch" : (e.verdict == .rich ? "zu fett" : "sauber")))
                    .symbolSize(18)
            }
        }
        .chartForegroundStyleScale(domain: ["sauber", "Magerloch", "zu fett"], range: [Color.green, Color.orange, Color.blue])
        .chartLegend(position: .bottom)
    }
}

struct TipTraceChart: View {
    let events: [TipInEvent]

    struct P: Identifiable {
        var t: Double
        var v: Double
        var series: String
        var id: String { series + String(t) }
    }

    var body: some View {
        let pts = events.flatMap { e in
            e.trace.enumerated().map { i, v in P(t: Double(i) * 0.25 - 1, v: Double(v), series: e.id.uuidString) }
        }
        Chart(pts) { p in
            LineMark(x: .value("s", p.t), y: .value("λ", p.v), series: .value("Gasstoß", p.series))
                .foregroundStyle(.orange.opacity(0.45))
        }
        .chartXScale(domain: -1.0...3.0)
        .chartYScale(domain: 0.75...1.25)
    }
}
