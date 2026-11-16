import SwiftUI

// ── Gemisch-Check: Uebersicht und Detailseiten ───────────────────
// Die Uebersicht zeigt je Betriebsbereich eine Zeile mit Ampel. Antippen
// oeffnet die Einzelheiten: Belege, Ursachen, was zu tun ist. Die Regeln
// stehen in MixtureDiagnosis.swift.

struct CheckPanel: View {
    let model: AppModel
    @ObservedObject var tuning: TuningStore
    @ObservedObject var tipIns: TipInAnalyzer
    @ObservedObject var pulls: PullStore
    @ObservedObject var carb: CarbLog

    @State private var sessionID: UUID?

    private var session: TuningSession { tuning.session(sessionID) ?? tuning.current }
    private var isCurrent: Bool { session.id == tuning.current.id }

    private func diagnose(_ s: TuningSession) -> Diagnosis {
        var input = DiagnosisInput(session: s)
        input.targets = LiveContext.targets
        input.jets = carb.setup.jets
        input.idleTargetRPM = LiveContext.idleTargetRPM
        if isCurrent {
            // Gasstoesse und Zuege gehoeren zur laufenden Messreihe, wenn sie seit deren Beginn passiert sind
            input.tipIns = tipIns.events.filter { $0.time >= s.created }.summary
            input.pulls = pulls.pulls.filter { $0.time >= s.created }.summary(target: input.targets.stage2)
        }
        return MixtureDiagnosis.run(input)
    }

