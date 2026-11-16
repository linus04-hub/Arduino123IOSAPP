import Foundation
import SwiftUI
import UIKit
import AudioToolbox

// ── Ablagen: Warnungen, Zuege unter Last, Beduesung/Logbuch, Tankbuch ──
// Die Rechenlogik steht in AlertMonitor.swift, PullDetector.swift und
// CarbSetup.swift. Hier wird nur gespeichert und an die Oberflaeche gemeldet.

enum Storage {
    /// Dateien, die man in der Dateien-App sehen soll
    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    /// Interne Dateien
    static let support: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .deferredToDate
        return try? dec.decode(type, from: d)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let d = try? JSONEncoder().encode(value) else { return }
        try? d.write(to: url, options: .atomic)
    }
}

// ── Warnungen ────────────────────────────────────────────────────
final class AlertCenter: ObservableObject {
    @Published private(set) var top: ActiveAlert?

    private var monitor = AlertMonitor()

    /// Gibt neu ausgeloeste Warnungen zurueck
    func update(_ s: Sample) -> [ActiveAlert] {
        let raised = monitor.update(s, settings: LiveContext.alerts)
        let t = monitor.top
        if t != top {
            withAnimation(.easeInOut(duration: 0.25)) { top = t }
        }
        return raised
    }

    func reset() {
        monitor.reset()
        if top != nil { top = nil }
    }

    /// Vibration und, wenn gewuenscht, ein Ton
    func notify(_ a: ActiveAlert) {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(a.kind.severity == .crit ? .error : .warning)
        if LiveContext.alerts.sound {
            AudioServicesPlayAlertSound(SystemSoundID(a.kind.severity == .crit ? 1005 : 1057))
        }
    }
}

// ── Zuege unter Last ─────────────────────────────────────────────
final class PullStore: ObservableObject {
    @Published private(set) var pulls: [Pull] = []       // neueste zuerst

    static let maxPulls = 80

    private var detector = PullDetector()
    private static var url: URL { Storage.support.appendingPathComponent("Zuege.json") }

    init() {
        pulls = Storage.read([Pull].self, from: Self.url) ?? []
    }

    /// Alle 0,25 s aus dem AppModel
    func add(_ s: Sample) {
        guard let p = detector.add(s) else { return }
        pulls.insert(p, at: 0)
        if pulls.count > Self.maxPulls { pulls.removeLast(pulls.count - Self.maxPulls) }
        Storage.write(pulls, to: Self.url)
    }

    func delete(_ p: Pull) {
        pulls.removeAll { $0.id == p.id }
        Storage.write(pulls, to: Self.url)
    }

    func clear() {
        pulls = []
        Storage.write(pulls, to: Self.url)
    }

    func summary(target: Double) -> PullSummary? { pulls.summary(target: target) }
}

// ── Beduesung und Logbuch ────────────────────────────────────────
final class CarbLog: ObservableObject {
    @Published private(set) var book: CarbBook

    private static var url: URL { Storage.documents.appendingPathComponent("Vergaser.json") }

    init() {
        if let b = Storage.read(CarbBook.self, from: Self.url) {
            book = b
        } else {
            // Duesen aus dem Duesen-Rechner frueherer Versionen uebernehmen
            book = CarbBook(setup: CarbSetup.fromDefaults())
        }
        mirrorToDefaults()
    }

    var setup: CarbSetup { book.setup }

    /// Aenderung eintragen; nil, wenn sich nichts geaendert hat und keine Notiz dabei ist
    @discardableResult
    func commit(_ new: CarbSetup, note: String, session: TuningSession?) -> LogEntry? {
        let e = book.commit(new, note: note, session: session.map { ($0.id, $0.name) })
        if e != nil { save() }
        return e
    }

    /// Der Duesen-Rechner aendert eine einzelne Duese, ohne Logbuch-Eintrag
    func setJet(_ c: CarbCircuit, _ value: Double) {
        guard let f = CarbSetup.Field.allCases.first(where: { $0.circuit == c }) else { return }
        let v: Double? = value > 0 ? value : nil
        guard book.setup[f] != v else { return }
        book.setup[f] = v
        save()
    }

    func delete(_ e: LogEntry) {
        book.entries.removeAll { $0.id == e.id }
        save()
    }

    /// Der Duesen-Rechner legt Duesen direkt in den Einstellungen ab. Hier uebernehmen,
    /// damit Gemisch-Check und Logbuch denselben Stand haben.
    func syncFromDefaults() {
        let d = UserDefaults.standard
        var changed = false
        for f in CarbSetup.Field.allCases {
            guard let c = f.circuit else { continue }
            let v = d.double(forKey: "jet." + c.rawValue)
            let new: Double? = v > 0 ? v : nil
            if book.setup[f] != new {
                book.setup[f] = new
                changed = true
            }
        }
        if changed { Storage.write(book, to: Self.url) }
    }

    private func save() {
        Storage.write(book, to: Self.url)
        mirrorToDefaults()
    }

    /// Der Duesen-Rechner liest "jet.<Kreis>" aus den Einstellungen
    private func mirrorToDefaults() {
        let d = UserDefaults.standard
        for c in CarbCircuit.allCases {
            let v = book.setup.jet(c) ?? 0
            if d.double(forKey: "jet." + c.rawValue) != v { d.set(v, forKey: "jet." + c.rawValue) }
        }
    }
}

// ── Tankbuch ─────────────────────────────────────────────────────
final class FuelStore: ObservableObject {
    @Published private(set) var entries: [FuelEntry] = []     // neueste zuerst

    private static var url: URL { Storage.documents.appendingPathComponent("Tankbuch.json") }

    init() {
        entries = (Storage.read([FuelEntry].self, from: Self.url) ?? []).sorted { $0.date > $1.date }
    }

    func add(_ e: FuelEntry) {
        entries.append(e)
        entries.sort { $0.date > $1.date }
        Storage.write(entries, to: Self.url)
    }

    func delete(_ e: FuelEntry) {
        entries.removeAll { $0.id == e.id }
        Storage.write(entries, to: Self.url)
    }

    /// Verbrauch je Volltanken; die Strecke ohne Kilometerstand kommt aus den Fahrten
    func results(trips: [TripSummary]) -> [UUID: FuelResult] {
        FuelMath.results(entries) { from, to in
            trips.reduce(0) { $0 + ($1.start >= from && $1.start < to ? $1.distanceKm : 0) }
        }
    }
}
