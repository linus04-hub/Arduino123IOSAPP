import SwiftUI
import Charts
import MapKit

// ── Tab "Fahrten": Liste ─────────────────────────────────────────
struct TripsView: View {
    @ObservedObject var recorder: TripRecorder
    let tuning: TuningStore

    var body: some View {
        NavigationStack {
            List {
                if let c = recorder.current {
                    Section("Läuft gerade") {
                        TripListRow(trip: c, live: true)
                            .listRowBackground(Theme.surface)
                    }
                }
                Section(recorder.trips.isEmpty ? "Noch keine Fahrten" : "Fahrten") {
                    ForEach(recorder.trips) { t in
                        NavigationLink(value: t) {
                            TripListRow(trip: t, live: false)
                        }
                        .listRowBackground(Theme.surface)
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { recorder.trips[$0] }
                        for t in doomed { recorder.delete(t) }
                    }
                }
                Section {
                    Text("Die Aufnahme startet von selbst, wenn der Motor läuft, und endet eine Minute nach dem Abstellen. Die CSV-Dateien findest du auch in der Dateien-App unter „Auf meinem iPhone › Citroën › Fahrten“.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Fahrten")
            .navBarStyle()
            .navigationDestination(for: TripSummary.self) { t in
                TripDetailView(trip: t, recorder: recorder, tuning: tuning)
            }
        }
    }
}

struct TripListRow: View {
    let trip: TripSummary
    let live: Bool

    private var subtitle: String {
        var parts = [Format.duration(trip.duration), String(format: "%.1f km", trip.distanceKm)]
        if !trip.markers.isEmpty {
            parts.append(trip.markers.count == 1 ? "1 Markierung" : "\(trip.markers.count) Markierungen")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Format.dayTime(trip.start))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.fg)
                Text(subtitle)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundColor(Theme.muted)
            }
            Spacer()
            if live {
                HStack(spacing: 5) {
                    Circle().fill(Theme.crit).frame(width: 8, height: 8)
                    Text("Aufnahme").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.crit)
                }
            } else if let l = trip.avgLambda {
                Text(String(format: "Ø λ %.3f", l))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(Limits.lambda(l).0.color)
            }
        }
        .padding(.vertical, 2)
    }
}

// ── Werte, die im Fahrtdiagramm waehlbar sind ────────────────────
enum TripMetric: String, CaseIterable, Identifiable {
    case lambda, rpm, speed, oilP, oilT, advance, map, voltage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lambda:  return "Lambda"
        case .rpm:     return "Drehzahl"
        case .speed:   return "Tempo"
        case .oilP:    return "Öldruck"
        case .oilT:    return "Öltemp."
        case .advance: return "Zündwinkel"
        case .map:     return "Saugrohr"
        case .voltage: return "Bordnetz"
        }
    }

    var unit: String {
        switch self {
        case .lambda:  return ""
        case .rpm:     return "U/min"
        case .speed:   return "km/h"
        case .oilP:    return "bar"
        case .oilT:    return "°C"
        case .advance: return "°"
        case .map:     return "kPa"
        case .voltage: return "V"
        }
    }

    var key: KeyPath<TripRow, Double?> {
        switch self {
        case .lambda:  return \TripRow.lambda
        case .rpm:     return \TripRow.rpm
        case .speed:   return \TripRow.speed
        case .oilP:    return \TripRow.oilP
        case .oilT:    return \TripRow.oilT
        case .advance: return \TripRow.advance
        case .map:     return \TripRow.map
        case .voltage: return \TripRow.voltage
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .lambda:  return 0.80...1.20
        case .rpm:     return 0...Limits.rpmScaleMax
        case .speed:   return 0...120
        case .oilP:    return 0...6
        case .oilT:    return 20...160
        case .advance: return 0...45
        case .map:     return 0...110
        case .voltage: return 10...16
        }
    }
}

struct TripChartPoint: Identifiable {
    let id: Int
    let t: Double        // Minuten
    let v: Double
}

struct TripChartMarker: Identifiable {
    let id: Int
    let t: Double        // Minuten
}

// ── Fahrt im Detail ──────────────────────────────────────────────
struct TripDetailView: View {
    let trip: TripSummary
    @ObservedObject var recorder: TripRecorder
    let tuning: TuningStore

    @State private var rows: [TripRow]?
    @State private var metric: TripMetric = .lambda
    @State private var askName = false
    @State private var sessionName = ""
    @State private var confirmDelete = false
    @State private var savedHint = false
    @Environment(\.dismiss) private var dismiss

