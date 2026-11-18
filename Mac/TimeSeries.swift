import SwiftUI
import Observation

// ── Verlauf einer Fahrt: mehrere Spuren uebereinander ───────────
// Jede Spur ein Kanal, gemeinsame Zeitachse. Maus darueber zeigt alle Werte
// an dieser Stelle, Ziehen waehlt einen Abschnitt, Doppelklick zeigt wieder
// die ganze Fahrt. Gezeichnet mit Canvas: schnell auch bei langen Fahrten.

@Observable
final class TripCursor {
    var hover: Double?
}

enum LaneGeo {
    static let left: CGFloat = 116
    static let right: CGFloat = 12
    static let laneHeight: CGFloat = 84
    static func height(_ ch: Channel) -> CGFloat { ch == .lambda ? 128 : laneHeight }
    static func total(_ lanes: [LaneData]) -> CGFloat { lanes.reduce(axis) { $0 + height($1.channel) } }
    static let axis: CGFloat = 22

    static func x(_ t: Double, _ domain: ClosedRange<Double>, width: CGFloat) -> CGFloat {
        let span = max(1e-6, domain.upperBound - domain.lowerBound)
        return left + CGFloat((t - domain.lowerBound) / span) * (width - left - right)
    }

    static func t(_ x: CGFloat, _ domain: ClosedRange<Double>, width: CGFloat) -> Double {
        let span = domain.upperBound - domain.lowerBound
        let f = Double((x - left) / max(1, width - left - right))
        return domain.lowerBound + min(1, max(0, f)) * span
    }
}

struct LaneData: Identifiable {
    var channel: Channel
    var points: [SeriesPoint]
    var colors: [Color]?           // je Punkt (Lambda nach Abstand zum Ziel)
    var target: [SeriesPoint] = [] // Ziel-Lambda des jeweiligen Bereichs
    var yRange: ClosedRange<Double>
    var id: Channel { channel }

    static func make(_ rows: [TripRow], _ ch: Channel, domain: ClosedRange<Double>, targets: MixtureTargets) -> LaneData {
        let pts = Downsample.series(rows, range: domain, buckets: 700) { ch.value($0) }
        var range = ch.range ?? 0...1
        if ch.range == nil, let lo = pts.map({ $0.v }).min(), let hi = pts.map({ $0.v }).max() {
            let pad = max(0.5, (hi - lo) * 0.1)
            range = (lo - pad)...(hi + pad)
        }
        guard ch == .lambda else {
            return LaneData(channel: ch, points: pts, colors: nil, yRange: range)
        }
        var colors: [Color] = []
        colors.reserveCapacity(pts.count)
        for p in pts {
            guard let i = TripIndex.nearest(rows, p.t), let rpm = rows[i].rpm, rpm >= 300, let k = rows[i].map else {
                colors.append(.secondary)
                continue
            }
            let j = MixtureJudge.judge(lambda: p.v, regime: Regime.of(rpm: rpm, kPa: k), targets: targets)
            colors.append(j.target == nil ? .secondary : j.severity.tint)
        }
        let target = Downsample.series(rows, range: domain, buckets: 350) { r in
            guard let rpm = r.rpm, rpm >= 300, let k = r.map else { return nil }
            return targets.target(rpm: rpm, kPa: k)
        }
        return LaneData(channel: ch, points: pts, colors: colors, target: target, yRange: range)
    }
}

/// Alle Spuren. Equatable ueber `key`, damit die Maus nicht alles neu zeichnet.
struct LanesView: View, Equatable {
    let key: String
    let lanes: [LaneData]
    let domain: ClosedRange<Double>
    let start: Date

    static func == (a: LanesView, b: LanesView) -> Bool { a.key == b.key }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(lanes) { lane in
                LaneCanvas(lane: lane, domain: domain)
                    .frame(height: LaneGeo.height(lane.channel))
            }
            TimeAxis(domain: domain, start: start)
                .frame(height: LaneGeo.axis)
        }
    }
}

struct LaneCanvas: View {
    let lane: LaneData
    let domain: ClosedRange<Double>

