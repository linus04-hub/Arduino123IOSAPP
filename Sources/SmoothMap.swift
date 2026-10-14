import SwiftUI
import CoreGraphics

// ── Kennfeld als weiche Farbkarte ────────────────────────────────
// Die Werte zwischen den Zellmitten werden bilinear gemischt, dadurch
// sieht man Verlaeufe statt Kaestchen. Drei Ansichten: mittleres Lambda,
// Streuung (wie unruhig das Gemisch ist) und Anzahl der Messwerte.
// Antippen einer Stelle zeigt Wert, Streuung und Anzahl dieser Zelle.

enum MapMode: String, CaseIterable, Identifiable {
    case lambda, spread, count

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lambda: return "Lambda"
        case .spread: return "Streuung"
        case .count:  return "Anzahl"
        }
    }

    /// Stuetzstellen der Farbskala. Bei "Anzahl" laeuft der Wert von 0 bis 1.
    var stops: [(Double, RGB)] {
        switch self {
        case .lambda:
            return [(0.90, RGB(70, 100, 255)), (0.95, RGB(64, 196, 255)), (1.00, RGB(46, 204, 113)),
                    (1.05, RGB(253, 140, 0)), (1.10, RGB(231, 76, 60))]
        case .spread:
            return [(0.00, RGB(46, 204, 113)), (0.02, RGB(241, 196, 15)), (0.04, RGB(253, 140, 0)),
                    (0.06, RGB(231, 76, 60))]
        case .count:
            return [(0.0, RGB(40, 44, 80)), (0.5, RGB(52, 120, 210)), (1.0, RGB(140, 225, 255))]
        }
    }
}

struct MapCell: Equatable {
    let row: Int
    let col: Int
}

/// Farbe als Zahlen, damit sie sich mischen und in Pixel schreiben laesst
struct RGB {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    var color: Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: 1) }

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let u = min(1, max(0, t))
        return RGB(a.r + (b.r - a.r) * u, a.g + (b.g - a.g) * u, a.b + (b.b - a.b) * u)
    }

    /// Farbverlauf ueber Stuetzstellen (Wert, Farbe), aufsteigend sortiert
    static func ramp(_ stops: [(Double, RGB)], _ v: Double) -> RGB {
        guard let first = stops.first, let last = stops.last else { return RGB(0, 0, 0) }
        if v <= first.0 { return first.1 }
        if v >= last.0 { return last.1 }
        for i in 1..<stops.count where v <= stops[i].0 {
            let a = stops[i - 1]
            let b = stops[i]
            return mix(a.1, b.1, (v - a.0) / (b.0 - a.0))
        }
        return last.1
    }
}

// ── Daten und Bild einer Ansicht ─────────────────────────────────
struct MapData {
    let values: [[Double?]]     // [Zeile][Spalte], nil = keine Aussage
    let maxCount: Int
    let image: CGImage?

    static let sub = 8          // Pixel je Zelle; den Rest glaettet die Skalierung

    init(session: TuningSession, mode: MapMode) {
        let rows = TuningSession.rows
        let cols = TuningSession.cols
        var mx = 0
        for r in 0..<rows {
            for c in 0..<cols {
                mx = max(mx, session.count(row: r, col: c))
            }
        }
        let logMax = log(1 + Double(max(1, mx)))
        var v: [[Double?]] = Array(repeating: Array(repeating: nil, count: cols), count: rows)
        for r in 0..<rows {
            for c in 0..<cols {
                switch mode {
                case .lambda:
                    v[r][c] = session.lambda(row: r, col: c)
                case .spread:
                    v[r][c] = session.spread(row: r, col: c)
                case .count:
                    let n = session.count(row: r, col: c)
                    v[r][c] = n > 0 ? log(1 + Double(n)) / logMax : nil
                }
            }
        }
        values = v
        maxCount = mx
        image = Self.render(v, stops: mode.stops)
    }

    /// Luecken mit dem Mittel der Nachbarn fuellen, nur fuer das Mischen
    private static func filled(_ v: [[Double?]]) -> [[Double]] {
        let rows = TuningSession.rows
        let cols = TuningSession.cols
        var g = v
        for _ in 0..<3 {
            var next = g
            for r in 0..<rows {
                for c in 0..<cols where g[r][c] == nil {
                    var s = 0.0
                    var n = 0
                    for dr in -1...1 {
                        for dc in -1...1 {
                            let rr = r + dr
                            let cc = c + dc
                            if rr < 0 || rr >= rows || cc < 0 || cc >= cols { continue }
                            if let x = g[rr][cc] {
                                s += x
                                n += 1
                            }
                        }
                    }
                    if n > 0 { next[r][c] = s / Double(n) }
                }
            }
            g = next
        }
        var total = 0.0
        var count = 0
        for row in g {
            for x in row {
                if let x {
                    total += x
                    count += 1
                }
            }
        }
        let fallback = count > 0 ? total / Double(count) : 1.0
        return g.map { row in row.map { $0 ?? fallback } }
    }

