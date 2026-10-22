import SwiftUI
import Charts

// ── Zuendkurven der 123: so programmiert, wie die 123-App sie zeigt ──
// Gelesen mit den Lesebefehlen der 123-App (siehe Tune123.swift). Die
// Messpunkte kommen aus der Messreihe "Aktuell" und zeigen, ob die 123
// wirklich so faehrt.

extension Tune123Program {
    static let chartMaxRPM = 6000.0
    static let chartMaxKPa = 100.0

    /// Punkte bis `limit`, am Rand auf `limit` interpoliert
    static func clipped(_ pts: [Tune123Point], to limit: Double) -> [Tune123Point] {
        var out = pts.filter { $0.x <= limit }
        if let last = pts.last, last.x > limit, let v = interpolate(pts, limit) {
            out.append(Tune123Point(x: limit, deg: v))
        }
        return out
    }

    /// Fuer CurvePlot im Tab "Zuendung"
    var advanceLine: [(Double, Double)] {
        Self.clipped(advance, to: Self.chartMaxRPM).map { ($0.x, $0.deg) }
    }

    var vacuumOff: Bool { !vacuum.isEmpty && vacuum.allSatisfy { $0.deg == 0 } }
}

private struct MeasuredPoint: Identifiable {
    let id: Int
    let x: Double
    let deg: Double
}

struct Tune123ProgramView: View {
    @ObservedObject var ble: BLEManager
    let session: TuningSession
    @AppStorage(BLEManager.autoReadKey) private var autoRead = true

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                readPanel
                if let p = ble.tuneProgram {
                    livePanel(p)
                    advancePanel(p)
                    if !p.vacuum.isEmpty { vacuumPanel(p) }
                    settingsPanel(p)
                }
                Text("Die App liest nur, mit denselben Befehlen wie die 123-App beim Verbinden. Kurven, Begrenzer und Wegfahrsperre bleiben unverändert; programmiert wird weiter mit der 123-App. Im selben Datenblock wie der Begrenzer schickt die 123 auch ihren Pincode. Die App verwirft ihn sofort, zeigt und speichert ihn nicht.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle("Zündkurven der 123")
        .navigationBarTitleDisplayMode(.inline)
        .navBarStyle()
    }

