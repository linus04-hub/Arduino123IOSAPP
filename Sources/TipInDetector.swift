import Foundation

// ── Gasstoss-Erkennung ───────────────────────────────────────────
// Mit dem Saugrohrdruck der 123: Der Druck springt aus ruhiger Fahrt in
// kurzer Zeit um mindestens 15 kPa nach oben und bleibt oben. So wird
// jeder Gasstoss erfasst, auch die sauberen. Ohne Saugrohrdruck gilt die
// alte Regel: Lambda schlaegt nach ruhiger Fahrt schnell um 0,05 aus und
// die Drehzahl steigt danach. Ausgewertet wird der 4-Hz-Verlauf; sehr
// kurze Spitzen koennen fehlen.

struct TipInEvent: Codable, Identifiable, Hashable {
    var id = UUID()
    var time: Date
    var baseLambda: Double       // Mittel vor dem Gasstoss
    var peakLambda: Double       // magerster Wert danach
    var minLambda: Double        // fettester Wert danach
    var leanSeconds: Double      // Zeit ueber Basis + 0,03
    var rpmBefore: Double
    var rpmAfter: Double
    var trace: [Float]           // Lambda alle 0,25 s, ab 1 s vor dem Ausschlag
    // ab Version 2.0
    var mapBefore: Double?       // Saugrohrdruck vor und nach dem Gasgeben
    var mapAfter: Double?

    var leanSpike: Double { peakLambda - baseLambda }
    var richDip: Double { baseLambda - minLambda }

    enum Verdict { case lean, rich, ok }

    /// Mager: Loch von mindestens 0,08. Fett: deutlich unter das, was Vollgas braucht.
    /// Dass es nach dem Gasgeben fetter wird als in der Teillast, ist gewollt.
    var verdict: Verdict {
        if leanSpike >= 0.08 { return .lean }
        if minLambda < 0.80 && richDip >= 0.12 { return .rich }
        return .ok
    }
}

extension Array where Element == TipInEvent {
    var summary: TipInSummary? {
        guard !isEmpty else { return nil }
        var s = TipInSummary(count: count)
        var spikes = 0.0
        for e in self {
            spikes += e.leanSpike
            switch e.verdict {
            case .lean: s.lean += 1
            case .rich: s.rich += 1
            case .ok:   s.ok += 1
            }
        }
        s.avgLeanSpike = spikes / Double(count)
        return s
    }
}

struct TipInDetector {
    static let triggerDelta = 0.05      // Lambda-Ausschlag (ohne Saugrohrdruck)
    static let minRPMRise = 120.0
    static let mapJump = 15.0           // kPa in hoechstens 1,5 s
    static let mapHold = 10.0           // so viel muss danach mindestens bleiben
    static let observe = 3.0            // Sekunden nach dem Ausloesen
    static let step = 0.25

    private var buffer: [Sample] = []
    private var triggerAt: Date?
    private var base = 0.0
    private var rpmBefore = 0.0
    private var mapBefore: Double?
    private var cooldownUntil = Date.distantPast

    /// Alle 0,25 s. Gibt einen fertigen Gasstoss zurueck, sobald er ausgewertet ist.
    mutating func add(_ s: Sample) -> TipInEvent? {
        buffer.append(s)
        let cut = s.time.addingTimeInterval(-8)
        if let i = buffer.firstIndex(where: { $0.time >= cut }), i > 0 {
            buffer.removeFirst(i)
        }

        if let t = triggerAt {
            guard s.time.timeIntervalSince(t) >= Self.observe else { return nil }
            triggerAt = nil
            cooldownUntil = s.time.addingTimeInterval(2)
            return finish(at: t)
        }

        guard s.time >= cooldownUntil, let l = s.lambda, let rpm = s.rpm, rpm >= 900 else { return nil }
        let from = s.time.addingTimeInterval(-2.0)
        let to = s.time.addingTimeInterval(-0.5)
        guard let b = SampleWindow.stat(buffer, from: from, to: to, { $0.lambda }), b.count >= 5,
              let r = SampleWindow.stat(buffer, from: from, to: to, { $0.rpm }) else { return nil }

        if let m = s.mapKPa, let mb = SampleWindow.stat(buffer, from: from, to: to, { $0.mapKPa }) {
            // mit Saugrohrdruck: Sprung aus ruhiger Fahrt
            guard b.spread < 0.03, mb.spread < 4, mb.mean <= 78, m - mb.mean >= Self.mapJump else { return nil }
            mapBefore = mb.mean
        } else {
            guard b.spread < 0.02, abs(l - b.mean) >= Self.triggerDelta else { return nil }
            mapBefore = nil
        }
        triggerAt = s.time
        base = b.mean
        rpmBefore = r.mean
        return nil
    }

    private func finish(at t: Date) -> TipInEvent? {
        let end = t.addingTimeInterval(Self.observe)
        let after = buffer.filter { $0.time >= t && $0.time <= end }
        let rpms = after.filter { $0.time >= t.addingTimeInterval(0.75) }.compactMap { $0.rpm }
        guard let rpmAfter = rpms.max() else { return nil }

        var mapAfter: Double?
        if let mb = mapBefore {
            // das Gas muss offen bleiben, sonst war es nur ein Zucken
            let held = after.filter { $0.time >= t.addingTimeInterval(0.25) && $0.time <= t.addingTimeInterval(1.5) }
                .compactMap { $0.mapKPa }
            guard !held.isEmpty else { return nil }
            let mean = held.reduce(0, +) / Double(held.count)
            guard mean - mb >= Self.mapHold, rpmAfter >= rpmBefore - 150 else { return nil }
            mapAfter = mean
        } else {
            // ohne Saugrohrdruck: nur echte Gasstoesse, die Drehzahl muss danach steigen
            guard rpmAfter - rpmBefore >= Self.minRPMRise else { return nil }
        }

        let lams = after.compactMap { $0.lambda }
        guard let peak = lams.max(), let low = lams.min() else { return nil }
        var leanCount = 0
        for x in after {
            if let v = x.lambda, v > base + 0.03 { leanCount += 1 }
        }
        let b = base
        let trace: [Float] = buffer
            .filter { $0.time >= t.addingTimeInterval(-1) && $0.time <= end }
            .map { Float($0.lambda ?? b) }

        return TipInEvent(time: t, baseLambda: b, peakLambda: max(peak, b), minLambda: min(low, b),
                          leanSeconds: Double(leanCount) * Self.step,
                          rpmBefore: rpmBefore, rpmAfter: rpmAfter, trace: trace,
                          mapBefore: mapBefore, mapAfter: mapAfter)
    }
}
