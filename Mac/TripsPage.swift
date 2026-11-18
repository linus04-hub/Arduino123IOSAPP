import SwiftUI

// ── Fahrten: Liste links, Auswertung rechts ──────────────────────

struct TripsPage: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var app: AppState

    var body: some View {
        HSplitView {
            List(lib.trips, selection: $app.tripID) { t in
                TripListRow(trip: t, stats: lib.stats[t.id])
                    .tag(t.id)
            }
            .frame(minWidth: 250, idealWidth: 290, maxWidth: 380)

            Group {
                if let id = app.tripID, let trip = lib.trips.first(where: { $0.id == id }) {
                    TripAnalysisView(trip: trip)
                        .id(trip.id)
                } else {
                    EmptyHint(text: "Links eine Fahrt auswählen.", symbol: "car.side")
                }
            }
            .frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if app.tripID == nil { app.tripID = lib.trips.first?.id }
        }
    }
}

struct TripListRow: View {
    let trip: TripRef
    let stats: TripStats?

    var body: some View {
        let s = trip.summary
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Fmt.date(s.start)).fontWeight(.semibold)
                Spacer()
                if !s.markers.isEmpty {
                    Label("\(s.markers.count)", systemImage: "flag.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 10) {
                Text(TimeText.duration(s.duration))
                Text(String(format: "%.1f km", s.distanceKm))
                if let l = s.avgLambda { Text(String(format: "Ø λ %.2f", l)) }
                if let st = stats, st.alerts.values.reduce(0, +) > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// ── Eine Fahrt im Detail ──
struct TripAnalysisView: View {
    let trip: TripRef
    @EnvironmentObject var lib: Library
    @EnvironmentObject var app: AppState

    @State private var rows: [TripRow] = []
    @State private var stats: TripStats?
    @State private var session: TuningSession?
    @State private var loading = true
    @State private var domain: ClosedRange<Double> = 0...1
    @State private var selection: ClosedRange<Double>?
    @State private var cursor = TripCursor()
    @State private var route: [RouteSegment] = []
    @State private var steadyRegimes = false

    private var full: ClosedRange<Double> { 0...max(1, rows.last?.t ?? 1) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if loading {
                    ProgressView("Lade Fahrt …").frame(maxWidth: .infinity, minHeight: 200)
                } else if rows.isEmpty {
                    EmptyHint(text: "Die CSV dieser Fahrt ist leer oder nicht lesbar.", symbol: "exclamationmark.triangle")
                } else {
                    timeline
                    if let s = selection { SelectionCard(rows: rows, range: s, channels: app.channels, start: trip.summary.start) }
                    HStack(alignment: .top, spacing: 14) {
                        if !route.isEmpty {
                            Card(title: "Strecke", symbol: "map") {
                                RouteMapView(segments: route, markers: RouteBuilder.markers(rows), rows: rows, cursor: cursor)
                                    .frame(height: 340)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text("Farbe: Gemisch gegen das Ziel des jeweiligen Bereichs. Grau: Schub, Stand oder ohne Lambda.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let st = stats {
                            Card(title: "Gemisch je Bereich", symbol: "chart.bar.doc.horizontal",
                                 trailing: AnyView(Toggle("nur ruhige Fahrt", isOn: $steadyRegimes).toggleStyle(.checkbox))) {
                                RegimeTable(regimes: steadyRegimes ? st.steadyRegimes : st.regimes, targets: lib.targets)
                            }
                            .frame(maxWidth: route.isEmpty ? .infinity : 520)
                        }
                    }
                    if let st = stats { extras(st) }
                    if let s = session, s.lambdaCount > 200 {
                        Text("Gemisch-Check dieser Fahrt").font(.title2.weight(.semibold)).padding(.top, 6)
                        SessionAnalysisView(session: s, pulls: stats?.pulls.summary(target: lib.targets.stage2),
                                            tipIns: stats?.tipIns.summary, compact: true)
                    }
                }
            }
            .padding(20)
        }
        .task(id: trip.id) { await load() }
        .onChange(of: app.snapshotHover) { _, v in cursor.hover = v }
        .onChange(of: app.snapshotSelection) { _, v in selection = v }
    }

    private func load() async {
        loading = true
        let r = await lib.rows(trip)
        let summary = trip.summary
        let targets = lib.targets
        let result = await Task.detached(priority: .userInitiated) { () -> (TripStats, TuningSession, [RouteSegment]) in
            (TripStats.compute(summary: summary, rows: r),
             TuningSession.from(rows: r, name: "Fahrt"),
             RouteBuilder.segments(r, targets: targets))
        }.value
        rows = r
        stats = result.0
        session = result.1
        route = result.2
        domain = 0...max(1, r.last?.t ?? 1)
        selection = nil
        loading = false
    }

    private var header: some View {
        let s = trip.summary
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.date(s.start)).font(.largeTitle.weight(.semibold))
                Text(trip.source).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer()
                Button {
                    SaveText.run(DemoData.csv(rows, start: s.start), name: s.id + ".csv")
                } label: {
                    Label("Als CSV sichern …", systemImage: "square.and.arrow.up")
                }
                .disabled(rows.isEmpty)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                StatTile(title: "Dauer", value: TimeText.duration(s.duration),
                         detail: stats.map { "Motor lief " + TimeText.duration($0.runningSeconds) } ?? "")
                StatTile(title: "Strecke", value: String(format: "%.1f km", s.distanceKm),
                         detail: s.avgSpeed.map { String(format: "Ø %.0f km/h", $0) } ?? "")
                StatTile(title: "Ø Lambda", value: Fmt.num(s.avgLambda, 3),
                         detail: "über alle Lasten")
                StatTile(title: "Drehzahl max", value: Fmt.num(s.maxRPM, 0),
                         detail: s.secondsOver5000 > 0 ? String(format: "%.0f s über 5000", s.secondsOver5000) : "",
                         tint: (s.maxRPM ?? 0) >= 5750 ? .red : .primary)
                StatTile(title: "Öl max", value: Fmt.num(s.maxOilT, 0, unit: "°C"),
                         detail: stats?.warmupMinutes.map { String(format: "warm nach %.0f min", $0) } ?? "",
                         tint: (s.maxOilT ?? 0) >= 145 ? .red : ((s.maxOilT ?? 0) >= 130 ? .orange : .primary))
                StatTile(title: "Öldruck min", value: Fmt.num(s.minOilPRunning, 1, unit: "bar"),
                         detail: stats?.oilPIdleWarm.map { String(format: "Leerlauf warm %.1f bar", $0) } ?? "ab 1200 U/min",
                         tint: (s.minOilPRunning ?? 9) < 1 ? .red : .primary)
            }
        }
    }

