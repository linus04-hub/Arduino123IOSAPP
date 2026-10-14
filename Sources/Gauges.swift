import SwiftUI

// ── Bewegung ─────────────────────────────────────────────────────
// Kritisch gedaempfte Federn: Werte folgen jedem neuen Messwert ohne
// Ueberschwingen. Kommt der naechste Wert mitten in der Bewegung, wird
// mit der aktuellen Geschwindigkeit weitergefahren statt neu zu starten.
// SwiftUI rechnet die Zwischenwerte mit Bildschirmrate (bis 120 Hz).
enum Motion {
    static let value = Animation.spring(response: 0.40, dampingFraction: 1.0)  // Bridge, ca. 10 Werte/s
    static let slow  = Animation.spring(response: 0.70, dampingFraction: 1.0)  // 123, seltener neue Werte
}

/// Zahl, die zwischen zwei Messwerten fluessig mitlaeuft statt zu springen.
struct RollingNumber: View, Animatable {
    var value: Double
    let render: (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(render(value)) }
}

// ── Karte wie auf dem Display: dunkle Kachel, 4px-Streifen in Statusfarbe ──
struct Card<Content: View>: View {
    let level: Level
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 12, leading: 18, bottom: 13, trailing: 14))
            .background(Theme.surface)
            .overlay(alignment: .leading) {
                Rectangle().fill(level.stripe).frame(width: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.easeInOut(duration: 0.3), value: level)
    }
}

struct CardLabel: View {
    let title: String
    var symbol: String? = nil   // SF Symbol
    var glyph: String? = nil    // Textzeichen, z. B. λ

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            }
            if let glyph {
                Text(glyph).font(.system(size: 15, weight: .bold))
            }
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
        }
        .foregroundColor(Theme.muted)
    }
}

/// Grosse Zahl. `value == nil` zeigt den Platzhalter (keine Daten / Sensorfehler).
struct BigValue: View {
    let value: Double?
    var format: String = "%.1f"
    var placeholder: String = "--"
    var unit: String = ""
    let level: Level
    var size: CGFloat = 40
    var motion: Animation = Motion.value
    var render: ((Double) -> String)? = nil

    private func text(_ v: Double) -> String { render?(v) ?? String(format: format, v) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if let v = value {
                    RollingNumber(value: v, render: text)
                        .animation(motion, value: v)
                } else {
                    Text(placeholder)
                }
            }
            .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundColor(level.color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.muted)
            }
        }
    }
}

struct StatusText: View {
    let text: String
    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 13))
            .foregroundColor(Theme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

// ── Lambda mit Fett/Mager-Skala 0.85..1.15 ───────────────────────
struct LambdaCard: View {
    let value: Double?

    private var judged: (Level, String) {
        guard let v = value else { return (.off, "keine Daten") }
        return Limits.lambda(v)
    }

    var body: some View {
        Card(level: judged.0) {
            VStack(alignment: .leading, spacing: 2) {
                CardLabel(title: "Lambda", glyph: "λ")
                // 4.5 = Sonde nicht bereit -> Platzhalter statt Zahl
                BigValue(value: value.flatMap { $0 <= 2 ? $0 : nil },
                         format: "%.3f", placeholder: "-.---",
                         level: judged.0, size: 56)
                StatusText(text: judged.1)
                LambdaScale(lambda: value).padding(.top, 10)
            }
        }
    }
}

struct LambdaScale: View {
    let lambda: Double?
    var showLabels = true

    // Zonen wie im Display: 0.94 / 0.98 / 1.02 / 1.06 auf 0.85..1.15
    private var zones: [(Color, CGFloat)] { [
        (Theme.crit, 0.30), (Theme.warn, 0.1333), (Theme.ok, 0.1334), (Theme.warn, 0.1333), (Theme.crit, 0.30)
    ] }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<zones.count, id: \.self) { i in
                            Rectangle()
                                .fill(zones[i].0.opacity(0.6))
                                .frame(width: w * zones[i].1)
                        }
                    }
                    .frame(height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                    if let l = lambda, l <= 2 {
                        let t = min(1, max(0, (l - 0.85) / 0.30))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.fg)
                            .frame(width: 4, height: 18)
                            .background {
                                RoundedRectangle(cornerRadius: 2).fill(Theme.bg).padding(-2)
                            }
                            .offset(x: w * CGFloat(t) - 2)
                            .animation(Motion.value, value: t)
                    }
                }
                .frame(height: 18)
            }
            .frame(height: 18)

            if showLabels {
                ZStack {
                    Text("fett 0.85").frame(maxWidth: .infinity, alignment: .leading)
                    Text("1.00")
                    Text("1.15 mager").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Theme.muted)
            }
        }
        .accessibilityHidden(true)
    }
}

