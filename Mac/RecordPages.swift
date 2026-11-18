import SwiftUI
import Charts

// ── Logbuch mit Wirkung jeder Aenderung, Tankbuch ────────────────

struct LogbookPage: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var app: AppState

    var body: some View {
        let entries = lib.book.entries.sorted { $0.date > $1.date }
        let effects = LogAnalysis.effects(entries: entries, stats: lib.allStats,
                                          target: lib.targets.stage2, vehicle: lib.vehicle)
        HSplitView {
            List(entries, selection: $app.logID) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.date(e.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(e.label).fontWeight(.semibold).lineLimit(2)
                    if !e.note.isEmpty { Text(e.note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                .padding(.vertical, 2)
                .tag(e.id)
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

            Group {
                if let id = app.logID, let e = entries.first(where: { $0.id == id }) {
                    LogEntryDetail(entry: e, previous: entries.first { $0.date < e.date },
                                   effect: effects.first { $0.id == e.id })
                } else if entries.isEmpty {
                    EmptyHint(text: "Das Logbuch ist leer. Auf dem iPhone unter Abstimmung › Mehr › Bedüsung und Logbuch jede Änderung eintragen. Dann zeigt der Mac, was sie gebracht hat.", symbol: "book.closed")
                } else {
                    EmptyHint(text: "Links einen Eintrag wählen.", symbol: "book")
                }
            }
            .frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if app.logID == nil { app.logID = entries.first { e in effects.contains { $0.id == e.id && $0.afterTrips > 0 && $0.beforeTrips > 0 } }?.id ?? entries.first?.id }
        }
    }
}

struct LogEntryDetail: View {
    let entry: LogEntry
    let previous: LogEntry?
    let effect: LogEffect?
    @EnvironmentObject var lib: Library

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: entry.label, subtitle: Fmt.date(entry.date) + (entry.note.isEmpty ? "" : " · " + entry.note))
                HStack(alignment: .top, spacing: 14) {
                    Card(title: "Bedüsung", symbol: "wrench.and.screwdriver") {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                            ForEach(CarbSetup.Field.allCases) { f in
                                let now = entry.setup[f]
                                let before = previous?.setup[f]
                                GridRow {
                                    Text(f.title).foregroundStyle(.secondary)
                                    Text(CarbSetup.text(now, f))
                                        .fontWeight(now != before ? .bold : .regular)
                                        .foregroundStyle(now != before ? Color.orange : Color.primary)
                                    if now != before, previous != nil {
                                        Text("vorher " + CarbSetup.text(before, f)).font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("")
                                    }
                                }
                                .monospacedDigit()
                            }
                        }
                        if let n = entry.sessionName {
                            Label("Messreihe davor auf dem iPhone: " + n, systemImage: "tray")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 430)
                    if let fx = effect { EffectCard(effect: fx) }
                }
                Card(title: "Lambda je Bereich über die Zeit", symbol: "chart.xyaxis.line") {
                    LambdaTrendChart(points: Trend.lambda(lib.allStats), entries: lib.book.entries, highlight: entry.id)
                        .frame(height: 260)
                }
                Card(title: "Leistung über die Zeit", symbol: "bolt.fill") {
                    PowerTrend(points: Trend.power(lib.allPulls, target: lib.targets.stage2, vehicle: lib.vehicle),
                               entries: lib.book.entries)
                        .frame(height: 200)
                }
            }
            .padding(20)
        }
    }
}

struct EffectCard: View {
    let effect: LogEffect
    @EnvironmentObject var lib: Library

    var body: some View {
        let fx = effect
        let targets = lib.targets
        Card(title: "Was hat es gebracht?", symbol: "arrow.left.arrow.right") {
            if fx.beforeTrips == 0 || fx.afterTrips == 0 {
                EmptyHint(text: fx.afterTrips == 0 ? "Seit der Änderung wurde noch nicht gefahren." : "Vor der Änderung gibt es keine Fahrten zum Vergleichen.",
                          symbol: "hourglass")
            } else {
                Text("\(fx.beforeTrips) Fahrten vorher (ab \(Fmt.day(fx.beforeFrom))) gegen \(fx.afterTrips) Fahrten nachher (bis \(Fmt.day(min(fx.afterTo, Date())))). Nur ruhige Fahrt bei warmem Motor.")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Bereich")
                        Text("vorher").gridColumnAlignment(.trailing)
                        Text("nachher").gridColumnAlignment(.trailing)
                        Text("Δ").gridColumnAlignment(.trailing)
                        Text("Ziel").gridColumnAlignment(.trailing)
                        Text("")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Regime.judged) { r in
                        let b = fx.lambda(r, after: false)
                        let a = fx.lambda(r, after: true)
                        let t = targets.target(r)
                        GridRow {
                            HStack(spacing: 6) { Circle().fill(r.tint).frame(width: 8, height: 8); Text(r.title).lineLimit(1).fixedSize() }
                            Text(Fmt.num(b, 3))
                            Text(Fmt.num(a, 3)).fontWeight(.semibold)
                            Text(Fmt.signed(fx.delta(r), 3))
                            Text(Fmt.num(t, 2)).foregroundStyle(.secondary)
                            verdict(b, a, t)
                        }
                        .monospacedDigit()
                    }
                }
                Divider()
                HStack(spacing: 24) {
                    pair("Leistung (Ø Spitze)", fx.beforePower, fx.afterPower, "%.1f kW")
                    pair("Gasstöße mit Magerloch", fx.beforeTipLean.map { $0 * 100 }, fx.afterTipLean.map { $0 * 100 }, "%.0f %%")
                }
            }
        }
    }

    @ViewBuilder
    private func verdict(_ b: Double?, _ a: Double?, _ t: Double?) -> some View {
        if let b, let a, let t {
            let db = abs(b - t), da = abs(a - t)
            if da < db - 0.01 {
                SeverityChip(text: "näher am Ziel", severity: .ok)
            } else if da > db + 0.01 {
                SeverityChip(text: "weiter weg", severity: .crit)
            } else {
                SeverityChip(text: "gleich", severity: .info)
            }
        } else {
            Text("")
        }
    }

    private func pair(_ title: String, _ b: Double?, _ a: Double?, _ fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text((b.map { String(format: fmt, $0) } ?? "–") + "  →  " + (a.map { String(format: fmt, $0) } ?? "–"))
                .font(.title3.weight(.semibold).monospacedDigit())
        }
    }
}