    private var timeline: some View {
        let targets = lib.targets
        let lanes = app.channels.map { LaneData.make(rows, $0, domain: domain, targets: targets) }
        let key = "\(trip.id)|\(domain.lowerBound)|\(domain.upperBound)|\(app.channels.map { $0.rawValue }.joined())"
        return Card(title: "Verlauf", symbol: "waveform.path") {
            HStack(spacing: 10) {
                Menu {
                    ForEach(Channel.allCases) { c in
                        Button {
                            app.toggle(c)
                        } label: {
                            if app.channels.contains(c) { Label(c.title, systemImage: "checkmark") } else { Text(c.title) }
                        }
                    }
                } label: {
                    Label("Kanäle", systemImage: "slider.horizontal.3")
                }
                .fixedSize()
                Button("Auf Auswahl zoomen") {
                    if let s = selection {
                        domain = s
                        selection = nil
                    }
                }
                .disabled(selection == nil)
                Button("Ganze Fahrt") {
                    domain = full
                    selection = nil
                }
                .disabled(domain == full)
                Spacer()
                Text(Fmt.time(trip.summary.start.addingTimeInterval(domain.lowerBound)) + " – "
                     + Fmt.time(trip.summary.start.addingTimeInterval(domain.upperBound))
                     + " (" + TimeText.duration(domain.upperBound - domain.lowerBound) + ")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    LanesView(key: key, lanes: lanes, domain: domain, start: trip.summary.start)
                        .equatable()
                    CursorOverlay(cursor: cursor, selection: $selection, domain: domain) {
                        domain = full
                        selection = nil
                    }
                }
                .frame(height: LaneGeo.total(lanes))
                VStack(alignment: .leading, spacing: 10) {
                    HoverReadout(cursor: cursor, rows: rows, start: trip.summary.start, targets: targets)
                    if !trip.summary.markers.isEmpty { markerList }
                }
            }
        }
    }

