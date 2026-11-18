import SwiftUI
import Charts

// ── Uebersicht, Gesamtauswertung, Messreihen ─────────────────────

struct OverviewView: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var app: AppState

    var body: some View {
        let all = lib.allStats
        let last30 = lib.stats(in: .last(days: 30))
        let totals = Aggregate.totals(all)
        let t30 = Aggregate.totals(last30)
        let fuel = FuelMath.results(lib.fuel) { from, to in
            lib.trips.reduce(0) { $0 + ($1.summary.start >= from && $1.summary.start < to ? $1.summary.distanceKm : 0) }
        }
        let avgFuel = FuelMath.average(Array(fuel.values))
        let lastEntry = lib.book.entries.max { $0.date < $1.date }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Übersicht",
                           subtitle: lib.demo ? "Beispieldaten: ein 2CV6 über acht Wochen"
                                              : "\(lib.trips.count) Fahrten, \(lib.sessions.count) Messreihen")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                    StatTile(title: "Fahrten", value: "\(totals.trips)", detail: "\(t30.trips) in 30 Tagen", symbol: "car.side")
                    StatTile(title: "Strecke", value: String(format: "%.0f km", totals.km),
                             detail: String(format: "%.0f km in 30 Tagen", t30.km), symbol: "road.lanes")
                    StatTile(title: "Motorlaufzeit", value: String(format: "%.1f h", totals.engineHours),
                             detail: String(format: "%.1f h in 30 Tagen", t30.engineHours), symbol: "clock")
                    StatTile(title: "Verbrauch", value: avgFuel.map { String(format: "%.1f l", $0) } ?? "–",
                             detail: avgFuel == nil ? "Tankbuch auf dem iPhone führen" : "je 100 km im Schnitt", symbol: "fuelpump")
                    StatTile(title: "Letzte Änderung", value: lastEntry.map { Fmt.day($0.date) } ?? "–",
                             detail: lastEntry?.label ?? "Logbuch ist leer", symbol: "wrench.and.screwdriver")
                }
                HStack(alignment: .top, spacing: 14) {
                    Card(title: "Gemisch der letzten 30 Tage", symbol: "stethoscope") {
                        if last30.isEmpty {
                            EmptyHint(text: "Keine Fahrten in den letzten 30 Tagen.")
                        } else {
                            RegimeTable(regimes: Aggregate.regimes(last30, steady: true), targets: lib.targets)
                            Text("Nur ruhige Fahrt bei warmem Motor. Genauer: Gesamtauswertung.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Card(title: "Auffälligkeiten, letzte 30 Tage", symbol: "exclamationmark.bubble") {
                        IssuesList(recent: last30, all: all)
                    }
                    .frame(width: 430)
                }
                Card(title: "Lambda je Bereich über die Zeit", symbol: "chart.xyaxis.line") {
                    LambdaTrendChart(points: Trend.lambda(all), entries: lib.book.entries)
                        .frame(height: 260)
                    Text("Ein Punkt je Fahrt, nur ruhige Fahrt bei warmem Motor. Orange Linien: Einträge im Logbuch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Card(title: "Letzte Fahrten", symbol: "list.bullet") {
                    ForEach(lib.trips.prefix(6)) { t in
                        Button { app.open(trip: t.id) } label: {
                            TripListRow(trip: t, stats: lib.stats[t.id])
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .padding(20)
        }
    }
}

struct IssuesList: View {
    let recent: [TripStats]
    let all: [TripStats]
    @EnvironmentObject var lib: Library

    struct Item: Identifiable {
        var id: String
        var severity: Severity
        var text: String
    }

    var body: some View {
        let items = make()
        if items.isEmpty {
            Label("Nichts Auffälliges", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        } else {
            ForEach(items) { i in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: i.severity.icon).foregroundStyle(i.severity.tint).frame(width: 18)
                    Text(i.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func make() -> [Item] {
        var out: [Item] = []
        var alerts: [String: Int] = [:]
        for s in recent { for (k, n) in s.alerts { alerts[k, default: 0] += n } }
        for (k, n) in alerts.sorted(by: { $0.value > $1.value }) {
            let kind = AlertKind(rawValue: k)
            out.append(Item(id: "a" + k, severity: kind?.severity ?? .warn,
                            text: (kind?.title ?? k) + ": \(n)-mal gewarnt"))
        }
        let target = lib.targets.stage2
        let pulls = recent.flatMap { $0.pulls }
        let lean = pulls.filter {
            let v = PullAnalysis($0, target: target).verdict
            return v == .lean || v == .leanTop || v == .starving
        }
        if !lean.isEmpty {
            out.append(Item(id: "p", severity: .crit, text: "\(lean.count) von \(pulls.count) Zügen unter Last werden mager"))
        }
        let tips = recent.flatMap { $0.tipIns }
        if tips.count >= 5 {
            let share = Double(tips.filter { $0.verdict == .lean }.count) / Double(tips.count)
            if share >= 0.4 {
                out.append(Item(id: "t", severity: .warn,
                                text: String(format: "%.0f %% der Gasstöße mit Magerloch", share * 100)))
            }
        }
        if let now = Aggregate.mean(recent, { $0.oilPIdleWarm }),
           let before = Aggregate.mean(all.filter { s in !recent.contains { $0.id == s.id } }, { $0.oilPIdleWarm }),
           now < before - 0.25 {
            out.append(Item(id: "o", severity: .warn,
                            text: String(format: "Öldruck im warmen Leerlauf gesunken: %.1f statt %.1f bar", now, before)))
        }
        if let mx = recent.compactMap({ $0.oilTMax }).max(), mx >= 130 {
            out.append(Item(id: "ot", severity: mx >= 145 ? .crit : .warn,
                            text: String(format: "Öltemperatur bis %.0f °C", mx)))
        }
        if let v = Aggregate.mean(recent, { $0.voltageRunning }), v < 13.2 {
            out.append(Item(id: "v", severity: .warn, text: String(format: "Bordnetz während der Fahrt nur %.1f V", v)))
        }
        return out
    }
}

/// Lambda je Bereich ueber die Zeit, mit den Logbuch-Eintraegen
struct LambdaTrendChart: View {
    let points: [TrendPoint]
    let entries: [LogEntry]
    var highlight: UUID? = nil

    var body: some View {
        if points.isEmpty {
            EmptyHint(text: "Noch keine Werte. Sie entstehen aus ruhiger Fahrt bei warmem Motor.", symbol: "chart.xyaxis.line")
        } else {
            Chart {
                ForEach(entries) { e in
                    RuleMark(x: .value("Datum", e.date))
                        .foregroundStyle(Color.orange.opacity(e.id == highlight ? 1 : 0.55))
                        .lineStyle(StrokeStyle(lineWidth: e.id == highlight ? 2 : 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text(e.shortLabel)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                                .frame(maxWidth: 160, alignment: .leading)
                        }
                }
                ForEach(points) { p in
                    LineMark(x: .value("Datum", p.date), y: .value("λ", p.value))
                        .foregroundStyle(by: .value("Bereich", p.series))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Datum", p.date), y: .value("λ", p.value))
                        .foregroundStyle(by: .value("Bereich", p.series))
                        .symbolSize(18)
                }
            }
            .chartForegroundStyleScale(domain: Regime.judged.map { $0.title }, range: Regime.judged.map { $0.tint })
            .chartYScale(domain: 0.8...1.2)
            .chartLegend(position: .bottom)
            .padding(.top, 14)
        }
    }
}

// ── Gesamtauswertung: alle Fahrten eines Zeitraums ──
struct OverallPage: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var app: AppState
    @State private var session: TuningSession?
    @State private var busy = false

    var body: some View {
        let period = app.period.period(lib.book)
        let stats = lib.stats(in: period)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom) {
                    PageHeader(title: "Gesamtauswertung", subtitle: "Alle Fahrten im Zeitraum, zusammengerechnet")
                    Picker("Zeitraum", selection: $app.period) {
                        ForEach(PeriodChoice.allCases) { p in Text(p.title).tag(p) }
                    }
                    .frame(width: 260)
                }
                let totals = Aggregate.totals(stats)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    StatTile(title: "Fahrten", value: "\(totals.trips)")
                    StatTile(title: "Strecke", value: String(format: "%.0f km", totals.km))
                    StatTile(title: "Ruhige Fahrt", value: session.map { String(format: "%.0f min", Double($0.steadyCount) * 0.25 / 60) } ?? "–",
                             detail: "zählt für Kennfeld und Check")
                    StatTile(title: "Züge / Gasstöße", value: "\(totals.pulls) / \(totals.tipIns)")
                }
                if busy {
                    ProgressView("Rechne \(stats.count) Fahrten zusammen …").frame(maxWidth: .infinity, minHeight: 120)
                } else if let s = session, s.lambdaCount > 0 {
                    SessionAnalysisView(session: s,
                                        pulls: stats.flatMap { $0.pulls }.summary(target: lib.targets.stage2),
                                        tipIns: stats.flatMap { $0.tipIns }.summary)
                    HealthCard(stats: stats)
                } else {
                    EmptyHint(text: "Keine Fahrten in diesem Zeitraum.")
                }
            }
            .padding(20)
        }
        .task(id: "\(app.period.rawValue)|\(lib.revision)|\(lib.trips.count)") {
            busy = true
            session = await lib.aggregate(period, name: app.period.title)
            busy = false
        }
    }
}

/// Motorzustand ueber die Zeit: Oeldruck, Oeltemperatur, Bordnetz, Warmlauf
struct HealthCard: View {
    let stats: [TripStats]

    struct P: Identifiable {
        var date: Date
        var value: Double
        var series: String
        var id: String { series + String(date.timeIntervalSinceReferenceDate) }
    }

    var body: some View {
        Card(title: "Motorzustand je Fahrt", symbol: "heart.text.square") {
            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    mini("Öldruck warm (bar)", [
                        ("Leerlauf", { $0.oilPIdleWarm }), ("3000 U/min", { $0.oilP3000Warm })
                    ], colors: [.yellow, .orange])
                    mini("Öltemperatur (°C)", [
                        ("Mittel warm", { $0.oilTWarmMean }), ("Höchstwert", { $0.oilTMax })
                    ], colors: [.pink, .red])
                }
                GridRow {
                    mini("Bordnetz ab 1500 U/min (V)", [("Spannung", { $0.voltageRunning })], colors: [.teal])
                    mini("Warmlauf bis 60 °C Öl (min)", [("Kaltstart", { $0.warmupMinutes })], colors: [.blue])
                }
            }
        }
    }

    private func mini(_ title: String, _ series: [(String, (TripStats) -> Double?)], colors: [Color]) -> some View {
        var pts: [P] = []
        for (name, f) in series {
            for s in stats { if let v = f(s) { pts.append(P(date: s.start, value: v, series: name)) } }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            if pts.isEmpty {
                Text("keine Werte").font(.caption).foregroundStyle(.secondary).frame(height: 140)
            } else {
                Chart(pts) { p in
                    LineMark(x: .value("Datum", p.date), y: .value(title, p.value))
                        .foregroundStyle(by: .value("Reihe", p.series))
                    PointMark(x: .value("Datum", p.date), y: .value(title, p.value))
                        .foregroundStyle(by: .value("Reihe", p.series))
                        .symbolSize(14)
                }
                .chartForegroundStyleScale(domain: series.map { $0.0 }, range: colors)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 140)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// ── Messreihen vom iPhone ──
struct SessionsPage: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var app: AppState

    var body: some View {
        HSplitView {
            List(lib.sessions, selection: $app.sessionID) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).fontWeight(.semibold)
                    Text(Fmt.date(s.created) + String(format: " · %.0f min", Double(s.lambdaCount) * 0.25 / 60))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .tag(s.id)
            }
            .frame(minWidth: 230, idealWidth: 260, maxWidth: 340)

            Group {
                if let id = app.sessionID, let s = lib.sessions.first(where: { $0.id == id }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            PageHeader(title: s.name, subtitle: "seit " + Fmt.date(s.created)
                                       + String(format: " · %.0f min, davon %.0f min ruhig", Double(s.lambdaCount) * 0.25 / 60,
                                                Double(s.steadyCount) * 0.25 / 60))
                            SessionAnalysisView(session: s)
                        }
                        .padding(20)
                    }
                } else if lib.sessions.isEmpty {
                    EmptyHint(text: "Keine Messreihen. Auf dem iPhone unter Abstimmung › Kennfeld › Speichern anlegen.", symbol: "tray")
                } else {
                    EmptyHint(text: "Links eine Messreihe auswählen.", symbol: "tray.full")
                }
            }
            .frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if app.sessionID == nil { app.sessionID = lib.sessions.first?.id }
        }
    }
}
