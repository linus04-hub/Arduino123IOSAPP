import SwiftUI

// ── Tab "Abstimmung": Kennfeld, Zuendkurve, Vorher/Nachher ───────

enum TuningPage: String, CaseIterable, Identifiable {
    case map, ignition, compare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .map:      return "Kennfeld"
        case .ignition: return "Zündung"
        case .compare:  return "Vergleich"
        }
    }
}

struct TuningView: View {
    @ObservedObject var tuning: TuningStore
    @ObservedObject var ble: BLEManager

    @State private var page: TuningPage = .map
    @State private var askName = false
    @State private var name = ""
    @State private var confirmReset = false
    @State private var before: UUID?
    @State private var after: UUID?
    @AppStorage("scatterByLoad") private var byLoad = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Picker("Seite", selection: $page) {
                        ForEach(TuningPage.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch page {
                    case .map:
                        sessionHeader
                        KennfeldPanel(session: tuning.current, rpm: ble.tune?.rpm, map: ble.tune?.mapKPa)
                        lambdaScatter
                    case .ignition:
                        sessionHeader
                        IgnitionPanel(session: tuning.current, rpm: ble.tune?.rpm,
                                      advance: ble.tune?.advance, byLoad: byLoad)
                    case .compare:
                        ComparePanel(tuning: tuning, before: $before, after: $after)
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Abstimmung")
            .navigationBarTitleDisplayMode(.inline)
            .navBarStyle()
            .alert("Messreihe speichern", isPresented: $askName) {
                TextField("Name, z. B. HD 115", text: $name)
                Button("Speichern") { tuning.saveCurrent(as: name) }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Danach kannst du sie unter „Vergleich“ mit einer anderen Messreihe vergleichen.")
            }
            .confirmationDialog("Aktuelle Messreihe leeren?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Leeren", role: .destructive) { tuning.resetCurrent() }
            } message: {
                Text("Vorher speichern, wenn du sie behalten willst.")
            }
        }
    }

    private var sessionHeader: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MESSREIHE „AKTUELL“")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1)
                            .foregroundColor(Theme.muted)
                        Text("seit \(Format.dayTime(tuning.current.created)) · \(tuning.current.lambdaCount) Lambda-Werte")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundColor(Theme.fg)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button {
                        name = ""
                        askName = true
                    } label: {
                        Label("Speichern", systemImage: "square.and.arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundColor(Color.black)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Button {
                        confirmReset = true
                    } label: {
                        Label("Neu beginnen", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundColor(Theme.fg)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var lambdaScatter: some View {
        let pts = tuning.current.lambdaPoints.map {
            ScatterPoint(rpm: Double($0.r), lambda: Double($0.v), mapKPa: $0.m.map { Double($0) })
        }
        return Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    CardLabel(title: "Lambda über Drehzahl")
                    Spacer()
                    Picker("Farbe", selection: $byLoad) {
                        Text("Zone").tag(false)
                        Text("Last").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 112)
                }
                ScatterPlot(points: pts, currentRPM: ble.tune?.rpm,
                            currentLambda: Metric.lambda.current(ble), byLoad: byLoad)
                    .frame(height: 210)
            }
        }
    }
}

// ── Raster fuer die Differenz im Vergleich ──────────────────────
struct CellLook {
    let text: String
    let fill: Color
    let textColor: Color
}

