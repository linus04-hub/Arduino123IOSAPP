import SwiftUI
import CoreGraphics

// ── Kennfeld als weiche Farbkarte ────────────────────────────────
// Die Werte zwischen den Zellmitten werden bilinear gemischt, dadurch
// sieht man Verlaeufe statt Kaestchen. Drei Ansichten: mittleres Lambda,
// Streuung (wie unruhig das Gemisch ist) und Anzahl der Messwerte.
// Antippen einer Stelle zeigt Wert, Streuung und Anzahl dieser Zelle.

/// Merkt sich das fertige Bild. Die Karte wird sonst bei jedem neuen Live-Wert
/// (10-mal je Sekunde) neu gerechnet, obwohl sich die Messreihe nur 1-mal je Sekunde aendert.
final class MapCache {
    private var key = ""
    private var data: MapData?

    func get(_ session: TuningSession, mode: MapMode, steady: Bool) -> MapData {
        let t = LiveContext.targets
        let k = "\(session.id)|\(session.lambdaCount)|\(session.advanceCount)|\(mode.rawValue)|\(steady)"
            + "|\(t.idle)|\(t.stage1)|\(t.transition)|\(t.stage2)"
        if k == key, let d = data { return d }
        let d = MapData(session: session, mode: mode, steady: steady, targets: t)
        key = k
        data = d
        return d
    }
}

// ── Die Karte selbst ─────────────────────────────────────────────
struct SmoothMap: View {
    let data: MapData
    var liveRPM: Double? = nil
    var liveKPa: Double? = nil
    var selected: MapCell? = nil
    var advanceLabels: [[Double?]]? = nil   // Zuendwinkel als Zahl in jeder Zelle
    var onTap: (MapCell) -> Void = { _ in }