    // ── Lesen ──
    private var readPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(title: "Programmierung", symbol: "memorychip")
                statusLine
                Button {
                    ble.readTuneProgram()
                } label: {
                    Label(ble.tuneProgram == nil ? "Von der 123 lesen" : "Neu lesen",
                          systemImage: "arrow.down.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .foregroundColor(ble.canReadProgram ? Color.black : Theme.muted)
                        .background(ble.canReadProgram ? Theme.accent : Theme.surface2,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!ble.canReadProgram)
                if let hint = readHint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                }
                Toggle("Beim Verbinden automatisch lesen", isOn: $autoRead)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.fg)
                    .tint(Theme.accent)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch ble.programRead {
        case .reading(let step):
            HStack(spacing: 8) {
                ProgressView().tint(Theme.accent)
                Text(step < Tune123.readBlocks.count ? "Lese Block \(step + 1) von 4 …" : "Lese Version …")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.fg)
            }
        case .failed:
            Text("Keine Antwort von der 123. Motor aus, Zündung an und nochmal lesen. Antwortet sie nie, kennt dieses Modell die Lesebefehle wohl nicht.")
                .font(.system(size: 13))
                .foregroundColor(Theme.warn)
        default:
            if let p = ble.tuneProgram {
                Text("Gelesen " + Format.dayTime(p.readAt) + (p.isDemo ? " · Demo" : "")
                     + (p.complete ? "" : " · unvollständig"))
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundColor(Theme.fg)
            } else {
                Text("Noch nicht gelesen.")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.fg)
            }
        }
    }

    private var readHint: String? {
        if ble.programReading { return nil }
        if ble.tuneState != .live && ble.tuneState != .demo { return "123 nicht verbunden." }
        if ble.tuneState == .live && ble.engineRunning { return "Nur bei stehendem Motor, wie in der 123-App." }
        return nil
    }

    // ── Soll und Ist jetzt ──
    @ViewBuilder
    private func livePanel(_ p: Tune123Program) -> some View {
        if let t = ble.tune, let rpm = t.rpm, rpm >= 500, let ist = t.advance {
            let soll = p.expected(rpm: rpm, kPa: t.mapKPa)
            let cf = p.centrifugal(rpm: rpm)
            let vac = t.mapKPa.flatMap { p.vacuumShare(rpm: rpm, kPa: $0) }
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    CardLabel(title: "Jetzt", symbol: "bolt.fill")
                    Text(String(format: "%.0f U/min", rpm) + (t.mapKPa.map { String(format: " · %.0f kPa", $0) } ?? ""))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundColor(Theme.muted)
                    row("Soll aus den Kurven", soll.map { String(format: "%.1f°", $0) } ?? "–")
                    if let cf {
                        row("  davon Fliehkraft", String(format: "%.1f°", cf))
                    }
                    if let vac {
                        row("  davon Unterdruck", String(format: "%.1f°", vac))
                    }
                    row("Ist (von der 123)", String(format: "%.1f°", ist), bold: true)
                    if t.tuningMode == true {
                        note("Tuning-Modus aktiv: Die 123 verschiebt den Zündwinkel gerade von Hand.")
                    } else if let s = soll, abs(ist - s) > 1.5 {
                        note("Weicht um " + String(format: "%.1f°", ist - s) + " ab. Entweder rechnet die 123 anders als hier angenommen, oder die Programmierung hat sich geändert (neu lesen).")
                    }
                }
            }
        }
    }

    // ── Fliehkraftkurve ──
    private func advancePanel(_ p: Tune123Program) -> some View {
        let line = Tune123Program.clipped(p.advance, to: Tune123Program.chartMaxRPM)
        let shown = p.advance.filter { $0.x <= Tune123Program.chartMaxRPM }
        // Messpunkte ohne Unterdruckanteil liegen direkt auf der Fliehkraftkurve
        let measured: [MeasuredPoint] = session.advancePoints.suffix(600).enumerated().compactMap { item -> MeasuredPoint? in
            let (i, pt) = item
            let r = Double(pt.r)
            guard r <= Tune123Program.chartMaxRPM else { return nil }
            if !p.vacuum.isEmpty {
                guard let m = pt.m, let v = p.vacuumShare(rpm: r, kPa: Double(m)), v < 0.3 else { return nil }
            }
            return MeasuredPoint(id: i, x: r, deg: Double(pt.v))
        }
        return Panel {
            VStack(alignment: .leading, spacing: 8) {
                CardLabel(title: "Fliehkraftkurve", symbol: "gauge.with.dots.needle.67percent")
                Chart {
                    ForEach(measured) { m in
                        PointMark(x: .value("U/min", m.x), y: .value("Grad", m.deg))
                            .symbolSize(12)
                            .foregroundStyle(Theme.muted.opacity(0.55))
                    }
                    ForEach(Array(line.enumerated()), id: \.offset) { _, pt in
                        LineMark(x: .value("U/min", pt.x), y: .value("Grad", pt.deg),
                                 series: .value("Kurve", "Programm"))
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, pt in
                        PointMark(x: .value("U/min", pt.x), y: .value("Grad", pt.deg))
                            .symbolSize(36)
                            .foregroundStyle(Theme.accent)
                    }
                    if let lim = p.rpmLimit, lim <= Tune123Program.chartMaxRPM {
                        RuleMark(x: .value("Begrenzer", lim))
                            .foregroundStyle(Theme.crit.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("Begrenzer")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(Theme.crit)
                            }
                    }
                }
                .chartXScale(domain: 0...Tune123Program.chartMaxRPM)
                .chartYScale(domain: 0...max(40, (p.advance.map(\.deg).max() ?? 0) + 5))
                .chartXAxisLabel("U/min")
                .chartYAxisLabel("° vor OT")
                .frame(height: 220)
                legend(measured: measured.isEmpty ? nil : "gemessen, ohne Unterdruckanteil")
                pointTable(p.advance, xTitle: "U/min", xFormat: "%.0f")
            }
        }
    }

    // ── Unterdruckkurve ──
    private func vacuumPanel(_ p: Tune123Program) -> some View {
        let line = Tune123Program.clipped(p.vacuum, to: Tune123Program.chartMaxKPa)
        let shown = p.vacuum.filter { $0.x <= Tune123Program.chartMaxKPa }
        // gemessener Unterdruckanteil = Ist minus Fliehkraft
        let measured: [MeasuredPoint] = session.advancePoints.suffix(600).enumerated().compactMap { item -> MeasuredPoint? in
            let (i, pt) = item
            let r = Double(pt.r)
            guard let m = pt.m, Double(m) <= Tune123Program.chartMaxKPa,
                  r >= (p.vacuumStartRPM ?? 0), let cf = p.centrifugal(rpm: r) else { return nil }
            return MeasuredPoint(id: i, x: Double(m), deg: Double(pt.v) - cf)
        }
        let maxDeg = max(15, (p.vacuum.map(\.deg).max() ?? 0) + 4)
        return Panel {
            VStack(alignment: .leading, spacing: 8) {
                CardLabel(title: "Unterdruckkurve", symbol: "wind")
                if p.vacuumOff {
                    Text("Alle Punkte 0°: Die Unterdruckverstellung ist praktisch aus.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.fg)
                }
                Chart {
                    ForEach(measured) { m in
                        PointMark(x: .value("kPa", m.x), y: .value("Grad", m.deg))
                            .symbolSize(12)
                            .foregroundStyle(Theme.muted.opacity(0.55))
                    }
                    ForEach(Array(line.enumerated()), id: \.offset) { _, pt in
                        LineMark(x: .value("kPa", pt.x), y: .value("Grad", pt.deg),
                                 series: .value("Kurve", "Programm"))
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, pt in
                        PointMark(x: .value("kPa", pt.x), y: .value("Grad", pt.deg))
                            .symbolSize(36)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .chartXScale(domain: 0...Tune123Program.chartMaxKPa)
                .chartYScale(domain: -5...maxDeg)
                .chartXAxisLabel("Saugrohrdruck kPa (100 = Vollgas)")
                .chartYAxisLabel("° zusätzlich")
                .frame(height: 200)
                legend(measured: measured.isEmpty ? nil : "gemessen: Ist minus Fliehkraft")
                if let s = p.vacuumStartRPM {
                    Text("Wirkt erst ab " + String(format: "%.0f", s) + " U/min. Wenig kPa heißt viel Unterdruck (Teillast, Schiebebetrieb).")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                }
                pointTable(p.vacuum, xTitle: "kPa", xFormat: "%.0f")
            }
        }
    }

    // ── Einstellungen ──
    private func settingsPanel(_ p: Tune123Program) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                CardLabel(title: "Einstellungen", symbol: "slider.horizontal.3")
                row("Unterdruck ab", p.vacuumOff ? "aus" : p.vacuumStartRPM.map { String(format: "%.0f U/min", $0) } ?? "–")
                row("Drehzahlbegrenzer", p.rpmLimit.map { String(format: "%.0f U/min", $0) } ?? "–")
                row("Wegfahrsperre", p.immobilizer.map { $0 ? "an" : "aus" } ?? "unbekannt")
                row("Firmware", p.version ?? "–")
                row("Kurvenpunkte", "\(p.advance.count) Fliehkraft · \(p.vacuum.count) Unterdruck")
            }
        }
    }

    // ── Bausteine ──
    private func row(_ title: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(Theme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: bold ? .bold : .semibold).monospacedDigit())
                .foregroundColor(Theme.fg)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Theme.warn)
            .padding(.top, 2)
    }

    private func legend(measured: String?) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 12, height: 3)
                Text("programmiert")
            }
            if let measured {
                HStack(spacing: 4) {
                    Circle().fill(Theme.muted.opacity(0.7)).frame(width: 5, height: 5)
                    Text(measured)
                }
            }
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundColor(Theme.muted)
    }

    private func pointTable(_ pts: [Tune123Point], xTitle: String, xFormat: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Punkt").frame(width: 44, alignment: .leading)
                Text(xTitle).frame(maxWidth: .infinity, alignment: .trailing)
                Text("Grad").frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Theme.muted)
            .padding(.vertical, 4)
            ForEach(Array(pts.enumerated()), id: \.offset) { i, pt in
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack {
                    Text("\(i + 1)").frame(width: 44, alignment: .leading)
                        .foregroundColor(Theme.muted)
                    Text(String(format: xFormat, pt.x)).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(String(format: "%.1f°", pt.deg)).frame(width: 70, alignment: .trailing)
                }
                .font(.system(size: 13).monospacedDigit())
                .foregroundColor(Theme.fg)
                .padding(.vertical, 5)
            }
        }
        .padding(.top, 4)
    }
}