// ── Oeldruck / Oeltemperatur / Zuendwinkel / Saugrohr ────────────
struct ValueCard: View {
    let title: String
    let symbol: String
    let unit: String
    let value: Double?
    var format: String = "%.1f"
    var placeholder: String = "--"
    let level: Level
    let status: String
    var motion: Animation = Motion.value

    var body: some View {
        Card(level: level) {
            VStack(alignment: .leading, spacing: 2) {
                CardLabel(title: title, symbol: symbol)
                BigValue(value: value, format: format, placeholder: placeholder,
                         unit: unit, level: level, motion: motion)
                StatusText(text: status)
            }
        }
    }
}

// ── Tank mit Balken ──────────────────────────────────────────────
struct TankCard: View {
    let value: Double?

    private var judged: (Level, String) {
        guard let v = value else { return (.off, "") }
        return Limits.tank(v)
    }

    var body: some View {
        let level = judged.0
        let frac = CGFloat(min(100, max(0, value ?? 0)) / 100)
        Card(level: level) {
            VStack(alignment: .leading, spacing: 2) {
                CardLabel(title: "Tank", symbol: "fuelpump.fill")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    BigValue(value: value, format: "%.0f", unit: "%", level: level)
                    StatusText(text: judged.1)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface2)
                        Capsule()
                            .fill(level.color)
                            .frame(width: geo.size.width * frac)
                            .animation(Motion.value, value: frac)
                    }
                }
                .frame(height: 12)
                .padding(.top, 8)
            }
        }
    }
}

// ── Lambda-Verlauf der letzten 60 s (Standard-Ansicht) ───────────
struct GraphCard: View {
    let samples: [Sample]

    var body: some View {
        let vals = samples.compactMap { $0.lambda }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                CardLabel(title: "Lambda-Verlauf · 60 s")
                Spacer()
                Text(vals.isEmpty ? "min –  ·  max –"
                     : String(format: "min %.3f  ·  max %.3f", vals.min()!, vals.max()!))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(Theme.muted)
            }
            TrendGraph(samples: samples, metric: .lambda).frame(height: 150)
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Verlauf eines Messwerts ueber 60 s, optional mit einem zweiten Wert als
/// duenne Linie dahinter (eigener Massstab). Zeitbasiert gezeichnet: die
/// Kurve wandert gleichmaessig nach links statt in Schritten.
struct TrendGraph: View {
    let samples: [Sample]
    let metric: Metric
    var overlay: Metric? = nil

    private var window: TimeInterval { BLEManager.graphWindow }

    private var hasData: Bool {
        samples.contains { s in
            metric.value(in: s) != nil || (overlay.map { $0.value(in: s) != nil } ?? false)
        }
    }