    /// Bilinear zwischen den Zellmitten; fx in Spalten, fy in Zeilen
    private static func bilinear(_ f: [[Double]], _ fx: Double, _ fy: Double) -> Double {
        let x = min(Double(TuningSession.cols - 1), max(0, fx))
        let y = min(Double(TuningSession.rows - 1), max(0, fy))
        let c0 = min(TuningSession.cols - 2, Int(x))
        let r0 = min(TuningSession.rows - 2, Int(y))
        let tx = x - Double(c0)
        let ty = y - Double(r0)
        let a = f[r0][c0] * (1 - tx) + f[r0][c0 + 1] * tx
        let b = f[r0 + 1][c0] * (1 - tx) + f[r0 + 1][c0 + 1] * tx
        return a * (1 - ty) + b * ty
    }

    private static func byte(_ x: Double) -> UInt8 { UInt8(min(255, max(0, x.rounded()))) }

    private static func render(_ v: [[Double?]], stops: [(Double, RGB)]) -> CGImage? {
        var any = false
        for row in v where row.contains(where: { $0 != nil }) { any = true }
        guard any else { return nil }

        let f = filled(v)
        let rows = TuningSession.rows
        let w = TuningSession.cols * sub
        let h = rows * sub
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for j in 0..<h {
            // Bildzeile 0 ist oben, also hohe Last
            let fy = Double(rows - 1) - ((Double(j) + 0.5) / Double(sub) - 0.5)
            for i in 0..<w {
                let fx = (Double(i) + 0.5) / Double(sub) - 0.5
                let c = RGB.ramp(stops, bilinear(f, fx, fy))
                let k = (j * w + i) * 4
                px[k] = byte(c.r)
                px[k + 1] = byte(c.g)
                px[k + 2] = byte(c.b)
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// ── Die Karte selbst ─────────────────────────────────────────────
struct SmoothMap: View {
    let data: MapData
    var liveRPM: Double? = nil
    var liveKPa: Double? = nil
    var selected: MapCell? = nil
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
        case .spread: return ("ruhig", "±0.03", "unruhig ±0.06")
        case .count:  return ("wenig", "", maxCount > 0 ? "\(maxCount) Werte" : "viel")
        }
    }
}

// ── Karte mit Umschalter, Skala und Wert der angetippten Zelle ───
struct KennfeldPanel: View {
    let session: TuningSession
    let rpm: Double?
    let map: Double?

    @AppStorage("mapMode") private var mode: MapMode = .lambda
    @State private var selected: MapCell?

    var body: some View {
        let data = MapData(session: session, mode: mode)
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(title: "Lambda-Kennfeld")
                Picker("Ansicht", selection: $mode) {
                    ForEach(MapMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                SmoothMap(data: data, liveRPM: rpm, liveKPa: map, selected: selected) { cell in
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
        let n = session.count(row: cell.row, col: cell.col)
        let lam = session.lambda(row: cell.row, col: cell.col)
        let sp = session.spread(row: cell.row, col: cell.col)
        let lo = TuningSession.rowLow(cell.row)
        let place = String(format: "%.0f U/min · %.0f–%.0f kPa", TuningSession.colCenter(cell.col), lo, lo + 10)
        let value = lam.map { String(format: "λ %.3f", $0) } ?? "zu wenige Werte"
        let valueColor: Color = lam.map { RGB.ramp(MapMode.lambda.stops, $0).color } ?? Theme.muted
        return HStack(alignment: .center, spacing: 10) {
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
                Text(detail(n: n, spread: sp))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Theme.muted)
            }
        }
        .padding(10)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func detail(n: Int, spread: Double?) -> String {
        let werte = n == 1 ? "1 Wert" : "\(n) Werte"
        guard let spread else { return werte }
        return String(format: "±%.3f · ", spread) + werte
    }

    private var explanation: String {
        switch mode {
        case .lambda:
            return "Mittleres Lambda je Drehzahl und Last, zwischen den Zellen weich gemischt. Das Fadenkreuz ist der aktuelle Betriebspunkt."
        case .spread:
            return "Wie stark Lambda in diesem Bereich schwankt. Rot heißt unruhig: Dort springt das Gemisch, zum Beispiel beim Übergang oder beim Gasgeben. Wird erst ab Version 1.2 erfasst, ältere Messreihen bleiben hier dunkel."
        case .count:
            return "Wie viele Messwerte in jedem Bereich stecken. Wo wenig gemessen wurde, ist die Farbe im Lambda-Bild noch unsicher."
        }
    }
}
