import SwiftUI

// ── Kennfeld gross: Farbkarte mit Zahlen und Tooltip ─────────────
// Zeilen: Saugrohrdruck 20…100 kPa (unten wenig, oben viel Last).
// Spalten: Drehzahl 1000…6000 U/min. Die Farbe ist weich gemischt,
// die Zahl in der Zelle ist der gemessene Wert.

struct HeatmapView: View {
    let values: [[Double?]]
    let image: CGImage?
    let stops: [(Double, RGB)]
    let digits: Int
    var signed = false
    var counts: [[Int]]? = nil
    var emptyDim = 0.45                  // Zellen ohne Werte abdunkeln
    var labels: [[String?]]? = nil        // statt der Zahlen aus `values`
    var tooltip: ((Int, Int) -> [String])? = nil
    var showRegimes = true

    @State private var hover: MapCell?
    @State private var mouse: CGPoint = .zero

    private let left: CGFloat = 52
    private let bottom: CGFloat = 26
    private let top: CGFloat = 6
    private let right: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: left, y: top, width: max(10, geo.size.width - left - right),
                              height: max(10, geo.size.height - top - bottom))
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(ctx, plot) }
                if let h = hover, let tip = tooltip?(h.row, h.col), !tip.isEmpty {
                    tooltipView(tip)
                        .offset(x: min(mouse.x + 14, geo.size.width - 230), y: max(0, mouse.y - 10))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    mouse = p
                    hover = cell(at: p, plot)
                case .ended:
                    hover = nil
                }
            }
        }
    }

    private func cell(at p: CGPoint, _ plot: CGRect) -> MapCell? {
        guard plot.contains(p) else { return nil }
        let cw = plot.width / CGFloat(TuningSession.cols)
        let ch = plot.height / CGFloat(TuningSession.rows)
        let c = Int((p.x - plot.minX) / cw)
        let r = TuningSession.rows - 1 - Int((p.y - plot.minY) / ch)
        guard c >= 0, c < TuningSession.cols, r >= 0, r < TuningSession.rows else { return nil }
        return MapCell(row: r, col: c)
    }

    private func draw(_ ctx: GraphicsContext, _ plot: CGRect) {
        let rows = TuningSession.rows
        let cols = TuningSession.cols
        let cw = plot.width / CGFloat(cols)
        let ch = plot.height / CGFloat(rows)
        let bg = RoundedRectangle(cornerRadius: 6).path(in: plot)
        ctx.fill(bg, with: .color(Color(nsColor: .underPageBackgroundColor)))
        if let img = image {
            var c = ctx
            c.clip(to: bg)
            c.draw(Image(decorative: img, scale: 1).interpolation(.high), in: plot)
        }
        // Zellen ohne Werte abdunkeln, damit die Mischung nicht mehr verspricht als da ist
        for r in 0..<rows {
            for c in 0..<cols where values[r][c] == nil {
                let rect = CGRect(x: plot.minX + CGFloat(c) * cw, y: plot.minY + CGFloat(rows - 1 - r) * ch,
                                  width: cw, height: ch)
                ctx.fill(Path(rect), with: .color(Color.black.opacity(image == nil ? 0 : emptyDim)))
            }
        }
        // Gitter
        var grid = Path()
        for c in 0...cols {
            let x = plot.minX + CGFloat(c) * cw
            grid.move(to: CGPoint(x: x, y: plot.minY))
            grid.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        for r in 0...rows {
            let y = plot.minY + CGFloat(r) * ch
            grid.move(to: CGPoint(x: plot.minX, y: y))
            grid.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        ctx.stroke(grid, with: .color(Color.black.opacity(0.18)), lineWidth: 0.5)

        // Grenzen der Betriebsbereiche
        if showRegimes {
            var lines = Path()
            for r in 0..<rows {
                for c in 0..<cols {
                    let g = Regime.of(row: r, col: c)
                    let x = plot.minX + CGFloat(c) * cw
                    let y = plot.minY + CGFloat(rows - 1 - r) * ch
                    if c + 1 < cols, Regime.of(row: r, col: c + 1) != g {
                        lines.move(to: CGPoint(x: x + cw, y: y))
                        lines.addLine(to: CGPoint(x: x + cw, y: y + ch))
                    }
                    if r + 1 < rows, Regime.of(row: r + 1, col: c) != g {
                        lines.move(to: CGPoint(x: x, y: y))
                        lines.addLine(to: CGPoint(x: x + cw, y: y))
                    }
                }
            }
            ctx.stroke(lines, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }

        // Werte
        let fontSize = min(13, max(9, cw / 4.6))
        for r in 0..<rows {
            for c in 0..<cols {
                guard let v = values[r][c] else { continue }
                let center = CGPoint(x: plot.minX + (CGFloat(c) + 0.5) * cw,
                                     y: plot.minY + (CGFloat(rows - 1 - r) + 0.5) * ch)
                var s = signed ? SignedText.of(v, digits) : String(format: "%.\(digits)f", v)
                if let l = labels {
                    guard let t = l[r][c] else { continue }
                    s = t
                }
                let bgc = RGB.ramp(stops, v)
                let dark = (bgc.r * 0.299 + bgc.g * 0.587 + bgc.b * 0.114) < 140
                ctx.draw(Text(s).font(.system(size: fontSize, weight: .semibold).monospacedDigit())
                    .foregroundColor(dark ? .white : .black), at: center)
                if let n = counts?[r][c], ch > 34 {
                    ctx.draw(Text("\(n)").font(.system(size: 9).monospacedDigit())
                        .foregroundColor((dark ? Color.white : Color.black).opacity(0.6)),
                             at: CGPoint(x: center.x, y: center.y + fontSize * 0.95))
                }
            }
        }
        if let h = hover {
            let rect = CGRect(x: plot.minX + CGFloat(h.col) * cw, y: plot.minY + CGFloat(rows - 1 - h.row) * ch,
                              width: cw, height: ch)
            ctx.stroke(Path(rect), with: .color(.white), lineWidth: 2)
        }

        // Achsen
        let label = Font.system(size: 10).monospacedDigit()
        for c in stride(from: 0, to: cols, by: 2) {
            ctx.draw(Text(String(format: "%.0f", TuningSession.colCenter(c))).font(label).foregroundColor(.secondary),
                     at: CGPoint(x: plot.minX + (CGFloat(c) + 0.5) * cw, y: plot.maxY + 12))
        }
        for r in 0..<rows {
            let lo = TuningSession.rowLow(r)
            ctx.draw(Text(String(format: "%.0f–%.0f", lo, lo + 10)).font(label).foregroundColor(.secondary),
                     at: CGPoint(x: plot.minX - 6, y: plot.minY + (CGFloat(rows - 1 - r) + 0.5) * ch), anchor: .trailing)
        }
    }

    private func tooltipView(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                Text(l)
                    .font(i == 0 ? .caption.weight(.semibold) : .caption)
                    .monospacedDigit()
            }
        }
        .padding(8)
        .frame(width: 210, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Farbskala unter der Karte
struct ColorLegend: View {
    let stops: [(Double, RGB)]
    let labels: (String, String, String)

    var body: some View {
        VStack(spacing: 3) {
            LinearGradient(stops: stops.enumerated().map { i, s in
                Gradient.Stop(color: s.1.color, location: CGFloat(i) / CGFloat(max(1, stops.count - 1)))
            }, startPoint: .leading, endPoint: .trailing)
            .frame(height: 8)
            .clipShape(Capsule())
            HStack {
                Text(labels.0)
                Spacer()
                Text(labels.1)
                Spacer()
                Text(labels.2)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

extension MapMode {
    var legend: (String, String, String) {
        switch self {
        case .lambda:  return ("0.90 fett", "1.00", "mager 1.10")
        case .delta:   return ("−0.12 fetter als Ziel", "Ziel", "magerer als Ziel +0.12")
        case .spread:  return ("ruhig", "", "unruhig")
        case .count:   return ("wenig Werte", "", "viele Werte")
        case .advance: return ("5°", "25°", "40°")
        }
    }

    var digits: Int {
        switch self {
        case .lambda, .delta, .spread: return 2
        case .count, .advance:         return 0
        }
    }
}