    var body: some View {
        // ohne Messwerte im Fenster gibt es nichts zu bewegen -> Timeline anhalten
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !hasData)) { timeline in
            Canvas { ctx, size in
                draw(ctx: ctx, size: size, now: timeline.date)
            }
        }
        .accessibilityLabel("\(metric.title)-Verlauf der letzten 60 Sekunden")
    }

    private func draw(ctx: GraphicsContext, size: CGSize, now: Date) {
        let left: CGFloat = 34, right: CGFloat = 8, top: CGFloat = 6, bottom: CGFloat = 18
        let w = size.width - left - right
        let h = size.height - top - bottom
        func y(_ v: Double, _ m: Metric) -> CGFloat {
            let r = m.range
            let c = min(r.upperBound, max(r.lowerBound, v))
            return top + CGFloat((r.upperBound - c) / (r.upperBound - r.lowerBound)) * h
        }
        func x(_ t: Date) -> CGFloat {
            left + w * CGFloat(1 - now.timeIntervalSince(t) / window)
        }

        // Lambda: Zielbereich 0.98..1.02 hinterlegen
        if metric == .lambda {
            let band = CGRect(x: left, y: y(1.02, .lambda), width: w, height: y(0.98, .lambda) - y(1.02, .lambda))
            ctx.fill(Path(band), with: .color(Theme.ok.opacity(0.08)))
        }
        // Raster mit Beschriftung, Lambda 1.0 gestrichelt
        for g in metric.gridLines {
            var p = Path()
            p.move(to: CGPoint(x: left, y: y(g, metric)))
            p.addLine(to: CGPoint(x: left + w, y: y(g, metric)))
            let isOne = metric == .lambda && abs(g - 1.0) < 0.001
            ctx.stroke(p, with: .color(isOne ? Theme.muted : Theme.line),
                       style: StrokeStyle(lineWidth: 1, dash: isOne ? [4, 4] : []))
            ctx.draw(Text(String(format: metric.gridFormat, g)).font(.system(size: 10)).foregroundColor(Theme.muted),
                     at: CGPoint(x: left - 6, y: y(g, metric)), anchor: .trailing)
        }
        ctx.draw(Text("−60 s").font(.system(size: 11)).foregroundColor(Theme.muted),
                 at: CGPoint(x: left, y: size.height), anchor: .bottomLeading)
        ctx.draw(Text("jetzt").font(.system(size: 11)).foregroundColor(Theme.muted),
                 at: CGPoint(x: left + w, y: size.height), anchor: .bottomTrailing)

        // Nur im Diagrammbereich zeichnen, aeltere Punkte laufen links raus
        var plot = ctx
        plot.clip(to: Path(CGRect(x: left, y: 0, width: w + right, height: size.height)))

        // zweiter Wert als duenne Linie dahinter
        if let o = overlay {
            var p = Path()
            var open = false
            for s in samples {
                guard let v = o.value(in: s) else { open = false; continue }
                let pt = CGPoint(x: x(s.time), y: y(v, o))
                if open { p.addLine(to: pt) } else { p.move(to: pt); open = true }
            }
            plot.stroke(p, with: .color(Theme.accent.opacity(0.55)),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }

        // Hauptlinie, jedes Stueck in der Statusfarbe seines Werts
        for i in samples.indices.dropFirst() {
            guard let a = metric.value(in: samples[i - 1]), let b = metric.value(in: samples[i]) else { continue }
            var p = Path()
            p.move(to: CGPoint(x: x(samples[i - 1].time), y: y(a, metric)))
            p.addLine(to: CGPoint(x: x(samples[i].time), y: y(b, metric)))
            plot.stroke(p, with: .color(metric.lineColor(b)),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
        if let last = samples.last, let v = metric.value(in: last) {
            let c = CGPoint(x: x(last.time), y: y(v, metric))
            plot.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)),
                      with: .color(metric.lineColor(v)))
        }
    }
}

// ── 123ignition ──────────────────────────────────────────────────

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.4)
            .foregroundColor(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }
}

/// Drehzahl gross, mit Balken bis rpmScaleMax und Markierung ab rpmWarn
struct RPMCard: View {
    let rpm: Double?
    let status: String

    private var level: Level { rpm.map { Limits.rpm($0) } ?? .off }

