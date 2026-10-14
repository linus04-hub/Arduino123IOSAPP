import SwiftUI

// ── Standard: die bisherige Ansicht ──────────────────────────────
struct StandardLayout: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        VStack(spacing: 10) {
            LambdaCard(value: ble.shown?.lambda)

            HStack(spacing: 10) {
                card(.oilP, symbol: "drop.fill", title: "Öldruck")
                card(.oilT, symbol: "thermometer", title: "Öltemp.")
            }

            TankCard(value: ble.shown?.tankValue)

            SectionLabel(text: "Zündung · 123ignition")

            if let w = ble.tuneWarning {
                WarningBanner(text: w)
            }

            RPMCard(rpm: ble.tune?.rpm, status: rpmStatus)

            HStack(spacing: 10) {
                ValueCard(title: "Zündwinkel", symbol: "bolt.fill", unit: "°",
                          value: ble.tune?.advance, placeholder: "--.-",
                          level: ble.tune?.advance == nil ? .off : .info,
                          status: ble.tune?.advance == nil ? "" : "vor OT",
                          motion: Motion.slow)
                mapCard
            }

            HStack(spacing: 10) {
                CompactCard(title: "Bordnetz", value: ble.tune?.voltage, placeholder: "--.-",
                            unit: "V", level: Metric.voltage.judge(ble.tune?.voltage).0,
                            status: Metric.voltage.judge(ble.tune?.voltage).1)
                CompactCard(title: "Spule", value: ble.tune?.coilCurrent, placeholder: "-.-",
                            unit: "A", level: ble.tune?.coilCurrent == nil ? .off : .info)
                CompactCard(title: "Modul", value: ble.tune?.moduleTemp, format: "%.0f",
                            unit: "°C", level: ble.tune?.moduleTemp.map { Limits.moduleTemp($0) } ?? .off)
            }

            GraphCard(samples: ble.history)
        }
    }

    private func card(_ m: Metric, symbol: String, title: String) -> some View {
        let v = m.current(ble)
        let judged = m.judge(v)
        return ValueCard(title: title, symbol: symbol, unit: m.unit,
                         value: v, format: m.format, placeholder: m.placeholderText(ble),
                         level: judged.0, status: m.status(ble))
    }

    private var rpmStatus: String {
        switch ble.tuneState {
        case .live, .demo:
            return ble.tune?.rpm == nil ? "warte auf Daten …" : ""
        case .connecting:   return "verbinde …"
        case .searching:    return "suche 123ignition …"
        case .bluetoothOff: return "Bluetooth aus"
        case .unauthorized: return "kein Bluetooth-Zugriff"
        }
    }

    /// Saugrohrdruck: absolut in kPa, darunter relativ zur Atmosphaere
    private var mapCard: some View {
        let kPa = ble.tune?.mapKPa
        let status: String = kPa.map { String(format: "%+.2f bar", ($0 - 100) / 100) } ?? ""
        return ValueCard(title: "Saugrohr", symbol: "wind", unit: "kPa",
                         value: kPa, format: "%.0f",
                         level: kPa == nil ? .off : .info,
                         status: status, motion: Motion.slow)
    }
}

// ── B: Rundinstrumente ───────────────────────────────────────────
struct DialsLayout: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        VStack(spacing: 10) {
            Panel(radius: 16) {
                VStack(spacing: 8) {
                    Dial(value: ble.tune?.rpm, range: 0...Limits.rpmScaleMax, major: 1000,
                         minorPerMajor: 2, labelScale: 1000, redFrom: Limits.rpmWarn,
                         caption: "× 1000 U/MIN", placeholder: "----", render: Metric.rpm.render,
                         valueColor: Metric.rpm.judge(ble.tune?.rpm).0.color)
                        .frame(height: 250)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    HStack(spacing: 8) {
                        MiniStat(title: "Zündwinkel", value: ble.tune?.advance, unit: "° vor OT")
                        MiniStat(title: "Saugrohr", value: ble.tune?.mapKPa, format: "%.0f", unit: "kPa")
                    }
                }
            }

            HStack(spacing: 10) {
                dialPanel(.oilP, title: "Öldruck", range: 0...6, major: 1, labelEvery: 1,
                          redFrom: 0, redTo: 1, format: "%.1f")
                dialPanel(.oilT, title: "Öltemperatur", range: 40...160, major: 20, labelEvery: 3,
                          redFrom: 145, redTo: nil, format: "%.0f")
            }