    var body: some View {
        Canvas { ctx, size in
            let ch = lane.channel
            let top: CGFloat = 4
            let h = size.height - 8
            let lo = lane.yRange.lowerBound
            let span = max(1e-9, lane.yRange.upperBound - lo)
            func y(_ v: Double) -> CGFloat { top + CGFloat(1 - (min(lane.yRange.upperBound, max(lo, v)) - lo) / span) * h }
            func x(_ t: Double) -> CGFloat { LaneGeo.x(t, domain, width: size.width) }

            // Hintergrund und Gitter
            let plot = CGRect(x: LaneGeo.left, y: top, width: size.width - LaneGeo.left - LaneGeo.right, height: h)
            ctx.fill(Path(plot), with: .color(Color(nsColor: .textBackgroundColor).opacity(0.5)))
            var grid = Path()
            let small = Font.system(size: 9).monospacedDigit()
            for g in ch.grid where g > lo && g < lane.yRange.upperBound {
                grid.move(to: CGPoint(x: plot.minX, y: y(g)))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y(g)))
                ctx.draw(Text(Self.short(g, ch)).font(small).foregroundColor(.secondary),
                         at: CGPoint(x: plot.minX - 4, y: y(g)), anchor: .trailing)
            }
            ctx.stroke(grid, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.5)
            if ch == .lambda {
                var one = Path()
                one.move(to: CGPoint(x: plot.minX, y: y(1)))
                one.addLine(to: CGPoint(x: plot.maxX, y: y(1)))
                ctx.stroke(one, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }
            // Titel
            ctx.draw(Text(ch.title).font(.system(size: 11, weight: .semibold)).foregroundColor(ch.tint == .primary ? .primary : ch.tint),
                     at: CGPoint(x: 6, y: top + 2), anchor: .topLeading)
            if !ch.unit.isEmpty {
                ctx.draw(Text(ch.unit).font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: 6, y: top + 17), anchor: .topLeading)
            }

            var clipped = ctx
            clipped.clip(to: Path(plot))

            // Ziel-Lambda
            if !lane.target.isEmpty {
                var p = Path()
                var prev: SeriesPoint?
                for q in lane.target {
                    let pt = CGPoint(x: x(q.t), y: y(q.v))
                    if let pr = prev, pr.seg == q.seg { p.addLine(to: pt) } else { p.move(to: pt) }
                    prev = q
                }
                clipped.stroke(p, with: .color(.green.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
            }

            // Werte
            let pts = lane.points
            guard pts.count > 1 else { return }
            if let colors = lane.colors, colors.count == pts.count {
                var i = 1
                while i < pts.count {
                    let col = colors[i]
                    var p = Path()
                    p.move(to: CGPoint(x: x(pts[i - 1].t), y: y(pts[i - 1].v)))
                    while i < pts.count && colors[i] == col {
                        let pt = CGPoint(x: x(pts[i].t), y: y(pts[i].v))
                        if pts[i].seg == pts[i - 1].seg { p.addLine(to: pt) } else { p.move(to: pt) }
                        i += 1
                    }
                    clipped.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                }
            } else {
                var p = Path()
                for (i, q) in pts.enumerated() {
                    let pt = CGPoint(x: x(q.t), y: y(q.v))
                    if i > 0 && pts[i - 1].seg == q.seg { p.addLine(to: pt) } else { p.move(to: pt) }
                }
                clipped.stroke(p, with: .color(ch.tint), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            }
        }
    }

    static func short(_ v: Double, _ ch: Channel) -> String {
        switch ch {
        case .lambda: return String(format: "%.1f", v)
        case .rpm:    return String(format: "%.0fk", v / 1000)
        default:      return String(format: v == v.rounded() ? "%.0f" : "%.1f", v)
        }
    }
}

struct TimeAxis: View {
    let domain: ClosedRange<Double>
    let start: Date