    var body: some View {
        Card(level: level) {
            VStack(alignment: .leading, spacing: 2) {
                CardLabel(title: "Drehzahl", symbol: "speedometer")
                // waehrend der Bewegung in 10er-Schritten, damit die Zahl ruhig bleibt
                BigValue(value: rpm, placeholder: "----", unit: "U/min", level: level,
                         size: 56, motion: Motion.slow,
                         render: { String(format: "%.0f", ($0 / 10).rounded() * 10) })
                StatusText(text: status)
                RPMBar(rpm: rpm).padding(.top, 8)

                HStack {
                    Text("0")
                    Spacer()
                    Text(String(format: "%.0f", Limits.rpmScaleMax))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Theme.muted)
            }
        }
    }
}

/// Kleine Karte fuer Nebenwerte (Spannung, Spule, Modultemperatur)
struct CompactCard: View {
    let title: String
    let value: Double?
    var format: String = "%.1f"
    var placeholder: String = "--"
    let unit: String
    let level: Level
    var status: String = ""

    var body: some View {
        Card(level: level) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                BigValue(value: value, format: format, placeholder: placeholder,
                         unit: unit, level: level, size: 24, motion: Motion.slow)
                StatusText(text: status)
            }
        }
    }
}

/// Drehzahlbalken bis rpmScaleMax, Bereich ab rpmWarn dezent rot
struct RPMBar: View {
    let rpm: Double?
    var height: CGFloat = 10

    private var level: Level { rpm.map { Limits.rpm($0) } ?? .off }