struct MapGrid: View {
    let look: (Int, Int) -> CellLook        // (Zeile, Spalte)
    var highlight: (row: Int, col: Int)? = nil

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array((0..<TuningSession.rows).reversed()), id: \.self) { r in
                HStack(spacing: 2) {
                    Text(String(format: "%.0f", TuningSession.rowLow(r)))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(Theme.muted)
                        .frame(width: 24, alignment: .trailing)
                    ForEach(0..<TuningSession.cols, id: \.self) { c in
                        cell(r, c)
                    }
                }
            }
            HStack(spacing: 2) {
                Text("kPa")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.muted)
                    .frame(width: 24, alignment: .trailing)
                ForEach(0..<TuningSession.cols, id: \.self) { c in
                    Text(c % 2 == 0 ? String(format: "%.0f", TuningSession.colCenter(c) / 1000) : "")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            Text("Drehzahl × 1000 U/min · oben Vollgas, unten Schiebebetrieb")
                .font(.system(size: 10))
                .foregroundColor(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func cell(_ r: Int, _ c: Int) -> some View {
        let l = look(r, c)
        let marked = highlight.map { $0.row == r && $0.col == c } ?? false
        return Text(l.text)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundColor(l.textColor)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(l.fill)
            .overlay {
                RoundedRectangle(cornerRadius: 3).stroke(marked ? Theme.fg : Color.clear, lineWidth: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// KennfeldPanel (weiche Farbkarte) steht in SmoothMap.swift

// ── Kurven-Diagramm ueber der Drehzahl ───────────────────────────
struct Curve {
    let pts: [(Double, Double)]
    let color: Color
    var dashed = false
}

struct CurvePlot: View {
    var points: [TunePoint] = []
    var byLoad = false
    var curves: [Curve] = []
    let yRange: ClosedRange<Double>
    let yGrid: [Double]
    var yFormat = "%.0f"
    var band: ClosedRange<Double>? = nil
    var currentX: Double? = nil
    var currentY: Double? = nil

    static let xMax = 6000.0

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let left: CGFloat = 34, right: CGFloat = 8, top: CGFloat = 6, bottom: CGFloat = 18
        let w = size.width - left - right
        let h = size.height - top - bottom
        let lo = yRange.lowerBound, hi = yRange.upperBound
        func x(_ r: Double) -> CGFloat { left + CGFloat(min(Self.xMax, max(0, r)) / Self.xMax) * w }
        func y(_ v: Double) -> CGFloat { top + CGFloat((hi - min(hi, max(lo, v))) / (hi - lo)) * h }

        if let b = band {
            ctx.fill(Path(CGRect(x: left, y: y(b.upperBound), width: w, height: y(b.lowerBound) - y(b.upperBound))),
                     with: .color(Theme.ok.opacity(0.08)))
        }
        for g in yGrid {
            var p = Path()
            p.move(to: CGPoint(x: left, y: y(g)))
            p.addLine(to: CGPoint(x: left + w, y: y(g)))
            ctx.stroke(p, with: .color(Theme.line), lineWidth: 1)
            ctx.draw(Text(String(format: yFormat, g)).font(.system(size: 10)).foregroundColor(Theme.muted),
                     at: CGPoint(x: left - 6, y: y(g)), anchor: .trailing)
        }
        for r in [2000.0, 4000.0] {
            var p = Path()
            p.move(to: CGPoint(x: x(r), y: top))
            p.addLine(to: CGPoint(x: x(r), y: top + h))
            ctx.stroke(p, with: .color(Theme.line), lineWidth: 1)
        }
        let axis = Font.system(size: 10)
        ctx.draw(Text("0").font(axis).foregroundColor(Theme.muted),
                 at: CGPoint(x: left, y: size.height), anchor: .bottomLeading)
        ctx.draw(Text("2000").font(axis).foregroundColor(Theme.muted),
                 at: CGPoint(x: x(2000), y: size.height), anchor: .bottom)
        ctx.draw(Text("4000").font(axis).foregroundColor(Theme.muted),
                 at: CGPoint(x: x(4000), y: size.height), anchor: .bottom)
        ctx.draw(Text("6000 U/min").font(axis).foregroundColor(Theme.muted),
                 at: CGPoint(x: left + w, y: size.height), anchor: .bottomTrailing)

        for p in points {
            let col: Color = byLoad ? ScatterPlot.loadColor(p.m.map { Double($0) }) : Theme.accent
            let c = CGPoint(x: x(Double(p.r)), y: y(Double(p.v)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4)),
                     with: .color(col.opacity(0.45)))
        }

        for cv in curves {
            var path = Path()
            for (i, pt) in cv.pts.enumerated() {
                let q = CGPoint(x: x(pt.0), y: y(pt.1))
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            ctx.stroke(path, with: .color(cv.color),
                       style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round,
                                          dash: cv.dashed ? [6, 4] : []))
        }

        if let cx = currentX, let cy = currentY {
            let c = CGPoint(x: x(cx), y: y(cy))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)),
                       with: .color(Theme.accent), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(Theme.accent))
        }
    }
}

struct IgnitionPanel: View {
    let session: TuningSession
    let rpm: Double?
    let advance: Double?
    let byLoad: Bool

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardLabel(title: "Zündwinkel über Drehzahl", symbol: "bolt.fill")
                    Spacer()
                    if let a = advance {
                        Text(String(format: "%.1f° vor OT", a))
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                            .foregroundColor(Theme.fg)
                    }
                }
                CurvePlot(points: session.advancePoints, byLoad: byLoad,
                          curves: [Curve(pts: session.advanceCurve, color: Theme.fg)],
                          yRange: 0...45, yGrid: [10, 20, 30, 40], yFormat: "%.0f°",
                          currentX: rpm, currentY: advance)
                    .frame(height: 240)
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(Theme.fg).frame(width: 12, height: 3)
                        Text("Mittel je 250 U/min")
                    }
                    if byLoad {
                        Text("Punkte: blau wenig Last, orange viel Last")
                    }
                    Spacer()
                }
                .font(.system(size: 10))
                .foregroundColor(Theme.muted)
                Text("So siehst du die Zündkurve, die die 123 tatsächlich fährt, inklusive Unterdruckverstellung. Die Farbe nach Last stellst du im Kennfeld unter „Lambda über Drehzahl“ um.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
            }
        }
    }
}