            Panel(radius: 16) {
                let v = Metric.lambda.current(ble)
                let judged = Metric.lambda.judge(v)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        CardLabel(title: "Lambda", glyph: "λ")
                        Spacer()
                        BigValue(value: v, format: "%.3f", placeholder: "-.---", level: judged.0, size: 30)
                    }
                    LambdaScale(lambda: ble.shown?.lambda, showLabels: false)
                    HStack {
                        Text("fett")
                        Spacer()
                        Text(judged.1)
                        Spacer()
                        Text("mager")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                }
            }

            HStack(spacing: 10) {
                SmallStat(metricTitle: "Tank", value: ble.shown?.tankValue, format: "%.0f", unit: "%",
                          level: Metric.tank.judge(ble.shown?.tankValue).0, motion: Motion.value)
                SmallStat(metricTitle: "Bordnetz", value: ble.tune?.voltage, unit: "V",
                          level: Metric.voltage.judge(ble.tune?.voltage).0)
                SmallStat(metricTitle: "Modul", value: ble.tune?.moduleTemp, format: "%.0f", unit: "°C",
                          level: ble.tune?.moduleTemp.map { Limits.moduleTemp($0) } ?? .off)
            }
        }
    }

    private func dialPanel(_ m: Metric, title: String, range: ClosedRange<Double>, major: Double,
                           labelEvery: Int, redFrom: Double, redTo: Double?, format: String) -> some View {
        let v = m.current(ble)
        let judged = m.judge(v)
        return Panel(radius: 16, padding: 8) {
            VStack(spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundColor(Theme.muted)
                Dial(value: v, range: range, major: major, labelEvery: labelEvery,
                     redFrom: redFrom, redTo: redTo, format: format,
                     placeholder: m.placeholderText(ble), valueColor: judged.0.color, motion: m.motion)
                    .frame(height: 124)
                Text(judged.1.isEmpty ? m.unit : "\(m.unit) · \(judged.1)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Titel und Wert nebeneinander im Kopf einer Flaeche
struct MiniStat: View {
    let title: String
    let value: Double?
    var format: String = "%.1f"
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundColor(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Group {
                    if let v = value {
                        RollingNumber(value: v, render: { String(format: format, $0) })
                            .animation(Motion.slow, value: v)
                    } else {
                        Text("--")
                    }
                }
                .font(.system(size: 22, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundColor(value == nil ? Theme.muted : Theme.fg)
                Text(unit)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ── C: Fokus ─────────────────────────────────────────────────────
struct FocusLayout: View {
    @ObservedObject var ble: BLEManager
    @AppStorage("focusMetric") private var focus: Metric = .lambda

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 10) {
            FocusPanel(metric: focus, ble: ble)

            Text("Kachel antippen, um sie groß zu zeigen")
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Metric.allCases.filter { $0 != focus }) { m in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { focus = m }
                    } label: {
                        MetricTile(metric: m, ble: ble)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(m.title) groß zeigen")
                }
            }
        }
    }
}

struct FocusPanel: View {
    let metric: Metric
    @ObservedObject var ble: BLEManager

    var body: some View {
        let v = metric.current(ble)
        let judged = metric.judge(v)
        let vals = ble.history.compactMap { metric.value(in: $0) }
        Panel(radius: 18, padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardLabel(title: metric.title, glyph: metric == .lambda ? "λ" : nil)
                    Spacer()
                    let status = metric.status(ble)
                    if !status.isEmpty {
                        Text(status)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(judged.0 == .info ? Theme.fg : judged.0.color)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background((judged.0 == .info ? Theme.surface2 : judged.0.color.opacity(0.16)),
                                        in: Capsule())
                    }
                }
                BigValue(value: v, format: metric.format, placeholder: metric.placeholderText(ble),
                         unit: metric.unit, level: judged.0, size: 96, motion: metric.motion,
                         render: metric.render)
                    .frame(maxWidth: .infinity)
                if metric == .lambda {
                    LambdaScale(lambda: ble.shown?.lambda)
                } else if metric == .rpm {
                    RPMBar(rpm: v)
                }
                Rectangle().fill(Theme.line).frame(height: 1).padding(.top, 2)
                HStack {
                    Text("Verlauf 60 s")
                    Spacer()
                    if let lo = vals.min(), let hi = vals.max() {
                        Text("min \(String(format: metric.format, lo))  ·  max \(String(format: metric.format, hi))")
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Theme.muted)
                TrendGraph(samples: ble.history, metric: metric).frame(height: 120)
            }
        }
    }
}

struct MetricTile: View {
    let metric: Metric
    @ObservedObject var ble: BLEManager

    var body: some View {
        let v = metric.current(ble)
        let judged = metric.judge(v)
        VStack(alignment: .leading, spacing: 6) {
            Text(metric.title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundColor(Theme.muted)
                .lineLimit(1)
            BigValue(value: v, format: metric.format, placeholder: metric.placeholderText(ble),
                     unit: metric.unit, level: judged.0, size: 28, motion: metric.motion,
                     render: metric.render)
            if metric == .rpm {
                RPMBar(rpm: v, height: 6)
            } else if metric == .tank {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface2)
                        Capsule()
                            .fill(judged.0.color)
                            .frame(width: geo.size.width * CGFloat(min(100, max(0, v ?? 0)) / 100))
                            .animation(Motion.value, value: v ?? 0)
                    }
                }
                .frame(height: 6)
            } else {
                Text(metric.status(ble).isEmpty ? " " : metric.status(ble))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(12)
        .background(Theme.surface)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}

// ── D: Abstimmung ────────────────────────────────────────────────
struct TuningLayout: View {
    @ObservedObject var ble: BLEManager
    @AppStorage("scatterByLoad") private var byLoad = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        let lam = Metric.lambda.current(ble)
        let lamJudged = Metric.lambda.judge(lam)
        let rpm = ble.tune?.rpm

        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Panel {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            CardLabel(title: "Lambda", glyph: "λ")
                            Spacer()
                            Text(lamJudged.1)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(lamJudged.0.color)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        BigValue(value: lam, format: "%.3f", placeholder: "-.---", level: lamJudged.0, size: 40)
                        LambdaScale(lambda: ble.shown?.lambda, showLabels: false)
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            CardLabel(title: "Drehzahl")
                            Spacer()
                            Text("U/min")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.muted)
                        }
                        BigValue(value: rpm, placeholder: "----", level: Metric.rpm.judge(rpm).0,
                                 size: 40, motion: Motion.slow, render: Metric.rpm.render)
                        RPMBar(rpm: rpm, height: 6).padding(.vertical, 6)
                    }
                }
            }

            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        CardLabel(title: "Lambda · 60 s")
                        Spacer()
                        legendLine(color: Theme.ok, text: "Lambda")
                        legendLine(color: Theme.accent.opacity(0.6), text: "Drehzahl")
                    }
                    TrendGraph(samples: ble.history, metric: .lambda, overlay: .rpm).frame(height: 150)
                }
            }

            Panel {
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
                    ScatterPlot(points: ble.scatter, currentRPM: rpm, currentLambda: lam, byLoad: byLoad)
                        .frame(height: 210)
                    HStack(spacing: 12) {
                        if byLoad {
                            HStack(spacing: 4) {
                                Text("wenig")
                                LinearGradient(colors: [ScatterPlot.loadColor(30), ScatterPlot.loadColor(100)],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 40, height: 6)
                                    .clipShape(Capsule())
                                Text("viel Last")
                            }
                        } else {
                            legendLine(color: Theme.fg, text: "Mittel je 500 U/min")
                        }
                        Spacer()
                        Text("\(ble.scatter.count / 120) min")
                        Button("Leeren") { ble.clearScatter() }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Theme.muted)
                }
            }

            LazyVGrid(columns: columns, spacing: 8) {
                SmallStat(metricTitle: "Öldruck", value: Metric.oilP.current(ble), format: "%.1f",
                          placeholder: Metric.oilP.placeholderText(ble), unit: "bar",
                          level: Metric.oilP.judge(Metric.oilP.current(ble)).0, motion: Motion.value)
                SmallStat(metricTitle: "Öltemp.", value: Metric.oilT.current(ble), format: "%.0f",
                          placeholder: Metric.oilT.placeholderText(ble), unit: "°C",
                          level: Metric.oilT.judge(Metric.oilT.current(ble)).0, motion: Motion.value)
                SmallStat(metricTitle: "Tank", value: ble.shown?.tankValue, format: "%.0f", unit: "%",
                          level: Metric.tank.judge(ble.shown?.tankValue).0, motion: Motion.value)
                SmallStat(metricTitle: "Bordnetz", value: ble.tune?.voltage, unit: "V",
                          level: Metric.voltage.judge(ble.tune?.voltage).0)
                SmallStat(metricTitle: "Zündw.", value: ble.tune?.advance, unit: "°")
                SmallStat(metricTitle: "Saugrohr", value: ble.tune?.mapKPa, format: "%.0f", unit: "kPa")
                SmallStat(metricTitle: "Spule", value: ble.tune?.coilCurrent, unit: "A")
                SmallStat(metricTitle: "Modul", value: ble.tune?.moduleTemp, format: "%.0f", unit: "°C",
                          level: ble.tune?.moduleTemp.map { Limits.moduleTemp($0) } ?? .off)
            }
        }
    }

    private func legendLine(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 12, height: 3)
            Text(text)
        }
        .font(.system(size: 10))
        .foregroundColor(Theme.muted)
    }
}
