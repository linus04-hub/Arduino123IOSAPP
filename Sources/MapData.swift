import SwiftUI
import CoreGraphics

// ── Kennfeld als Bild ────────────────────────────────────────────
// Gemeinsam fuer iPhone und Mac. Die Werte zwischen den Zellmitten werden
// bilinear gemischt, dadurch sieht man Verlaeufe statt Kaestchen.

enum MapMode: String, CaseIterable, Identifiable {
    case lambda, delta, spread, count, advance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lambda: return "Lambda"
        case .delta:  return "Δ Ziel"
        case .spread: return "Streuung"
        case .count:  return "Anzahl"
        case .advance: return "Zündung"
        }
    }

    /// Stuetzstellen der Farbskala. Bei "Anzahl" laeuft der Wert von 0 bis 1.
    var stops: [(Double, RGB)] {
        switch self {
        case .lambda:
            return [(0.90, RGB(70, 100, 255)), (0.95, RGB(64, 196, 255)), (1.00, RGB(46, 204, 113)),
                    (1.05, RGB(253, 140, 0)), (1.10, RGB(231, 76, 60))]
        case .delta:
            // Abweichung vom Ziel: blau zu fett, gruen passt, rot zu mager
            return [(-0.12, RGB(70, 100, 255)), (-0.06, RGB(64, 196, 255)), (-0.03, RGB(46, 204, 113)),
                    (0.03, RGB(46, 204, 113)), (0.06, RGB(253, 140, 0)), (0.12, RGB(231, 76, 60))]
        case .spread:
            return [(0.00, RGB(46, 204, 113)), (0.02, RGB(241, 196, 15)), (0.04, RGB(253, 140, 0)),
                    (0.06, RGB(231, 76, 60))]
        case .count:
            return [(0.0, RGB(40, 44, 80)), (0.5, RGB(52, 120, 210)), (1.0, RGB(140, 225, 255))]
        case .advance:
            return [(5, RGB(52, 73, 140)), (15, RGB(64, 160, 220)), (25, RGB(120, 210, 160)),
                    (35, RGB(240, 200, 80)), (40, RGB(253, 140, 0))]
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

    /// `steady`: nur ruhige Fahrt bei warmem Motor
    init(session: TuningSession, mode: MapMode, steady: Bool = false, targets: MixtureTargets = MixtureTargets()) {
        let rows = TuningSession.rows
        let cols = TuningSession.cols
        var mx = 0
        for r in 0..<rows {
            for c in 0..<cols {
                mx = max(mx, session.count(row: r, col: c, steady: steady))
            }
        }
        let logMax = log(1 + Double(max(1, mx)))
        var v: [[Double?]] = Array(repeating: Array(repeating: nil, count: cols), count: rows)
        for r in 0..<rows {
            for c in 0..<cols {
                switch mode {
                case .lambda:
                    v[r][c] = session.lambda(row: r, col: c, steady: steady)
                case .delta:
                    if let l = session.lambda(row: r, col: c, steady: steady),
                       let t = targets.target(Regime.of(row: r, col: c)) {
                        v[r][c] = l - t
                    }
                case .spread:
                    v[r][c] = session.spread(row: r, col: c, steady: steady)
                case .count:
                    let n = session.count(row: r, col: c, steady: steady)
                    v[r][c] = n > 0 ? log(1 + Double(n)) / logMax : nil
                case .advance:
                    v[r][c] = session.advance(row: r, col: c)
                }
            }
        }
        values = v
        maxCount = mx
        image = Self.render(v, stops: mode.stops)
    }

    /// Bild aus beliebigen Zellwerten (zum Beispiel einer Differenz zweier Messreihen)
    static func image(_ v: [[Double?]], stops: [(Double, RGB)]) -> CGImage? {
        render(v, stops: stops)
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
