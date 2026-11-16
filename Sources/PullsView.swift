import SwiftUI

// ── Zuege unter Last: Liste und Auswertung ───────────────────────
// Erkennung und Rechnung stehen in PullDetector.swift.

struct PullsView: View {
    @ObservedObject var store: PullStore
    @State private var confirmClear = false

    private var target: Double { LiveContext.targets.stage2 }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                summaryCard
                ForEach(store.pulls.prefix(40)) { p in
                    NavigationLink {
                        PullDetailView(pull: p, store: store)
                    } label: {
                        PullRow(pull: p, target: target)
                    }
                    .buttonStyle(.plain)
                }
                infoCard
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle("Züge unter Last")
        .navigationBarTitleDisplayMode(.inline)
        .navBarStyle()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Leeren") { confirmClear = true }
                    .disabled(store.pulls.isEmpty)
            }
        }
        .confirmationDialog("Alle aufgezeichneten Züge löschen?", isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { store.clear() }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private var summaryCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(title: "Vollgas", symbol: "gauge.with.dots.needle.67percent")
                if let s = store.summary(target: target) {
                    HStack(spacing: 8) {
                        Chip(text: "\(s.count) Züge", color: Theme.fg)
                        if s.leanTop > 0 { Chip(text: "\(s.leanTop) mager", color: Theme.crit) }
                        if s.starving > 0 { Chip(text: "\(s.starving) läuft weg", color: Theme.crit) }
                        if s.leanTop == 0 && s.starving == 0 { Chip(text: "keiner mager", color: Theme.ok) }
                        Spacer()
                    }
                    Text(verdict(s))
                        .font(.system(size: 13))
                        .foregroundColor(Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Noch nichts aufgezeichnet. Fahr im dritten Gang ab etwa 2000 U/min mit Vollgas durch, wo es der Verkehr erlaubt. Die App erkennt den Zug von selbst.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func verdict(_ s: PullSummary) -> String {
        if s.starving > 0 {
            return "Bei anhaltendem Vollgas wird Lambda mit der Zeit magerer. Das spricht für die Benzinversorgung: Pumpe, Filter, Schwimmernadelventil, Tankentlüftung."
        }
        if s.leanTop * 2 >= s.count {
            return "Die meisten Züge werden mager. Das passt zu einer zu kleinen Hauptdüse oder einer zu großen Luftkorrekturdüse der zweiten Stufe."
        }
        if s.leanTop > 0 { return "Einzelne Züge werden mager. Antippen zeigt, ab welcher Drehzahl." }
        return String(format: "Unter Vollgas bleibt Lambda im Rahmen (Ziel %.2f).", target)
    }

    private var infoCard: some View {
        Panel {
            Text("Ein Zug zählt, wenn der Saugrohrdruck mindestens 3 s über 80 kPa bleibt und die Drehzahl dabei um mindestens 600 U/min steigt. Bleibt die Drehzahl gleich, zählt es ab 8 s als Dauervollgas. Die Leistung ist eine Schätzung aus Beschleunigung, Fahrzeugmasse und Fahrwiderständen und gilt nur auf ebener Strecke ohne Wind. Zum Vergleichen immer dieselbe Strecke im selben Gang fahren.")
                .font(.system(size: 11))
                .foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum PullLook {
    static func verdict(_ v: PullAnalysis.Verdict) -> (String, Color) {
        switch v {
        case .ok:       return ("passt", Theme.ok)
        case .lean:     return ("mager", Theme.crit)
        case .leanTop:  return ("oben mager", Theme.crit)
        case .rich:     return ("fett", Theme.load)
        case .starving: return ("läuft weg", Theme.crit)
        case .noLambda: return ("ohne Lambda", Theme.muted)
        }
    }
}

struct PullRow: View {
    let pull: Pull
    let target: Double

    var body: some View {
        let a = PullAnalysis(pull, target: target, vehicle: LiveContext.vehicle)
        let look = PullLook.verdict(a.verdict)
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(Format.dayTime(pull.time))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.fg)
                    Spacer()
                    Chip(text: look.0, color: look.1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.muted)
                }
                Text(line(a))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func line(_ a: PullAnalysis) -> String {
        var parts: [String] = []
        if pull.kind == .steady {
            parts.append(String(format: "Dauervollgas %.0f s bei %.0f U/min", a.duration, (a.rpmFrom + a.rpmTo) / 2))
        } else {
            parts.append(String(format: "%.0f → %.0f U/min in %.1f s", a.rpmFrom, a.rpmTo, a.duration))
        }
        if let l = a.lambdaMean { parts.append(String(format: "λ %.2f", l)) }
        if let p = a.peak { parts.append(String(format: "≈ %.0f kW", p.kW)) }
        return parts.joined(separator: " · ")
    }
}

struct PullDetailView: View {
    let pull: Pull
    @ObservedObject var store: PullStore
    @Environment(\.dismiss) private var dismiss

    private var target: Double { LiveContext.targets.stage2 }

    var body: some View {
        let a = PullAnalysis(pull, target: target, vehicle: LiveContext.vehicle)
        let look = PullLook.verdict(a.verdict)
        ScrollView {
            VStack(spacing: 12) {
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            CardLabel(title: pull.kind == .steady ? "Dauervollgas" : "Zug", symbol: "gauge.with.dots.needle.67percent")
                            Spacer()
                            Chip(text: look.0, color: look.1)
                        }
                        Text(explain(a))
                            .font(.system(size: 14))
                            .foregroundColor(Theme.fg)
                            .fixedSize(horizontal: false, vertical: true)
                        statGrid(a)
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        CardLabel(title: pull.kind == .steady ? "Lambda über der Zeit" : "Lambda über der Drehzahl")
                        PullLambdaPlot(pull: pull, target: target)
                            .frame(height: 200)
                        Text(pull.kind == .steady
                             ? "Steigt die Linie über die Dauer an, kommt nicht genug Sprit nach."
                             : "Grün hinterlegt das Ziel. Die Sonde hängt dem Motor etwa eine Viertelsekunde hinterher, bei schnellen Zügen verschiebt das die Kurve leicht nach rechts.")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if a.power.count >= 3 {
                    Panel {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                CardLabel(title: "Leistung am Rad, geschätzt", symbol: "bolt.fill")
                                Spacer()
                                if let p = a.peak {
                                    Text(String(format: "≈ %.0f kW (%.0f PS) bei %.0f", p.kW, p.kW * 1.36, p.rpm))
                                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                                        .foregroundColor(Theme.fg)
                                }
                            }
                            CurvePlot(curves: [Curve(pts: a.power.map { ($0.rpm, $0.kW) }, color: Theme.accent)],
                                      yRange: 0...30, yGrid: [10, 20, 30], yFormat: "%.0f")
                                .frame(height: 170)
                            Text(String(format: "Aus Beschleunigung, %.0f kg und Fahrwiderständen gerechnet. Stimmt nur auf ebener Strecke ohne Wind. Gut zum Vergleichen vorher und nachher, nicht als absoluter Wert. Die Masse stellst du in den Einstellungen ein.", LiveContext.vehicle.mass))
                                .font(.system(size: 10))
                                .foregroundColor(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Button {
                    store.delete(pull)
                    dismiss()
                } label: {
                    Label("Diesen Zug löschen", systemImage: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundColor(Theme.crit)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle(Format.dayTime(pull.time))
        .navigationBarTitleDisplayMode(.inline)
        .navBarStyle()
    }

    private func explain(_ a: PullAnalysis) -> String {
        switch a.verdict {
        case .ok:
            return String(format: "Lambda bleibt unter Last im Rahmen (Ziel %.2f).", target)
        case .lean:
            return "Schon von unten weg zu mager. Hauptdüse der zweiten Stufe zu klein, oder es fehlt Sprit."
        case .leanTop:
            return String(format: "Ab etwa %.0f U/min wird es mager. Unten passt es: Das spricht für die Luftkorrekturdüse der zweiten Stufe (kleiner) oder für knappe Benzinversorgung.", a.leanFrom ?? 0)
        case .rich:
            return "Fetter als nötig. Das kostet etwas Leistung, schadet aber nicht."
        case .starving:
            return String(format: "Lambda steigt um %.2f je 10 s. Bei gleichbleibender Last heißt das: Die Schwimmerkammer läuft leer. Pumpe, Filter, Nadelventil und Tankentlüftung prüfen.", a.drift ?? 0)
        case .noLambda:
            return "Für diesen Zug gibt es keine Lambda-Werte."
        }
    }

    private func statGrid(_ a: PullAnalysis) -> some View {
        var items: [(String, String)] = [
            ("Dauer", String(format: "%.1f s", a.duration)),
            ("Drehzahl", String(format: "%.0f–%.0f", a.rpmFrom, a.rpmTo))
        ]
        if let m = a.mapMean { items.append(("Saugrohr", String(format: "%.0f kPa", m))) }
        if let lo = a.lambdaMin, let hi = a.lambdaMax { items.append(("Lambda", String(format: "%.2f–%.2f", lo, hi))) }
        if pull.kind == .pull {
            items.append(("Hochdrehen", String(format: "%.0f U/min je s", a.rate)))
            if let t = PullAnalysis.time(pull, from: 3000, to: 4000) {
                items.append(("3000 → 4000", String(format: "%.1f s", t)))
            }
        }
        if let r = a.ratio { items.append(("Gang", String(format: "%.1f km/h je 1000", r))) }
        if let d = a.drift { items.append(("Drift", String(format: "%+.2f je 10 s", d))) }
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.0.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.muted)
                    Text(item.1)
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(Theme.fg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

/// Lambda eines Zugs: ueber der Drehzahl, bei Dauervollgas ueber der Zeit
struct PullLambdaPlot: View {
    let pull: Pull
    let target: Double

    var body: some View {
        Canvas { ctx, size in
            draw(ctx, size)
        }
        .accessibilityLabel("Lambda-Verlauf des Zugs")
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let left: CGFloat = 34, right: CGFloat = 8, top: CGFloat = 6, bottom: CGFloat = 18
        let w = size.width - left - right
        let h = size.height - top - bottom
        let lo = 0.75, hi = 1.25
        let overTime = pull.kind == .steady
        let s = pull.samples
        let xMin: Double = overTime ? 0 : 1000
        let xMax: Double = overTime ? max(10, Double(s.last?.t ?? 10)) : 6000
        func x(_ v: Double) -> CGFloat { left + CGFloat((min(xMax, max(xMin, v)) - xMin) / (xMax - xMin)) * w }
        func y(_ v: Double) -> CGFloat { top + CGFloat((hi - min(hi, max(lo, v))) / (hi - lo)) * h }

        ctx.fill(Path(CGRect(x: left, y: y(target + 0.04), width: w, height: y(target - 0.04) - y(target + 0.04))),
                 with: .color(Theme.ok.opacity(0.10)))
        let font = Font.system(size: 10)
        for g in [0.8, 0.9, 1.0, 1.1, 1.2] {
            var p = Path()
            p.move(to: CGPoint(x: left, y: y(g)))
            p.addLine(to: CGPoint(x: left + w, y: y(g)))
            ctx.stroke(p, with: .color(abs(g - 1) < 0.001 ? Theme.muted : Theme.line),
                       style: StrokeStyle(lineWidth: 1, dash: abs(g - 1) < 0.001 ? [4, 4] : []))
            ctx.draw(Text(String(format: "%.1f", g)).font(font).foregroundColor(Theme.muted),
                     at: CGPoint(x: left - 6, y: y(g)), anchor: .trailing)
        }
        let ticks: [Double] = overTime ? [0, xMax / 2, xMax] : [2000, 4000, 6000]
        for t in ticks {
            let label = overTime ? String(format: "%.0f s", t) : String(format: "%.0f", t)
            ctx.draw(Text(label).font(font).foregroundColor(Theme.muted),
                     at: CGPoint(x: x(t), y: size.height), anchor: t >= xMax ? .bottomTrailing : .bottom)
        }

        // Linie, jedes Stueck nach Abstand zum Ziel gefaerbt
        var prev: (CGPoint, Double)?
        for i in s.indices {
            guard let l = s[i].lambda else { prev = nil; continue }
            // Lambda dem Punkt davor zuordnen (Laufzeit bis zur Sonde)
            let ref = s[max(0, i - 1)]
            let pt = CGPoint(x: x(overTime ? Double(s[i].t) : Double(ref.rpm)), y: y(Double(l)))
            if let p = prev {
                var seg = Path()
                seg.move(to: p.0)
                seg.addLine(to: pt)
                let d = Double(l) - target
                let col = d >= 0.09 || Double(l) >= 1.0 ? Theme.crit : (abs(d) <= 0.04 ? Theme.ok : Theme.warn)
                ctx.stroke(seg, with: .color(col), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }
            prev = (pt, Double(l))
        }
    }
}