    private var markerList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Markierungen").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(trip.summary.markers) { m in
                Button {
                    let t = m.time.timeIntervalSince(trip.summary.start)
                    domain = max(0, t - 45)...min(full.upperBound, t + 45)
                    selection = nil
                    cursor.hover = t
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "flag.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(m.id) · " + Fmt.time(m.time)).font(.caption.monospacedDigit())
                            if !m.note.isEmpty { Text(m.note).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 220, alignment: .leading)
    }

    @ViewBuilder
    private func extras(_ st: TripStats) -> some View {
        let target = lib.targets.stage2
        if !st.pulls.isEmpty || !st.tipIns.isEmpty || !st.alerts.isEmpty {
            HStack(alignment: .top, spacing: 14) {
                if !st.pulls.isEmpty {
                    Card(title: "Züge unter Last", symbol: "gauge.with.dots.needle.67percent") {
                        ForEach(st.pulls) { p in
                            let a = PullAnalysis(p, target: target, vehicle: lib.vehicle)
                            let v = PullVerdictText.of(a.verdict)
                            Button {
                                let t = p.time.timeIntervalSince(trip.summary.start)
                                domain = max(0, t - 10)...min(full.upperBound, t + a.duration + 10)
                                selection = t...(t + a.duration)
                            } label: {
                                HStack {
                                    Text(Fmt.time(p.time)).monospacedDigit()
                                    Text(p.kind == .steady ? "Dauervollgas" : String(format: "%.0f→%.0f", a.rpmFrom, a.rpmTo))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .fixedSize()
                                    Spacer()
                                    if let k = PowerSanity.ok(a.peak?.kW) { Text(String(format: "≈ %.0f kW", k)).monospacedDigit() }
                                    SeverityChip(text: v.0, severity: v.1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !st.tipIns.isEmpty {
                    let s = st.tipIns.summary
                    Card(title: "Gasstöße", symbol: "waveform.path.ecg") {
                        Text("\(st.tipIns.count) erkannt: \(s?.lean ?? 0) mager, \(s?.ok ?? 0) sauber, \(s?.rich ?? 0) fett")
                        Text(String(format: "Im Mittel kurz %.3f magerer", s?.avgLeanSpike ?? 0))
                            .foregroundStyle(.secondary)
                    }
                }
                if !st.alerts.isEmpty {
                    Card(title: "Warnungen", symbol: "exclamationmark.triangle.fill") {
                        ForEach(st.alerts.sorted { $0.key < $1.key }, id: \.key) { item in
                            HStack {
                                Text(AlertKind(rawValue: item.key)?.title ?? item.key)
                                Spacer()
                                Text("\(item.value)×").monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }
}

enum PullVerdictText {
    static func of(_ v: PullAnalysis.Verdict) -> (String, Severity) {
        switch v {
        case .ok:       return ("passt", .ok)
        case .lean:     return ("mager", .crit)
        case .leanTop:  return ("oben mager", .crit)
        case .rich:     return ("fett", .warn)
        case .starving: return ("läuft weg", .crit)
        case .noLambda: return ("ohne Lambda", .none)
        }
    }
}

/// Werte des gewaehlten Abschnitts
struct SelectionCard: View {
    let rows: [TripRow]
    let range: ClosedRange<Double>
    let channels: [Channel]
    let start: Date
    @EnvironmentObject var lib: Library
    @State private var showCheck = false

    var body: some View {
        let slice = RangeStats.slice(rows, range)
        Card(title: "Auswahl " + Fmt.time(start.addingTimeInterval(range.lowerBound)) + " – "
             + Fmt.time(start.addingTimeInterval(range.upperBound)), symbol: "selection.pin.in.out",
             trailing: AnyView(HStack {
                Button("Als CSV …") { SaveText.run(DemoData.csv(slice, start: start), name: "Auswahl.csv") }
                Button(showCheck ? "Gemisch-Check ausblenden" : "Gemisch-Check der Auswahl") { showCheck.toggle() }
             })) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("Kanal")
                    Text("min").gridColumnAlignment(.trailing)
                    Text("Ø").gridColumnAlignment(.trailing)
                    Text("max").gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(channels) { ch in
                    if let s = RangeStats.of(rows, ch, range: range) {
                        GridRow {
                            Text(ch.title)
                            Text(ch.format(s.min))
                            Text(ch.format(s.mean)).fontWeight(.semibold)
                            Text(ch.format(s.max))
                        }
                        .monospacedDigit()
                    }
                }
            }
            Text(String(format: "%.0f s, %d Werte", range.upperBound - range.lowerBound, slice.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            if showCheck {
                SessionAnalysisView(session: TuningSession.from(rows: slice, name: "Auswahl"), compact: true)
            }
        }
    }
}