// ── Vorher/Nachher ───────────────────────────────────────────────
struct ComparePanel: View {
    @ObservedObject var tuning: TuningStore
    @Binding var before: UUID?
    @Binding var after: UUID?
    @State private var toDelete: TuningSession?

    var body: some View {
        let a = tuning.session(before)
        let b = tuning.session(after)
        VStack(spacing: 12) {
            Panel {
                VStack(spacing: 8) {
                    pickerRow("Vorher", selection: $before, color: Theme.muted)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    pickerRow("Nachher", selection: $after, color: Theme.accent)
                }
            }
            if let a, let b {
                deltaPanel(a, b)
                curvePanel(title: "Lambda über Drehzahl",
                           a: a.lambdaCurve, b: b.lambdaCurve,
                           range: 0.85...1.15, grid: [0.90, 1.00, 1.10], format: "%.2f", band: 0.98...1.02)
                curvePanel(title: "Zündwinkel über Drehzahl",
                           a: a.advanceCurve, b: b.advanceCurve,
                           range: 0...45, grid: [10, 20, 30, 40], format: "%.0f°", band: nil)
            } else {
                Text("Wähle oben zwei Messreihen, zum Beispiel vor und nach einem Düsenwechsel. Messreihen speicherst du unter „Kennfeld“ oder aus einer Fahrt.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            savedList
        }
        .confirmationDialog("Messreihe löschen?", isPresented: Binding(
            get: { toDelete != nil },
            set: { if !$0 { toDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let s = toDelete {
                    if before == s.id { before = nil }
                    if after == s.id { after = nil }
                    tuning.delete(s)
                }
                toDelete = nil
            }
        }
    }

    private func label(_ s: TuningSession) -> String {
        s.id == tuning.current.id ? "Aktuell (läuft)" : s.name
    }

    private func pickerRow(_ title: String, selection: Binding<UUID?>, color: Color) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 3)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.fg)
            Spacer()
            Picker(title, selection: selection) {
                Text("wählen …").tag(UUID?.none)
                ForEach(tuning.all) { s in
                    Text(label(s)).tag(UUID?.some(s.id))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func deltaPanel(_ a: TuningSession, _ b: TuningSession) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                CardLabel(title: "Kennfeld: Nachher minus Vorher")
                MapGrid(look: { r, c in
                    guard let va = a.lambda(row: r, col: c), let vb = b.lambda(row: r, col: c) else {
                        return CellLook(text: "", fill: Theme.surface2, textColor: Theme.muted)
                    }
                    let d = vb - va
                    let strength = min(0.9, 0.25 + abs(d) * 12)
                    if d < -0.005 {
                        return CellLook(text: String(format: "%+.2f", d), fill: Theme.load.opacity(strength),
                                        textColor: Theme.fg)
                    } else if d > 0.005 {
                        return CellLook(text: String(format: "%+.2f", d), fill: Theme.accent.opacity(strength),
                                        textColor: Theme.fg)
                    } else {
                        return CellLook(text: "±0", fill: Theme.surface2, textColor: Theme.fg)
                    }
                })
                Text("Blau: nachher fetter. Orange: nachher magerer. Nur Zellen, die in beiden Messreihen genug Werte haben.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
            }
        }
    }

    private func curvePanel(title: String, a: [(Double, Double)], b: [(Double, Double)],
                            range: ClosedRange<Double>, grid: [Double], format: String,
                            band: ClosedRange<Double>?) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                CardLabel(title: title)
                CurvePlot(curves: [Curve(pts: a, color: Theme.muted, dashed: true),
                                   Curve(pts: b, color: Theme.accent)],
                          yRange: range, yGrid: grid, yFormat: format, band: band)
                    .frame(height: 200)
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(Theme.muted).frame(width: 12, height: 3)
                        Text("Vorher")
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 12, height: 3)
                        Text("Nachher")
                    }
                    Spacer()
                }
                .font(.system(size: 10))
                .foregroundColor(Theme.muted)
            }
        }
    }

    private var savedList: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                CardLabel(title: "Gespeicherte Messreihen")
                if tuning.saved.isEmpty {
                    Text("Noch keine gespeichert.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                } else {
                    ForEach(tuning.saved) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Theme.fg)
                                Text("\(Format.dayTime(s.created)) · \(s.lambdaCount) Lambda-Werte")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundColor(Theme.muted)
                            }
                            Spacer()
                            Button {
                                toDelete = s
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(Theme.crit)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(s.name) löschen")
                        }
                    }
                }
            }
        }
    }
}