    var body: some View {
        let s = session
        let d = diagnose(s)
        VStack(spacing: 12) {
            overview(d, s)
            if !d.plan.isEmpty { planPanel(d) }
            NavigationLink {
                CarbLogView(carb: carb, tuning: tuning)
            } label: {
                Label("Änderung am Vergaser eintragen", systemImage: "wrench.and.screwdriver.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .foregroundColor(Color.black)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            Text("Der Check vergleicht die Messreihe mit deinem Ziel-Lambda je Bereich (Einstellungen › Gemisch). Die Hinweise sind Faustregeln für den Registervergaser. Immer nur eine Sache ändern und neu messen.")
                .font(.system(size: 11))
                .foregroundColor(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { carb.syncFromDefaults() }
    }

    private func overview(_ d: Diagnosis, _ s: TuningSession) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardLabel(title: "Gemisch-Check", symbol: "stethoscope")
                    Spacer()
                    if tuning.saved.isEmpty {
                        Text("Messreihe „Aktuell“")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.muted)
                    } else {
                        Picker("Messreihe", selection: $sessionID) {
                            Text("Aktuell").tag(UUID?.none)
                            ForEach(tuning.saved) { x in
                                Text(x.name).tag(UUID?.some(x.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: d.worst.symbol)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(d.worst.color)
                    Text(d.headline)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(basis(d, s))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(d.findings) { f in
                        Rectangle().fill(Theme.line).frame(height: 1)
                        row(f, s)
                    }
                }
            }
        }
    }

    private func basis(_ d: Diagnosis, _ s: TuningSession) -> String {
        let minutes = String(format: "%.0f min", d.seconds / 60)
        if d.steady { return minutes + " ruhige Fahrt bei warmem Motor ausgewertet" }
        if s.steadyCells == nil && s.lambdaCount > 0 {
            return minutes + " ausgewertet. Ältere Messreihe: Gasstöße und Kaltlauf sind mit drin."
        }
        return minutes + " ausgewertet. Noch wenig ruhige Fahrt, deshalb zählen vorerst alle Werte."
    }

    private func row(_ f: Finding, _ s: TuningSession) -> some View {
        NavigationLink {
            FindingDetailView(finding: f, session: s, model: model)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: f.severity.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(f.severity.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.area.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.fg)
                    Text(subtitle(f))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    if !f.value.isEmpty {
                        Text(f.value)
                            .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(Theme.fg)
                    }
                    Text(f.verdict + (f.preliminary ? " (vorläufig)" : ""))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(f.severity.color)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.muted)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(f.area.title + ", " + f.value + ", " + f.verdict)
    }

    private func subtitle(_ f: Finding) -> String {
        var parts: [String] = []
        if let t = f.target { parts.append(String(format: "Ziel %.2f", t)) }
        if f.seconds > 0 { parts.append(FindingDetailView.timeText(f.seconds)) }
        if parts.isEmpty { return f.area == .tipIn ? "Beschleunigerpumpe" : (f.area.regime?.area ?? "") }
        return parts.joined(separator: " · ")
    }

    private func planPanel(_ d: Diagnosis) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(title: "In dieser Reihenfolge", symbol: "list.number")
                ForEach(Array(d.plan.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1)")
                            .font(.system(size: 12, weight: .heavy).monospacedDigit())
                            .foregroundColor(Color.black)
                            .frame(width: 22, height: 22)
                            .background(Theme.accent, in: Circle())
                        Text(step)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.fg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// ── Einzelheiten zu einem Bereich ────────────────────────────────
struct FindingDetailView: View {
    let finding: Finding
    let session: TuningSession
    let model: AppModel

    static func timeText(_ seconds: Double) -> String {
        seconds < 90 ? String(format: "%.0f s", seconds) : String(format: "%.0f min", seconds / 60)
    }

    var body: some View {
        let f = finding
        ScrollView {
            VStack(spacing: 12) {
                head(f)
                if !f.actions.isEmpty { listPanel("Was du tun kannst", "wrench.and.screwdriver.fill", f.actions, numbered: true) }
                if let j = f.jet { jetPanel(j) }
                toolLink(f)
                if !f.evidence.isEmpty || f.byRPM.count >= 2 { evidencePanel(f) }
                if let h = histogram(f) { histogramPanel(h, f) }
                if !f.causes.isEmpty { listPanel("Mögliche Ursachen", "questionmark.circle.fill", f.causes, numbered: false) }
                Text("Zugeordnet nach Drehzahl und Saugrohrdruck der 123. Die Grenzen zwischen den Vergaserkreisen sind fließend, die Zuordnung ist grob.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle(f.area.title)
        .navigationBarTitleDisplayMode(.inline)
        .navBarStyle()
    }

    private func head(_ f: Finding) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    CardLabel(title: f.area.title, symbol: f.area.symbol)
                    Spacer()
                    Chip(text: f.verdict + (f.preliminary ? " · vorläufig" : ""), color: f.severity.color)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(f.value.isEmpty ? "–" : f.value)
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(f.severity == .none ? Theme.muted : f.severity.color)
                    if let t = f.target {
                        Text(String(format: "Ziel %.2f", t))
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundColor(Theme.muted)
                    }
                }
                if let l = f.lambda, f.target != nil {
                    LambdaScale(lambda: l, target: f.target)
                }
                Text(f.summary)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if let r = f.area.regime {
                    Text("Bereich: " + r.area)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.muted)
                }
            }
        }
    }

    private func listPanel(_ title: String, _ symbol: String, _ items: [String], numbered: Bool) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(title: title, symbol: symbol)
                ForEach(Array(items.enumerated()), id: \.offset) { i, text in
                    HStack(alignment: .top, spacing: 10) {
                        if numbered {
                            Text("\(i + 1)")
                                .font(.system(size: 12, weight: .heavy).monospacedDigit())
                                .foregroundColor(Color.black)
                                .frame(width: 22, height: 22)
                                .background(Theme.accent, in: Circle())
                        } else {
                            Circle().fill(Theme.muted).frame(width: 5, height: 5).padding(.top, 6)
                        }
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.fg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func jetPanel(_ j: JetAdvice) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                CardLabel(title: "Rechnerisch", symbol: "function")
                if let o = j.old, let n = j.new {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(JetAdvice.num(o))
                            .foregroundColor(Theme.muted)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.muted)
                        Text(JetAdvice.num(n.rounded()))
                            .foregroundColor(Theme.accent)
                        Text(j.circuit.jetName)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.muted)
                    }
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                } else {
                    Text(String(format: "%+.0f %% Kraftstoff", j.fuelPercent))
                        .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(Theme.accent)
                    Text("Trag deine Düsen unter Mehr › Bedüsung und Logbuch ein, dann rechnet die App die neue Größe aus.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Faustregel aus dem Düsenquerschnitt. Düsen gibt es meist in 2er- oder 5er-Schritten: die nächste passende nehmen und nachmessen.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func toolLink(_ f: Finding) -> some View {
        switch f.tool {
        case .idleAssistant:
            ToolLink(title: "Leerlauf-Assistent", subtitle: "Gemischschraube Schritt für Schritt einstellen",
                     symbol: "speedometer") {
                IdleAssistantView(ble: model.ble, idle: model.idle)
            }
        case .jetCalc(let c):
            ToolLink(title: "Düsen-Rechner", subtitle: c.jetName + " mit anderem Ziel durchrechnen",
                     symbol: "function") {
                JetCalcView(sessions: [session], preset: c)
            }
        case .tipIns:
            ToolLink(title: "Gasstöße", subtitle: "Jeden einzelnen Gasstoß ansehen", symbol: "waveform.path.ecg") {
                TipInView(analyzer: model.tipIns)
            }
        case .pulls:
            ToolLink(title: "Züge unter Last", subtitle: "Lambda über der Drehzahl bei Vollgas",
                     symbol: "gauge.with.dots.needle.67percent") {
                PullsView(store: model.pulls)
            }
        case .none:
            if f.area == .fullLow || f.area == .fullHigh {
                ToolLink(title: "Züge unter Last", subtitle: "Lambda über der Drehzahl bei Vollgas",
                         symbol: "gauge.with.dots.needle.67percent") {
                    PullsView(store: model.pulls)
                }
            }
        }
    }

    private func evidencePanel(_ f: Finding) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                CardLabel(title: "Was die Daten zeigen", symbol: "chart.bar.fill")
                ForEach(Array(f.evidence.enumerated()), id: \.offset) { _, text in
                    Text(text)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundColor(Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if f.byRPM.count >= 2 {
                    CurvePlot(curves: [Curve(pts: f.byRPM.map { ($0.rpm, $0.lambda) }, color: Theme.fg)],
                              yRange: 0.75...1.25, yGrid: [0.8, 0.9, 1.0, 1.1, 1.2], yFormat: "%.1f",
                              band: f.target.map { ($0 - 0.04)...($0 + 0.04) })
                        .frame(height: 170)
                        .padding(.top, 4)
                    Text("Mittleres Lambda je 500 U/min in diesem Bereich. Grün hinterlegt: das Ziel.")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.muted)
                }
            }
        }
    }

    private func histogram(_ f: Finding) -> [Int]? {
        guard let r = f.area.regime, let h = session.hist?[r.rawValue],
              h.count == TuningSession.histBins, h.reduce(0, +) >= 40 else { return nil }
        return h
    }

    private func histogramPanel(_ bins: [Int], _ f: Finding) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                CardLabel(title: "Verteilung", symbol: "chart.bar.xaxis")
                LambdaHistogram(bins: bins, target: f.target)
                    .frame(height: 120)
                Text("Wie oft welches Lambda vorkam (ruhige Fahrt). Ein schmaler Berg heißt gleichmäßiges Gemisch. Zwei Berge oder ein breiter Fuß: Das Gemisch springt, zum Beispiel zwischen zwei Vergaserkreisen.")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Lambda-Verteilung 0.70 … 1.30 als Balken, das Ziel als Strich
struct LambdaHistogram: View {
    let bins: [Int]
    let target: Double?

    var body: some View {
        Canvas { ctx, size in
            let bottom: CGFloat = 16
            let h = size.height - bottom
            let n = max(1, bins.count)
            let bw = size.width / CGFloat(n)
            let peak = CGFloat(max(1, bins.max() ?? 1))
            let lo = TuningSession.histLow
            let span = TuningSession.histStep * Double(n)
            func x(_ lambda: Double) -> CGFloat { CGFloat((lambda - lo) / span) * size.width }

            if let t = target {
                let band = CGRect(x: x(t - 0.04), y: 0, width: x(t + 0.04) - x(t - 0.04), height: h)
                ctx.fill(Path(band), with: .color(Theme.ok.opacity(0.10)))
            }
            for i in 0..<bins.count where bins[i] > 0 {
                let bh = max(1.5, CGFloat(bins[i]) / peak * (h - 4))
                let center = lo + (Double(i) + 0.5) * TuningSession.histStep
                var col = Theme.fg.opacity(0.75)
                if let t = target {
                    let d = abs(center - t)
                    col = d <= 0.04 ? Theme.ok : (d <= 0.09 ? Theme.warn : Theme.crit)
                }
                let r = CGRect(x: CGFloat(i) * bw + 1, y: h - bh, width: max(1, bw - 2), height: bh)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(col.opacity(0.85)))
            }
            if let t = target {
                var p = Path()
                p.move(to: CGPoint(x: x(t), y: 0))
                p.addLine(to: CGPoint(x: x(t), y: h))
                ctx.stroke(p, with: .color(Theme.fg), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            var base = Path()
            base.move(to: CGPoint(x: 0, y: h))
            base.addLine(to: CGPoint(x: size.width, y: h))
            ctx.stroke(base, with: .color(Theme.line), lineWidth: 1)
            let font = Font.system(size: 10).monospacedDigit()
            for v in [0.8, 0.9, 1.0, 1.1, 1.2] {
                ctx.draw(Text(String(format: "%.1f", v)).font(font).foregroundColor(Theme.muted),
                         at: CGPoint(x: x(v), y: size.height), anchor: .bottom)
            }
        }
        .accessibilityLabel("Verteilung der Lambda-Werte")
    }
}