// ── Tankbuch ──
struct FuelPage: View {
    @EnvironmentObject var lib: Library

    struct Bar: Identifiable {
        var id: UUID
        var date: Date
        var per100: Double
        var gps: Bool
    }

    var body: some View {
        let results = FuelMath.results(lib.fuel) { from, to in
            lib.trips.reduce(0) { $0 + ($1.summary.start >= from && $1.summary.start < to ? $1.summary.distanceKm : 0) }
        }
        let bars = lib.fuel.compactMap { e in results[e.id].map { Bar(id: e.id, date: e.date, per100: $0.per100, gps: $0.gps) } }
            .sorted { $0.date < $1.date }
        let avg = FuelMath.average(Array(results.values))
        let priced = lib.fuel.filter { ($0.price ?? 0) > 0 && $0.liters > 0 }
        let perLiter = priced.isEmpty ? nil : priced.reduce(0) { $0 + $1.price! } / priced.reduce(0) { $0 + $1.liters }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Tankbuch", subtitle: "Eingetragen auf dem iPhone unter Fahrten › Tankbuch")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    StatTile(title: "Verbrauch Ø", value: avg.map { String(format: "%.1f l", $0) } ?? "–", detail: "je 100 km")
                    StatTile(title: "Zuletzt", value: bars.last.map { String(format: "%.1f l", $0.per100) } ?? "–",
                             detail: bars.last.map { Fmt.day($0.date) } ?? "")
                    StatTile(title: "Getankt", value: String(format: "%.0f l", lib.fuel.reduce(0) { $0 + $1.liters }),
                             detail: "\(lib.fuel.count) Einträge")
                    StatTile(title: "Preis Ø", value: perLiter.map { String(format: "%.2f €/l", $0) } ?? "–")
                }
                if bars.isEmpty {
                    EmptyHint(text: "Für einen Verbrauch braucht es zwei Einträge mit „Vollgetankt“.", symbol: "fuelpump")
                } else {
                    Card(title: "Verbrauch je Tankfüllung", symbol: "chart.bar.fill") {
                        Chart {
                            ForEach(bars) { b in
                                BarMark(x: .value("Datum", b.date, unit: .day), y: .value("l/100 km", b.per100))
                                    .foregroundStyle(b.gps ? Color.orange.opacity(0.6) : Color.orange)
                                    .annotation(position: .top) {
                                        Text(String(format: "%.1f", b.per100)).font(.caption2).monospacedDigit()
                                    }
                            }
                            if let avg {
                                RuleMark(y: .value("Ø", avg))
                                    .foregroundStyle(.secondary)
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            }
                            ForEach(lib.book.entries) { e in
                                RuleMark(x: .value("Datum", e.date))
                                    .foregroundStyle(Color.orange.opacity(0.5))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            }
                        }
                        .frame(height: 240)
                        Text("Hell: Strecke aus den GPS-Kilometern der Fahrten, weil kein Kilometerstand eingetragen war.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Card(title: "Einträge", symbol: "list.bullet") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                        GridRow {
                            Text("Datum"); Text("Liter"); Text("km-Stand"); Text("Betrag"); Text("voll"); Text("Verbrauch")
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(lib.fuel) { e in
                            GridRow {
                                Text(Fmt.date(e.date))
                                Text(String(format: "%.1f", e.liters))
                                Text(Fmt.num(e.odometer, 0))
                                Text(e.price.map { String(format: "%.2f €", $0) } ?? "–")
                                Text(e.full ? "ja" : "nein")
                                Text(results[e.id].map { String(format: "%.1f l/100 km", $0.per100) + ($0.gps ? " (GPS)" : "") } ?? "–")
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}