    var body: some View {
        let frac = CGFloat(min(1, max(0, (rpm ?? 0) / Limits.rpmScaleMax)))
        GeometryReader { geo in
            let w = geo.size.width
            let warnX = w * CGFloat(Limits.rpmWarn / Limits.rpmScaleMax)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface2)
                Rectangle()
                    .fill(Theme.crit.opacity(0.25))
                    .frame(width: w - warnX)
                    .offset(x: warnX)
                Capsule()
                    .fill(level.stripe)
                    .frame(width: w * frac)
                    .animation(Motion.slow, value: frac)
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

// ── Bausteine der neuen Ansichten ────────────────────────────────

/// Schlichte Flaeche ohne Statusstreifen
struct Panel<Content: View>: View {
    var radius: CGFloat = 14
    var padding: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Kleiner Wert mit Titel, fuer Kachelreihen
struct SmallStat: View {
    let metricTitle: String
    let value: Double?
    var format: String = "%.1f"
    var placeholder: String = "--"
    let unit: String
    var level: Level = .info
    var motion: Animation = Motion.slow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(metricTitle.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundColor(Theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Group {
                    if let v = value {
                        RollingNumber(value: v, render: { String(format: format, $0) })
                            .animation(motion, value: v)
                    } else {
                        Text(placeholder)
                    }
                }
                .font(.system(size: 19, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundColor(level.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Rundinstrument: 240°-Skala, Zeiger mit Feder, Digitalwert unten in der Mitte.
/// Hoehe = 1,5 x Radius + Rand; der Aufrufer gibt die Hoehe per .frame vor.
struct Dial: View {
    let value: Double?
    let range: ClosedRange<Double>
    let major: Double                 // Abstand der grossen Striche
    var minorPerMajor = 1             // Teilung zwischen zwei grossen Strichen
    var labelEvery = 1                // jede n-te grosse Marke beschriften
    var labelScale = 1.0              // Beschriftung = Wert / labelScale
    var redFrom: Double? = nil
    var redTo: Double? = nil
    var caption = ""
    var format = "%.0f"
    var placeholder = "--"
    var render: ((Double) -> String)? = nil
    var valueColor: Color = Theme.fg
    var motion: Animation = Motion.slow

    static let start = 150.0
    static let sweep = 240.0

    private func text(_ v: Double) -> String { render?(v) ?? String(format: format, v) }

    private func angle(_ v: Double) -> Double {
        let c = min(range.upperBound, max(range.lowerBound, v))
        return Self.start + Self.sweep * (c - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let r = max(20, min(w / 2 - 6, (geo.size.height - 12) / 1.5))
            let c = CGPoint(x: w / 2, y: r + 6)
            let needle = angle(value ?? range.lowerBound)
            ZStack {
                Canvas { ctx, _ in drawScale(ctx: ctx, c: c, r: r) }

                Capsule()
                    .fill(Theme.accent)
                    .frame(width: r * 0.95, height: max(3, r * 0.035))
                    .offset(x: r * 0.355)            // dreht um den Mittelpunkt, kurzes Ende hinten
                    .rotationEffect(.degrees(needle))
                    .animation(motion, value: needle)
                    .position(c)
                    .opacity(value == nil ? 0.3 : 1)

                Circle()
                    .fill(Theme.fg)
                    .frame(width: r * 0.13, height: r * 0.13)
                    .position(c)

                Group {
                    if let v = value {
                        RollingNumber(value: v, render: text)
                            .animation(motion, value: v)
                    } else {
                        Text(placeholder)
                    }
                }
                .font(.system(size: max(16, r * 0.24), weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundColor(value == nil ? Theme.muted : valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: r * 0.9)
                .position(x: c.x, y: c.y + r * 0.47)
            }
        }
    }

    private func drawScale(ctx: GraphicsContext, c: CGPoint, r: CGFloat) {
        func pt(_ deg: Double, _ rr: CGFloat) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: c.x + rr * CGFloat(cos(a)), y: c.y + rr * CGFloat(sin(a)))
        }
        // Zifferblatt
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.06, y: c.y - r * 1.06, width: r * 2.12, height: r * 2.12)),
                 with: .color(Theme.dialFace))
        // Skalenbogen (clockwise: false = im Uhrzeigersinn auf dem Bildschirm)
        var track = Path()
        track.addArc(center: c, radius: r, startAngle: .degrees(Self.start),
                     endAngle: .degrees(Self.start + Self.sweep), clockwise: false)
        ctx.stroke(track, with: .color(Theme.line), lineWidth: 2)
        if let lo = redFrom {
            var red = Path()
            red.addArc(center: c, radius: r, startAngle: .degrees(angle(lo)),
                       endAngle: .degrees(angle(redTo ?? range.upperBound)), clockwise: false)
            ctx.stroke(red, with: .color(Theme.crit), lineWidth: max(4, r * 0.045))
        }
        // Striche und Zahlen
        let count = Int(((range.upperBound - range.lowerBound) / major + 0.0001).rounded(.down))
        for i in 0...count {
            let v = range.lowerBound + Double(i) * major
            let a = angle(v)
            var p = Path()
            p.move(to: pt(a, r * 0.97))
            p.addLine(to: pt(a, r * 0.85))
            ctx.stroke(p, with: .color(Theme.fg), style: StrokeStyle(lineWidth: max(2, r * 0.02), lineCap: .round))
            if i % labelEvery == 0 {
                let label = String(format: "%.0f", v / labelScale)
                ctx.draw(Text(label)
                            .font(.system(size: max(10, r * 0.12), weight: .heavy, design: .rounded))
                            .foregroundColor(Theme.fg),
                         at: pt(a, r * 0.70))
            }
            if minorPerMajor > 1 {
                for k in 1..<minorPerMajor {
                    let vm = v + major * Double(k) / Double(minorPerMajor)
                    guard vm <= range.upperBound else { break }
                    let am = angle(vm)
                    var q = Path()
                    q.move(to: pt(am, r * 0.97))
                    q.addLine(to: pt(am, r * 0.91))
                    ctx.stroke(q, with: .color(Theme.muted), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
        }
        if !caption.isEmpty {
            ctx.draw(Text(caption).font(.system(size: max(9, r * 0.075), weight: .semibold)).foregroundColor(Theme.muted),
                     at: CGPoint(x: c.x, y: c.y - r * 0.32))
        }
    }
}

/// Punktewolke "Lambda ueber Drehzahl" mit Mittelwert je 500 U/min.
/// Farbe nach Lambda-Zone oder nach Last (Saugrohrdruck der 123).
struct ScatterPlot: View {
    let points: [ScatterPoint]
    let currentRPM: Double?
    let currentLambda: Double?
    let byLoad: Bool

    static let rpmMax = 6000.0
    static let lo = 0.85
    static let hi = 1.15

    /// 30 kPa (Schub, Leerlauf) blau -> 100 kPa (Vollgas) orange
    static func loadColor(_ kPa: Double?) -> Color {
        guard let k = kPa else { return Theme.muted }
        let t = min(1, max(0, (k - 30) / 70))
        return Color(red: 0.25 + 0.74 * t, green: 0.77 - 0.22 * t, blue: 1.0 - t)
    }

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .accessibilityLabel("Lambda über Drehzahl")
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let left: CGFloat = 34, right: CGFloat = 8, top: CGFloat = 6, bottom: CGFloat = 18
        let w = size.width - left - right
        let h = size.height - top - bottom
        func x(_ r: Double) -> CGFloat { left + CGFloat(min(Self.rpmMax, max(0, r)) / Self.rpmMax) * w }
        func y(_ l: Double) -> CGFloat { top + CGFloat((Self.hi - min(Self.hi, max(Self.lo, l))) / (Self.hi - Self.lo)) * h }

        ctx.fill(Path(CGRect(x: left, y: y(1.02), width: w, height: y(0.98) - y(1.02))),
                 with: .color(Theme.ok.opacity(0.08)))
        for g in [0.90, 1.00, 1.10] {
            var p = Path()
            p.move(to: CGPoint(x: left, y: y(g)))
            p.addLine(to: CGPoint(x: left + w, y: y(g)))
            let isOne = abs(g - 1.0) < 0.001
            ctx.stroke(p, with: .color(isOne ? Theme.muted : Theme.line),
                       style: StrokeStyle(lineWidth: 1, dash: isOne ? [4, 4] : []))
            ctx.draw(Text(String(format: "%.2f", g)).font(.system(size: 10)).foregroundColor(Theme.muted),
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
        ctx.draw(Text("mager").font(axis).foregroundColor(Theme.muted),
                 at: CGPoint(x: left + w - 2, y: top + 2), anchor: .topTrailing)
        ctx.draw(Text("fett").font(axis).foregroundColor(Theme.muted),
                 at: CGPoint(x: left + w - 2, y: top + h - 2), anchor: .bottomTrailing)

        // Punkte
        for p in points {
            let col = byLoad ? Self.loadColor(p.mapKPa) : Limits.lambda(p.lambda).0.color
            ctx.fill(Path(ellipseIn: CGRect(x: x(p.rpm) - 2.5, y: y(p.lambda) - 2.5, width: 5, height: 5)),
                     with: .color(col.opacity(0.5)))
        }

        // Mittelwert je 500 U/min (nur Abschnitte mit mindestens 3 Punkten)
        var sums = [Double](repeating: 0, count: 13)
        var counts = [Int](repeating: 0, count: 13)
        for p in points {
            let b = Int((p.rpm / 500).rounded())
            if b >= 1 && b < 13 {
                sums[b] += p.lambda
                counts[b] += 1
            }
        }
        var mean = Path()
        var open = false
        for b in 1..<13 {
            guard counts[b] >= 3 else { open = false; continue }
            let pt = CGPoint(x: x(Double(b) * 500), y: y(sums[b] / Double(counts[b])))
            if open { mean.addLine(to: pt) } else { mean.move(to: pt); open = true }
        }
        ctx.stroke(mean, with: .color(Theme.fg), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        // aktueller Punkt
        if let r = currentRPM, let l = currentLambda {
            var v = Path()
            v.move(to: CGPoint(x: x(r), y: top))
            v.addLine(to: CGPoint(x: x(r), y: top + h))
            ctx.stroke(v, with: .color(Theme.accent.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let c = CGPoint(x: x(r), y: y(l))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)),
                       with: .color(Theme.accent), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(Theme.accent))
        }
    }
}