    var body: some View {
        Canvas { ctx, size in
            let span = domain.upperBound - domain.lowerBound
            let steps: [Double] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
            let step = steps.first { span / $0 <= 9 } ?? 3600
            var t = (domain.lowerBound / step).rounded(.up) * step
            let f = DateFormatter()
            f.locale = Locale(identifier: "de_DE")
            f.dateFormat = step < 60 ? "HH:mm:ss" : "HH:mm"
            while t <= domain.upperBound {
                let x = LaneGeo.x(t, domain, width: size.width)
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: 0))
                tick.addLine(to: CGPoint(x: x, y: 4))
                ctx.stroke(tick, with: .color(.secondary), lineWidth: 1)
                ctx.draw(Text(f.string(from: start.addingTimeInterval(t))).font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary), at: CGPoint(x: x, y: 13))
                t += step
            }
        }
    }
}

/// Maus-Linie, Auswahl und Gesten ueber den Spuren
struct CursorOverlay: View {
    let cursor: TripCursor
    @Binding var selection: ClosedRange<Double>?
    let domain: ClosedRange<Double>
    let onReset: () -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                if let s = selection {
                    let a = LaneGeo.x(s.lowerBound, domain, width: w)
                    let b = LaneGeo.x(s.upperBound, domain, width: w)
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay(Rectangle().stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
                        .frame(width: max(1, b - a), height: max(0, geo.size.height - LaneGeo.axis))
                        .offset(x: a)
                }
                HoverLine(cursor: cursor, domain: domain, width: w, height: geo.size.height - LaneGeo.axis)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    cursor.hover = p.x >= LaneGeo.left ? LaneGeo.t(p.x, domain, width: w) : nil
                case .ended:
                    cursor.hover = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { v in
                    let a = LaneGeo.t(v.startLocation.x, domain, width: w)
                    let b = LaneGeo.t(v.location.x, domain, width: w)
                    selection = min(a, b)...max(a, b)
                    cursor.hover = b
                }
                .onEnded { _ in
                    if let s = selection, s.upperBound - s.lowerBound < 1 { selection = nil }
                })
            .onTapGesture(count: 2) { onReset() }
            .onTapGesture(count: 1) { selection = nil }
        }
    }
}

struct HoverLine: View {
    let cursor: TripCursor
    let domain: ClosedRange<Double>
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        if let t = cursor.hover {
            Rectangle()
                .fill(Color.primary.opacity(0.55))
                .frame(width: 1, height: max(0, height))
                .offset(x: LaneGeo.x(t, domain, width: width))
                .allowsHitTesting(false)
        }
    }
}

/// Werte an der Mausposition
struct HoverReadout: View {
    let cursor: TripCursor
    let rows: [TripRow]
    let start: Date
    let targets: MixtureTargets

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = cursor.hover, let i = TripIndex.nearest(rows, t) {
                let r = rows[i]
                Text(Fmt.time(start.addingTimeInterval(r.t)))
                    .font(.headline.monospacedDigit())
                Text("nach " + TimeText.clock(r.t) + " min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let rpm = r.rpm, rpm >= 300, let k = r.map {
                    let g = Regime.of(rpm: rpm, kPa: k)
                    HStack(spacing: 5) {
                        Circle().fill(g.tint).frame(width: 8, height: 8)
                        Text(g.title).font(.caption.weight(.semibold))
                    }
                    if let l = r.lambdaValid, let tg = targets.target(g) {
                        let j = MixtureJudge.judge(lambda: l, regime: g, targets: targets)
                        Text(String(format: "Ziel %.2f · %+.3f · ", tg, l - tg) + j.text)
                            .font(.caption)
                            .foregroundStyle(j.severity.tint)
                    }
                } else {
                    Text(r.rpm == nil ? "keine Drehzahl" : "Motor steht").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(Channel.allCases) { ch in
                        GridRow {
                            Text(ch.title).foregroundStyle(.secondary)
                            Text(ch.value(r).map { ch.format($0) } ?? "–")
                                .fontWeight(ch == .lambda ? .bold : .regular)
                                .gridColumnAlignment(.trailing)
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
                if let m = r.marker {
                    Label("Markierung \(m)", systemImage: "flag.fill").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Maus über den Verlauf bewegen").font(.caption).foregroundStyle(.secondary)
                Text("Ziehen wählt einen Abschnitt, Doppelklick zeigt die ganze Fahrt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(width: 220, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}