    static let labelW: CGFloat = 26
    static let axisH: CGFloat = 18
    static let rowH: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: Self.labelW, y: 0,
                              width: max(1, geo.size.width - Self.labelW),
                              height: max(1, geo.size.height - Self.axisH))
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)
                if let img = data.image {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: plot.width, height: plot.height)
                        .opacity(Theme.night ? 0.7 : 1)
                        .offset(x: plot.minX, y: plot.minY)
                }
                Canvas { ctx, size in
                    drawOverlay(ctx, plot: plot, size: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        if let cell = Self.cell(at: value.location, plot: plot) { onTap(cell) }
                    }
            )
        }
        .frame(height: CGFloat(TuningSession.rows) * Self.rowH + Self.axisH)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kennfeld, Drehzahl nach rechts, Last nach oben")
    }

    static func cell(at p: CGPoint, plot: CGRect) -> MapCell? {
        guard plot.contains(p) else { return nil }
        let cw = plot.width / CGFloat(TuningSession.cols)
        let rh = plot.height / CGFloat(TuningSession.rows)
        let c = min(TuningSession.cols - 1, max(0, Int((p.x - plot.minX) / cw)))
        let fromTop = min(TuningSession.rows - 1, max(0, Int((p.y - plot.minY) / rh)))
        return MapCell(row: TuningSession.rows - 1 - fromTop, col: c)
    }

    private func drawOverlay(_ ctx: GraphicsContext, plot: CGRect, size: CGSize) {
        let rows = TuningSession.rows
        let cols = TuningSession.cols
        let cw = plot.width / CGFloat(cols)
        let rh = plot.height / CGFloat(rows)

        func rect(_ r: Int, _ c: Int) -> CGRect {
            CGRect(x: plot.minX + CGFloat(c) * cw, y: plot.minY + CGFloat(rows - 1 - r) * rh,
                   width: cw, height: rh)
        }

        // Zellen ohne Aussage abdunkeln
        for r in 0..<rows {
            for c in 0..<cols where data.values[r][c] == nil {
                ctx.fill(Path(rect(r, c)), with: .color(Theme.surface.opacity(0.9)))
            }
        }

        // feines Raster, damit man die Zellen noch erkennt
        var grid = Path()
        for c in 1..<cols {
            let x = plot.minX + CGFloat(c) * cw
            grid.move(to: CGPoint(x: x, y: plot.minY))
            grid.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        for r in 1..<rows {
            let y = plot.minY + CGFloat(r) * rh
            grid.move(to: CGPoint(x: plot.minX, y: y))
            grid.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        ctx.stroke(grid, with: .color(Color.black.opacity(0.15)), lineWidth: 0.5)

        // Achsen: Last links, Drehzahl unten
        let font = Font.system(size: 9).monospacedDigit()
        for r in 0..<rows {
            let y = plot.minY + (CGFloat(rows - 1 - r) + 0.5) * rh
            let t = Text(String(format: "%.0f", TuningSession.rowLow(r))).font(font).foregroundColor(Theme.muted)
            ctx.draw(t, at: CGPoint(x: plot.minX - 5, y: y), anchor: .trailing)
        }
        for c in stride(from: 0, to: cols, by: 2) {
            let x = plot.minX + (CGFloat(c) + 0.5) * cw
            let t = Text(String(format: "%.0f", TuningSession.colCenter(c) / 1000)).font(font).foregroundColor(Theme.muted)
            ctx.draw(t, at: CGPoint(x: x, y: size.height), anchor: .bottom)
        }
        ctx.draw(Text("kPa").font(.system(size: 8)).foregroundColor(Theme.muted),
                 at: CGPoint(x: plot.minX - 5, y: size.height), anchor: .bottomTrailing)

        // Zuendwinkel als Zahl ueber die Karte legen
        if let labels = advanceLabels {
            let font = Font.system(size: 9, weight: .bold).monospacedDigit()
            for r in 0..<rows {
                for c in 0..<cols {
                    guard let a = labels[r][c] else { continue }
                    let box = rect(r, c)
                    let tag = CGRect(x: box.midX - 12, y: box.midY - 7, width: 24, height: 14)
                    ctx.fill(Path(roundedRect: tag, cornerRadius: 3), with: .color(Color.black.opacity(0.5)))
                    ctx.draw(Text(String(format: "%.0f°", a)).font(font).foregroundColor(Color.white),
                             at: CGPoint(x: box.midX, y: box.midY))
                }
            }
        }

        // angetippte Zelle
        if let s = selected {
            let r = rect(s.row, s.col).insetBy(dx: 1, dy: 1)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(Theme.fg), lineWidth: 2)
        }

        // aktueller Betriebspunkt als Fadenkreuz
        if let rpm = liveRPM, rpm >= 500, let kPa = liveKPa {
            let x = plot.minX + min(plot.width, max(0, CGFloat((rpm - 750) / 500) * cw))
            let y = plot.minY + min(plot.height, max(0, CGFloat((100 - kPa) / 10) * rh))
            var cross = Path()
            cross.move(to: CGPoint(x: x, y: plot.minY))
            cross.addLine(to: CGPoint(x: x, y: plot.maxY))
            cross.move(to: CGPoint(x: plot.minX, y: y))
            cross.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.stroke(cross, with: .color(Theme.fg.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let dot = CGRect(x: x - 5, y: y - 5, width: 10, height: 10)
            ctx.fill(Path(ellipseIn: dot), with: .color(Theme.fg))
            ctx.stroke(Path(ellipseIn: dot), with: .color(Color.black), lineWidth: 1.5)
        }
    }
}

// ── Farbskala unter der Karte ────────────────────────────────────
struct ColorScale: View {
    let mode: MapMode
    let maxCount: Int

    var body: some View {
        VStack(spacing: 4) {
            LinearGradient(stops: gradientStops, startPoint: .leading, endPoint: .trailing)
                .frame(height: 8)
                .clipShape(Capsule())
                .opacity(Theme.night ? 0.7 : 1)
            ZStack {
                HStack {
                    Text(labels.0)
                    Spacer()
                    Text(labels.2)
                }
                Text(labels.1)
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(Theme.muted)
        }
    }

    private var gradientStops: [Gradient.Stop] {
        let s = mode.stops
        guard let lo = s.first?.0, let hi = s.last?.0, hi > lo else { return [] }
        return s.map { stop in
            Gradient.Stop(color: stop.1.color, location: CGFloat((stop.0 - lo) / (hi - lo)))
        }
    }

    private var labels: (String, String, String) {
        switch mode {
        case .lambda: return ("0.90 fett", "1.00", "mager 1.10")
        case .delta:  return ("−0.12 zu fett", "Ziel", "zu mager +0.12")
        case .spread: return ("ruhig", "±0.03", "unruhig ±0.06")
        case .count:  return ("wenig", "", maxCount > 0 ? "\(maxCount) Werte" : "viel")
        case .advance: return ("5°", "22°", "40° vor OT")
        }
    }
}

// ── Karte mit Umschalter, Skala und Wert der angetippten Zelle ───
struct KennfeldPanel: View {
    let session: TuningSession
    let rpm: Double?
    let map: Double?

    @AppStorage("mapMode") private var mode: MapMode = .lambda
    @AppStorage("mapShowAdvance") private var showAdvance = false
    @AppStorage("mapSteady") private var steadyOnly = true
    @State private var selected: MapCell?
    @State private var cache = MapCache()

    /// Ruhige Fahrt gibt es erst in Messreihen ab Version 2.0
    private var steady: Bool { steadyOnly && session.steadyCells != nil }

    /// Zuendwinkel je Zelle fuer die Zahlen ueber der Karte
    private var advanceGrid: [[Double?]] {
        (0..<TuningSession.rows).map { r in
            (0..<TuningSession.cols).map { c in session.advance(row: r, col: c) }
        }
    }

    var body: some View {
        let data = cache.get(session, mode: mode, steady: steady)
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(title: "Lambda-Kennfeld")
                Picker("Ansicht", selection: $mode) {
                    ForEach(MapMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                if session.steadyCells != nil {
                    Toggle("Nur ruhige Fahrt, Motor warm", isOn: $steadyOnly)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.fg)
                        .tint(Theme.accent)
                }
                Toggle("Zündwinkel einblenden", isOn: $showAdvance)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.fg)
                    .tint(Theme.accent)
                SmoothMap(data: data, liveRPM: rpm, liveKPa: map, selected: selected,
                          advanceLabels: showAdvance ? advanceGrid : nil) { cell in
                    selected = (selected == cell) ? nil : cell
                }
                Text("Drehzahl × 1000 U/min · dunkel = noch zu wenige Werte")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                ColorScale(mode: mode, maxCount: data.maxCount)
                cellInfo
                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var liveCell: MapCell? {
        guard let r = rpm, r >= 500, let m = map else { return nil }
        return MapCell(row: TuningSession.row(m), col: TuningSession.col(r))
    }

    @ViewBuilder
    private var cellInfo: some View {
        if let s = selected {
            info(s, caption: "AUSGEWÄHLT")
        } else if let l = liveCell {
            info(l, caption: "JETZT")
        } else {
            Text("Tippe auf eine Stelle, um Lambda, Streuung und Anzahl zu sehen.")
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func info(_ cell: MapCell, caption: String) -> some View {
        let n = session.count(row: cell.row, col: cell.col, steady: steady)
        let lam = session.lambda(row: cell.row, col: cell.col, steady: steady)
        let sp = session.spread(row: cell.row, col: cell.col, steady: steady)
        let regime = Regime.of(row: cell.row, col: cell.col)
        let judged = lam.map { MixtureJudge.judge(lambda: $0, regime: regime, targets: LiveContext.targets) }
        let adv = session.advance(row: cell.row, col: cell.col)
        let lo = TuningSession.rowLow(cell.row)
        let place = String(format: "%.0f U/min · %.0f–%.0f kPa", TuningSession.colCenter(cell.col), lo, lo + 10)
        let value = lam.map { String(format: "λ %.3f", $0) } ?? "zu wenige Werte"
        let valueColor: Color = judged.map { $0.severity.color } ?? Theme.muted
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(caption)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1)
                        .foregroundColor(Theme.muted)
                    Text(place)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundColor(Theme.fg)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value)
                        .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(valueColor)
                    Text(detail(n: n, spread: sp, advance: adv))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(Theme.muted)
                }
            }
            if let j = judged {
                Text(regime.title + (j.target.map { String(format: " · Ziel %.2f · ", $0) + j.text } ?? " · ohne Ziel"))
                    .font(.system(size: 12))
                    .foregroundColor(j.severity.color)
            }
            if lam != nil, CarbCircuit.of(row: cell.row, col: cell.col) != nil {
                NavigationLink {
                    JetCalcView(sessions: [session], cell: cell, steady: steady)
                } label: {
                    Label("Düse für diese Stelle berechnen", systemImage: "function")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func detail(n: Int, spread: Double?, advance: Double?) -> String {
        var parts: [String] = []
        if let spread { parts.append(String(format: "±%.3f", spread)) }
        parts.append(n == 1 ? "1 Wert" : "\(n) Werte")
        if let advance { parts.append(String(format: "%.0f° vor OT", advance)) }
        return parts.joined(separator: " · ")
    }

    private var steadyNote: String {
        steady ? " Gezählt wird nur ruhige Fahrt bei warmem Motor, Gasstöße und Kaltlauf bleiben draußen." : ""
    }

    private var explanation: String {
        switch mode {
        case .lambda:
            return "Mittleres Lambda je Drehzahl und Last, zwischen den Zellen weich gemischt. Das Fadenkreuz ist der aktuelle Betriebspunkt."
                + steadyNote
        case .delta:
            return "Abstand zum Ziel-Lambda des jeweiligen Bereichs: Leerlauf, Teillast, Übergang, Vollgas. Grün passt, blau ist fetter als gewollt, rot magerer. Die Ziele stellst du unter Einstellungen › Gemisch ein. Schiebebetrieb (unterste Zeile) hat kein Ziel."
                + steadyNote
        case .spread:
            return "Wie stark Lambda in diesem Bereich schwankt. Rot heißt unruhig: Dort springt das Gemisch, zum Beispiel beim Übergang oder beim Gasgeben. Wird erst ab Version 1.2 erfasst, ältere Messreihen bleiben hier dunkel."
        case .count:
            return "Wie viele Messwerte in jedem Bereich stecken. Wo wenig gemessen wurde, ist die Farbe im Lambda-Bild noch unsicher."
        case .advance:
            return "Mittlerer Zündwinkel der 123 je Drehzahl und Last, mit Unterdruckverstellung. „Zündwinkel einblenden“ legt die Zahlen auch über die Lambda-Karte. Wird ab Version 1.4 erfasst, ältere Messreihen bleiben hier dunkel."
        }
    }
}