    /// aktueller Stand (Notizen koennen sich geaendert haben)
    private var summary: TripSummary {
        recorder.trips.first { $0.id == trip.id } ?? trip
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                TripSummaryGrid(trip: summary)
                if let rows {
                    let coords = Self.coordinates(rows)
                    if coords.count > 1 {
                        TripMapView(coords: coords, markers: Self.markerCoordinates(rows))
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    chartPanel(rows)
                    markerPanel(rows)
                    actionPanel(rows)
                } else {
                    ProgressView()
                        .tint(Theme.accent)
                        .padding(40)
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle(Format.day(trip.start))
        .navigationBarTitleDisplayMode(.inline)
        .navBarStyle()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(item: TripRecorder.csvURL(trip.id)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("CSV teilen")
            }
        }
        .task {
            let id = trip.id
            let loaded = await Task.detached(priority: .userInitiated) { TripRecorder.loadRows(id) }.value
            rows = loaded
        }
        .alert("Als Messreihe speichern", isPresented: $askName) {
            TextField("Name, z. B. HD 115", text: $sessionName)
            Button("Speichern") {
                if let rows { tuning.save(rows: rows, name: sessionName) }
                savedHint = true
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Fahrt erscheint dann unter Abstimmung › Vergleich.")
        }
        .confirmationDialog("Fahrt löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                recorder.delete(trip)
                dismiss()
            }
        }
    }

    // Diagramm mit waehlbarem Wert und Markierungen
    private func chartPanel(_ rows: [TripRow]) -> some View {
        let pts = Self.points(rows, metric.key)
        let marks: [TripChartMarker] = rows.compactMap { r in
            guard let m = r.marker else { return nil }
            return TripChartMarker(id: m, t: r.t / 60)
        }
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(TripMetric.allCases) { m in
                            Button {
                                metric = m
                            } label: {
                                Text(m.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(m == metric ? Color.black : Theme.fg)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(m == metric ? Theme.accent : Theme.surface2, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if pts.isEmpty {
                    Text("Keine \(metric.title)-Werte in dieser Fahrt.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    TripChart(points: pts, markers: marks, metric: metric)
                        .frame(height: 210)
                }
            }
        }
    }

    // Markierungen mit Werten und Notiz
    private func markerPanel(_ rows: [TripRow]) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(title: "Markierungen", symbol: "flag.fill")
                if summary.markers.isEmpty {
                    Text("Keine Markierungen. Während der Fahrt im Live-Tab auf „Markierung“ tippen.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                } else {
                    ForEach(summary.markers) { m in
                        MarkerRow(marker: m,
                                  row: rows.first(where: { $0.marker == m.id }),
                                  start: summary.start) { note in
                            recorder.setNote(note, marker: m.id, trip: trip.id)
                        }
                    }
                }
            }
        }
    }

    private func actionPanel(_ rows: [TripRow]) -> some View {
        VStack(spacing: 10) {
            Button {
                sessionName = Format.dayTime(trip.start)
                askName = true
            } label: {
                Label(savedHint ? "Als Messreihe gespeichert" : "Als Messreihe für Vorher/Nachher speichern",
                      systemImage: savedHint ? "checkmark" : "square.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .foregroundColor(Theme.fg)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            Button {
                confirmDelete = true
            } label: {
                Label("Fahrt löschen", systemImage: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .foregroundColor(Theme.crit)
            }
            .buttonStyle(.plain)
        }
    }

    // ── Daten aufbereiten ────────────────────────────────────────
    /// hoechstens ~500 Punkte, gemittelt
    static func points(_ rows: [TripRow], _ key: KeyPath<TripRow, Double?>) -> [TripChartPoint] {
        let step = max(1, rows.count / 500)
        var out: [TripChartPoint] = []
        var i = 0
        while i < rows.count {
            let end = min(rows.count, i + step)
            var sum = 0.0
            var n = 0
            for k in i..<end {
                if let v = rows[k][keyPath: key] {
                    sum += v
                    n += 1
                }
            }
            if n > 0 { out.append(TripChartPoint(id: out.count, t: rows[i].t / 60, v: sum / Double(n))) }
            i = end
        }
        return out
    }

    static func coordinates(_ rows: [TripRow]) -> [CLLocationCoordinate2D] {
        let step = max(1, rows.count / 2000)
        var out: [CLLocationCoordinate2D] = []
        var i = 0
        while i < rows.count {
            if let la = rows[i].lat, let lo = rows[i].lon {
                out.append(CLLocationCoordinate2D(latitude: la, longitude: lo))
            }
            i += step
        }
        return out
    }

    static func markerCoordinates(_ rows: [TripRow]) -> [TripMapMarker] {
        rows.compactMap { r in
            guard let m = r.marker, let la = r.lat, let lo = r.lon else { return nil }
            return TripMapMarker(number: m, coordinate: CLLocationCoordinate2D(latitude: la, longitude: lo))
        }
    }
}

struct TripSummaryGrid: View {
    let trip: TripSummary

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            box("Dauer", Format.duration(trip.duration))
            box("Strecke", String(format: "%.1f km", trip.distanceKm))
            box("Ø Tempo", Format.value(trip.avgSpeed, "%.0f", "km/h"))
            box("max Tempo", Format.value(trip.maxSpeed, "%.0f", "km/h"))
            box("max Drehzahl", Format.value(trip.maxRPM, "%.0f"))
            box("über 5000", Format.duration(trip.secondsOver5000))
            box("max Öltemp.", Format.value(trip.maxOilT, "%.0f", "°C"),
                trip.maxOilT.map { Limits.temperature($0).0.color })
            box("min Öldruck", Format.value(trip.minOilPRunning, "%.1f", "bar"),
                trip.minOilPRunning.map { Limits.pressure($0).0.color })
            box("Ø Lambda", Format.value(trip.avgLambda, "%.3f"),
                trip.avgLambda.map { Limits.lambda($0).0.color })
        }
    }

    private func box(_ title: String, _ value: String, _ color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 17, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundColor(color ?? Theme.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct MarkerRow: View {
    let marker: TripMarker
    let row: TripRow?
    let start: Date
    let onSave: (String) -> Void
    @State private var text: String

    init(marker: TripMarker, row: TripRow?, start: Date, onSave: @escaping (String) -> Void) {
        self.marker = marker
        self.row = row
        self.start = start
        self.onSave = onSave
        _text = State(initialValue: marker.note)
    }

    private var values: String {
        guard let r = row else { return "" }
        var parts: [String] = []
        if let l = r.lambda { parts.append(String(format: "λ %.3f", l)) }
        if let v = r.rpm { parts.append(String(format: "%.0f U/min", v)) }
        if let v = r.speed { parts.append(String(format: "%.0f km/h", v)) }
        if let v = r.map { parts.append(String(format: "%.0f kPa", v)) }
        if let v = r.oilT { parts.append(String(format: "%.0f °C", v)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(marker.id)")
                    .font(.system(size: 13, weight: .heavy).monospacedDigit())
                    .foregroundColor(Color.black)
                    .frame(width: 24, height: 24)
                    .background(Theme.warn, in: Circle())
                Text(Format.duration(marker.time.timeIntervalSince(start)))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundColor(Theme.fg)
                Text(Format.time(marker.time))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(Theme.muted)
                Spacer()
            }
            if !values.isEmpty {
                Text(values)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(Theme.muted)
            }
            TextField("Notiz, z. B. Ruckeln beim Gasgeben", text: $text)
                .font(.system(size: 14))
                .foregroundColor(Theme.fg)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .submitLabel(.done)
                .onSubmit { onSave(text) }
        }
        .padding(.vertical, 4)
    }
}

// ── Diagramm einer Fahrt (Swift Charts) ──────────────────────────
struct TripChart: View {
    let points: [TripChartPoint]
    let markers: [TripChartMarker]
    let metric: TripMetric

    var body: some View {
        Chart {
            if metric == .lambda {
                RuleMark(y: .value("Lambda 1", 1.0))
                    .foregroundStyle(Theme.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            ForEach(points) { p in
                LineMark(x: .value("Minuten", p.t), y: .value(metric.title, p.v))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
            ForEach(markers) { m in
                RuleMark(x: .value("Markierung", m.t))
                    .foregroundStyle(Theme.warn)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top) {
                        Text("\(m.id)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.warn)
                    }
            }
        }
        .chartYScale(domain: metric.range)
        .chartXAxisLabel("Minuten")
        .chartYAxisLabel(metric.unit)
    }
}

// ── Karte mit der gefahrenen Strecke ─────────────────────────────
struct TripMapMarker {
    let number: Int
    let coordinate: CLLocationCoordinate2D
}

struct TripMapView: UIViewRepresentable {
    let coords: [CLLocationCoordinate2D]
    let markers: [TripMapMarker]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let m = MKMapView()
        m.delegate = context.coordinator
        m.overrideUserInterfaceStyle = .dark
        m.isRotateEnabled = false
        m.pointOfInterestFilter = .excludingAll
        return m
    }

    func updateUIView(_ m: MKMapView, context: Context) {
        // nur neu zeichnen, wenn sich die Strecke geaendert hat
        guard context.coordinator.drawnCount != coords.count else { return }
        context.coordinator.drawnCount = coords.count
        m.removeOverlays(m.overlays)
        m.removeAnnotations(m.annotations)
        guard coords.count > 1 else { return }
        let line = MKPolyline(coordinates: coords, count: coords.count)
        m.addOverlay(line)
        for mk in markers {
            let a = MKPointAnnotation()
            a.coordinate = mk.coordinate
            a.title = "Markierung \(mk.number)"
            m.addAnnotation(a)
        }
        m.setVisibleMapRect(line.boundingMapRect,
                            edgePadding: UIEdgeInsets(top: 28, left: 28, bottom: 28, right: 28),
                            animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var drawnCount = -1

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let p = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: p)
            r.strokeColor = UIColor(Theme.accent)
            r.lineWidth = 4
            return r
        }
    }
}
