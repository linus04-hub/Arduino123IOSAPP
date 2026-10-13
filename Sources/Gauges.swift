import SwiftUI

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

struct BigValue: View {
    let text: String
    var unit: String = ""
    let level: Level
    var size: CGFloat = 40

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
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

    private var text: String {
        guard let v = value, v <= 2 else { return "-.---" }
        return String(format: "%.3f", v)
    }

    var body: some View {
        Card(level: judged.0) {
            VStack(alignment: .leading, spacing: 2) {
                CardLabel(title: "Lambda", glyph: "λ")
                BigValue(text: text, level: judged.0, size: 56)
                StatusText(text: judged.1)
                LambdaScale(lambda: value).padding(.top, 10)
            }
        }
    }
}

struct LambdaScale: View {
    let lambda: Double?

    // Zonen wie im Display: 0.94 / 0.98 / 1.02 / 1.06 auf 0.85..1.15
    private let zones: [(Color, CGFloat)] = [
        (Theme.crit, 0.30), (Theme.warn, 0.1333), (Theme.ok, 0.1334), (Theme.warn, 0.1333), (Theme.crit, 0.30)
    ]

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
                    }
                }
                .frame(height: 18)
            }
            .frame(height: 18)

            ZStack {
                Text("fett 0.85").frame(maxWidth: .infinity, alignment: .leading)
                Text("1.00")
                Text("1.15 mager").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundColor(Theme.muted)
        }
        .accessibilityHidden(true)
    }
}

// ── Oeldruck / Oeltemperatur ─────────────────────────────────────
struct ValueCard: View {
    let title: String
    let symbol: String
    let unit: String
    let text: String
    let level: Level
    let status: String

    var body: some View {
        Card(level: level) {
            VStack(alignment: .leading, spacing: 2) {
                CardLabel(title: title, symbol: symbol)
                BigValue(text: text, unit: unit, level: level)
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

    private var text: String {
        guard let v = value else { return "--" }
        return String(format: "%.0f", v)
    }

    var body: some View {
        let level = judged.0
        Card(level: level) {
            VStack(alignment: .leading, spacing: 2) {
                CardLabel(title: "Tank", symbol: "fuelpump.fill")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    BigValue(text: text, unit: "%", level: level)
                    StatusText(text: judged.1)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface2)
                        Capsule()
                            .fill(level.color)
                            .frame(width: geo.size.width * CGFloat(min(100, max(0, value ?? 0)) / 100))
                    }
                }
                .frame(height: 12)
                .padding(.top, 8)
            }
        }
    }
}

// ── Lambda-Verlauf der letzten 60 s ──────────────────────────────
struct GraphCard: View {
    let history: [Double?]

    var body: some View {
        let vals = history.compactMap { $0 }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                CardLabel(title: "Lambda-Verlauf · 60 s")
                Spacer()
                Text(vals.isEmpty ? "min –  ·  max –"
                     : String(format: "min %.3f  ·  max %.3f", vals.min()!, vals.max()!))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(Theme.muted)
            }
            LambdaGraph(history: history).frame(height: 150)
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct LambdaGraph: View {
    let history: [Double?]

    var body: some View {
        Canvas { ctx, size in
            let left: CGFloat = 34, right: CGFloat = 8, top: CGFloat = 6, bottom: CGFloat = 18
            let w = size.width - left - right
            let h = size.height - top - bottom
            let n = max(2, history.count)
            func y(_ v: Double) -> CGFloat { top + CGFloat((1.30 - min(1.30, max(0.70, v))) / 0.60) * h }
            func x(_ i: Int) -> CGFloat { left + CGFloat(i) / CGFloat(n - 1) * w }

            // Raster mit Beschriftung, 1.0 gestrichelt hervorgehoben
            for g in [0.8, 0.9, 1.0, 1.1, 1.2] {
                var p = Path()
                p.move(to: CGPoint(x: left, y: y(g)))
                p.addLine(to: CGPoint(x: left + w, y: y(g)))
                let isOne = abs(g - 1.0) < 0.001
                ctx.stroke(p, with: .color(isOne ? Theme.muted : Theme.line),
                           style: StrokeStyle(lineWidth: 1, dash: isOne ? [4, 4] : []))
                ctx.draw(Text(String(format: "%.1f", g)).font(.system(size: 11)).foregroundColor(Theme.muted),
                         at: CGPoint(x: left - 6, y: y(g)), anchor: .trailing)
            }
            ctx.draw(Text("−60 s").font(.system(size: 11)).foregroundColor(Theme.muted),
                     at: CGPoint(x: left, y: size.height), anchor: .bottomLeading)
            ctx.draw(Text("jetzt").font(.system(size: 11)).foregroundColor(Theme.muted),
                     at: CGPoint(x: left + w, y: size.height), anchor: .bottomTrailing)

            // Linie, jedes Stueck in der Statusfarbe seines Werts
            for i in 1..<history.count {
                guard let a = history[i - 1], let b = history[i] else { continue }
                var p = Path()
                p.move(to: CGPoint(x: x(i - 1), y: y(a)))
                p.addLine(to: CGPoint(x: x(i), y: y(b)))
                ctx.stroke(p, with: .color(Limits.lambda(b).0.color),
                           style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            if let lastOpt = history.last, let last = lastOpt {
                let c = CGPoint(x: x(history.count - 1), y: y(last))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)),
                         with: .color(Limits.lambda(last).0.color))
            }
        }
        .accessibilityLabel("Lambda-Verlauf der letzten 60 Sekunden")
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

    private var text: String {
        guard let r = rpm else { return "----" }
        return String(format: "%.0f", (r / 50).rounded() * 50)   // Aufloesung der 123: 50 U/min
    }

    var body: some View {
        Card(level: level) {
            VStack(alignment: .leading, spacing: 2) {
                CardLabel(title: "Drehzahl", symbol: "speedometer")
                BigValue(text: text, unit: "U/min", level: level, size: 56)
                StatusText(text: status)
                GeometryReader { geo in
                    let w = geo.size.width
                    let frac = CGFloat(min(1, max(0, (rpm ?? 0) / Limits.rpmScaleMax)))
                    let warnX = w * CGFloat(Limits.rpmWarn / Limits.rpmScaleMax)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface2)
                        // Bereich ab rpmWarn dezent markieren
                        Rectangle()
                            .fill(Theme.crit.opacity(0.25))
                            .frame(width: w - warnX)
                            .offset(x: warnX)
                        Capsule()
                            .fill(level.stripe)
                            .frame(width: w * frac)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                .padding(.top, 8)

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
    let text: String
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
                BigValue(text: text, unit: unit, level: level, size: 24)
                StatusText(text: status)
            }
        }
    }
}
