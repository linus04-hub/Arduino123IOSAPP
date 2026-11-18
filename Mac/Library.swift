import Foundation
import SwiftUI
import AppKit

// ── Datenbibliothek ──────────────────────────────────────────────
// Sammelt Fahrten, Messreihen, Logbuch, Tankbuch, Zuege und Gasstoesse aus
//   ~/Library/Application Support/CitroenAnzeige/iPhone      (vom iPhone geholt)
//   ~/Library/Application Support/CitroenAnzeige/Importiert  (hineingezogen)
//   und weiteren Ordnern aus den Einstellungen.
// Die Ordnerstruktur ist egal: gesucht wird nach "Fahrten", "Messreihen" und
// den bekannten Dateinamen, so wie sie die iPhone-App anlegt.

enum DataPaths {
    static let base: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CitroenAnzeige", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var phone: URL { base.appendingPathComponent("iPhone", isDirectory: true) }
    static var imported: URL { base.appendingPathComponent("Importiert", isDirectory: true) }
    static var cache: URL { base.appendingPathComponent("Cache", isDirectory: true) }
    static var syncScript: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".citroen-auto/sync-data.sh")
    }
    static var syncStamp: URL { base.appendingPathComponent("letzter-abgleich.txt") }

    static let extraKey = "mac.folders"

    static var extra: [URL] {
        (UserDefaults.standard.stringArray(forKey: extraKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

struct TripRef: Identifiable, Hashable {
    var summary: TripSummary
    var csv: URL?
    var source: String
    var id: String { summary.id }
}

enum SyncState: Equatable {
    case idle
    case running
    case done(String)
    case failed(String)
}

struct ScanResult {
    var trips: [TripRef] = []
    var sessions: [TuningSession] = []
    var book: CarbBook?
    var bookDate = Date.distantPast
    var fuel: [FuelEntry] = []
    var pulls: [Pull] = []
    var tipIns: [TipInEvent] = []
}

private struct CachedStats: Codable {
    var sig: String
    var stats: TripStats
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var trips: [TripRef] = []           // neueste zuerst
    @Published private(set) var sessions: [TuningSession] = []
    @Published private(set) var book = CarbBook()
    @Published private(set) var fuel: [FuelEntry] = []
    @Published private(set) var phonePulls: [Pull] = []
    @Published private(set) var phoneTipIns: [TipInEvent] = []
    @Published private(set) var stats: [String: TripStats] = [:]
    @Published private(set) var pending = 0                       // Fahrten, die noch ausgewertet werden
    @Published private(set) var loaded = false
    @Published private(set) var demo = false
    @Published var sync: SyncState = .idle
    @Published private(set) var lastSync: Date?
    @Published private(set) var revision = 0                      // zaehlt bei jedem Neuladen hoch

    private var demoRows: [String: [TripRow]] = [:]
    private var rowCache: [String: [TripRow]] = [:]
    private var cacheOrder: [String] = []
    private var statsTask: Task<Void, Never>?
    private var aggregateCache: [String: TuningSession] = [:]

    var targets: MixtureTargets { MixtureTargets.load() }
    var vehicle: Vehicle { Vehicle.load() }
    var hasData: Bool { !trips.isEmpty || !sessions.isEmpty }

    /// Kennzahlen aller Fahrten, aelteste zuerst
    var allStats: [TripStats] {
        trips.compactMap { stats[$0.id] }.sorted { $0.start < $1.start }
    }

    func stats(in p: Period) -> [TripStats] { allStats.filter { p.contains($0.start) } }

    /// Alle Zuege: aus den Fahrten erkannt, dazu die live erkannten ausserhalb aufgezeichneter Fahrten
    var allPulls: [Pull] {
        var out = allStats.flatMap { $0.pulls }
        let windows = allStats.map { ($0.start, $0.end) }
        for p in phonePulls where !windows.contains(where: { p.time >= $0.0 && p.time <= $0.1 }) {
            out.append(p)
        }
        return out.sorted { $0.time > $1.time }
    }

    var allTipIns: [TipInEvent] {
        var out = allStats.flatMap { $0.tipIns }
        let windows = allStats.map { ($0.start, $0.end) }
        for e in phoneTipIns where !windows.contains(where: { e.time >= $0.0 && e.time <= $0.1 }) {
            out.append(e)
        }
        return out.sorted { $0.time > $1.time }
    }

    // MARK: Laden

    func load(demo: Bool) {
        self.demo = demo
        reload()
    }

    func setDemo(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "mac.demo")
        load(demo: on)
    }

    func reload() {
        statsTask?.cancel()
        aggregateCache = [:]
        rowCache = [:]
        cacheOrder = []
        lastSync = Self.readSyncStamp()
        if demo {
            let bundle = DemoData.make()
            var refs: [TripRef] = []
            demoRows = [:]
            for t in bundle.trips {
                refs.append(TripRef(summary: t.summary, csv: nil, source: "Beispiel"))
                demoRows[t.summary.id] = t.rows
            }
            apply(ScanResult(trips: refs.sorted { $0.summary.start > $1.summary.start },
                             sessions: bundle.sessions, book: bundle.book, fuel: bundle.fuel))
            stats = [:]
        } else {
            demoRows = [:]
            let roots = [DataPaths.phone, DataPaths.imported] + DataPaths.extra
            Task {
                let result = await Task.detached(priority: .userInitiated) { Self.scan(roots) }.value
                self.apply(result)
                self.stats = self.stats.filter { k, _ in result.trips.contains { $0.id == k } }
                self.computeStats()
            }
            return
        }
        computeStats()
    }

    private func apply(_ r: ScanResult) {
        trips = r.trips
        sessions = r.sessions
        book = r.book ?? CarbBook()
        fuel = r.fuel.sorted { $0.date > $1.date }
        phonePulls = r.pulls
        phoneTipIns = r.tipIns
        loaded = true
        revision += 1
    }

    nonisolated static func scan(_ roots: [URL]) -> ScanResult {
        var r = ScanResult()
        var tripIDs = Set<String>()
        var sessionIDs = Set<UUID>()
        var fuelIDs = Set<UUID>()
        var pullIDs = Set<UUID>()
        var tipIDs = Set<UUID>()
        let fm = FileManager.default
        let dec = JSONDecoder()
        for root in roots where fm.fileExists(atPath: root.path) {
            let source = root.path.hasPrefix(DataPaths.phone.path) ? "iPhone"
                : (root.path.hasPrefix(DataPaths.imported.path) ? "Import" : root.lastPathComponent)
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in en {
                if en.level > 7 { en.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "json" else { continue }
                let name = url.lastPathComponent
                let folder = url.deletingLastPathComponent().lastPathComponent
                guard let data = try? Data(contentsOf: url) else { continue }
                switch name {
                case "Vergaser.json":
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    if let b = try? dec.decode(CarbBook.self, from: data), date > r.bookDate || r.book == nil {
                        r.book = b
                        r.bookDate = date
                    }
                    continue
                case "Tankbuch.json":
                    if let f = try? dec.decode([FuelEntry].self, from: data) {
                        for e in f where !fuelIDs.contains(e.id) { fuelIDs.insert(e.id); r.fuel.append(e) }
                    }
                    continue
                case "Zuege.json":
                    if let p = try? dec.decode([Pull].self, from: data) {
                        for e in p where !pullIDs.contains(e.id) { pullIDs.insert(e.id); r.pulls.append(e) }
                    }
                    continue
                case "Gasstoesse.json":
                    if let p = try? dec.decode([TipInEvent].self, from: data) {
                        for e in p where !tipIDs.contains(e.id) { tipIDs.insert(e.id); r.tipIns.append(e) }
                    }
                    continue
                default:
                    break
                }
                if folder == "Fahrten", let s = try? dec.decode(TripSummary.self, from: data) {
                    let csv = url.deletingPathExtension().appendingPathExtension("csv")
                    guard fm.fileExists(atPath: csv.path), !tripIDs.contains(s.id) else { continue }
                    tripIDs.insert(s.id)
                    r.trips.append(TripRef(summary: s, csv: csv, source: source))
                } else if folder == "Messreihen", var s = try? dec.decode(TuningSession.self, from: data) {
                    guard !sessionIDs.contains(s.id), s.lambdaCount > 0 else { continue }
                    sessionIDs.insert(s.id)
                    if name == "aktuell.json" { s.name = "Aktuell (" + source + ")" }
                    r.sessions.append(s)
                }
            }
        }
        r.trips.sort { $0.summary.start > $1.summary.start }
        r.sessions.sort { $0.created > $1.created }
        return r
    }

    // MARK: Zeilen einer Fahrt

    func rows(_ trip: TripRef) async -> [TripRow] {
        if let d = demoRows[trip.id] { return d }
        if let c = rowCache[trip.id] {
            cacheOrder.removeAll { $0 == trip.id }
            cacheOrder.append(trip.id)
            return c
        }
        guard let url = trip.csv else { return [] }
        let rows = await Task.detached(priority: .userInitiated) { Self.readRows(url) }.value
        rowCache[trip.id] = rows
        cacheOrder.append(trip.id)
        while cacheOrder.count > 12 {
            rowCache[cacheOrder.removeFirst()] = nil
        }
        return rows
    }

    nonisolated static func readRows(_ url: URL) -> [TripRow] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return TripCSV.parse(text)
    }

    // MARK: Kennzahlen im Hintergrund

    private func computeStats() {
        let list = trips
        let demoCopy = demoRows
        let cacheURL = DataPaths.cache.appendingPathComponent("kennzahlen.json")
        pending = list.count
        statsTask = Task { [weak self] in
            var cache: [String: CachedStats] = [:]
            if demoCopy.isEmpty {
                cache = await Task.detached { () -> [String: CachedStats] in
                    guard let d = try? Data(contentsOf: cacheURL),
                          let c = try? JSONDecoder().decode([String: CachedStats].self, from: d) else { return [:] }
                    return c
                }.value
            }
            var changed = false
            var batch: [String: TripStats] = [:]
            for (i, t) in list.enumerated() {
                if Task.isCancelled { return }
                let sig = Self.signature(t)
                if let c = cache[t.id], c.sig == sig {
                    batch[t.id] = c.stats
                } else {
                    let rows = demoCopy[t.id]
                    let csv = t.csv
                    let st = await Task.detached(priority: .utility) { () -> TripStats in
                        let r = rows ?? csv.map { Self.readRows($0) } ?? []
                        return TripStats.compute(summary: t.summary, rows: r)
                    }.value
                    batch[t.id] = st
                    if demoCopy.isEmpty {
                        cache[t.id] = CachedStats(sig: sig, stats: st)
                        changed = true
                    }
                }
                // in Schueben veroeffentlichen, damit die Oberflaeche nicht staendig neu rechnet
                if batch.count >= 8 || i == list.count - 1 {
                    guard let self else { return }
                    self.stats.merge(batch) { _, new in new }
                    self.pending = list.count - i - 1
                    batch = [:]
                }
            }
            if list.isEmpty { self?.pending = 0 }
            if changed {
                let keep = Set(list.map { $0.id })
                let pruned = cache.filter { keep.contains($0.key) }
                await Task.detached {
                    try? FileManager.default.createDirectory(at: DataPaths.cache, withIntermediateDirectories: true)
                    if let d = try? JSONEncoder().encode(pruned) { try? d.write(to: cacheURL, options: .atomic) }
                }.value
            }
        }
    }

    nonisolated static func signature(_ t: TripRef) -> String {
        var sig = "v\(TripStats.version)"
        if let url = t.csv, let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            sig += "-\(v.fileSize ?? 0)-\(Int(v.contentModificationDate?.timeIntervalSince1970 ?? 0))"
        }
        return sig
    }

    // MARK: Messreihe ueber einen Zeitraum

    /// Alle Fahrten im Zeitraum als eine Messreihe
    func aggregate(_ p: Period, name: String) async -> TuningSession {
        let list = trips.filter { p.contains($0.summary.start) }
        let key = "\(revision)|\(p.from?.timeIntervalSince1970 ?? 0)|\(p.to?.timeIntervalSince1970 ?? 0)|\(list.count)"
        if var s = aggregateCache[key] {
            s.name = name
            return s
        }
        let demoCopy = demoRows
        var s = await Task.detached(priority: .userInitiated) { () -> TuningSession in
            var s = TuningSession(name: name)
            for t in list.reversed() {
                let rows = demoCopy[t.id] ?? t.csv.map { Self.readRows($0) } ?? []
                s.add(rows: rows)
            }
            if let first = list.last { s.created = first.summary.start }
            return s
        }.value
        s.name = name
        aggregateCache[key] = s
        return s
    }

    // MARK: Vom iPhone holen

    var canSync: Bool { FileManager.default.isExecutableFile(atPath: DataPaths.syncScript.path)
        || FileManager.default.fileExists(atPath: DataPaths.syncScript.path) }

    func syncFromPhone() {
        guard sync != .running else { return }
        guard canSync else {
            sync = .failed("Der Abgleich ist noch nicht eingerichtet. Im Terminal das Setup-Skript noch einmal ausführen.")
            return
        }
        sync = .running
        let script = DataPaths.syncScript.path
        Task {
            let result = await Task.detached { () -> (Int32, String) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [script]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do {
                    try p.run()
                } catch {
                    return (-1, error.localizedDescription)
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return (p.terminationStatus, String(decoding: data, as: UTF8.self))
            }.value
            let last = result.1.split(separator: "\n").last.map(String.init) ?? ""
            if result.0 == 0 {
                self.sync = .done(last.isEmpty ? "Daten geholt" : Self.stripStamp(last))
                self.reload()
            } else {
                self.sync = .failed(last.isEmpty ? "Abgleich fehlgeschlagen" : Self.stripStamp(last))
            }
        }
    }

    /// "2026-11-18 22:03:58  Text" -> "Text"
    nonisolated static func stripStamp(_ line: String) -> String {
        let parts = line.components(separatedBy: "  ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: "  ") : line
    }

    nonisolated static func readSyncStamp() -> Date? {
        guard let t = try? String(contentsOf: DataPaths.syncStamp, encoding: .utf8),
              let v = Double(t.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: v)
    }

    // MARK: Import

    /// Dateien oder Ordner uebernehmen (hineingezogen oder ueber Ablage › Importieren)
    func importItems(_ urls: [URL]) {
        Task {
            let n = await Task.detached { Self.copyIn(urls) }.value
            self.sync = .done(n == 1 ? "1 Datei übernommen" : "\(n) Dateien übernommen")
            self.reload()
        }
    }

    nonisolated static func copyIn(_ urls: [URL]) -> Int {
        let fm = FileManager.default
        let base = DataPaths.imported
        let trips = base.appendingPathComponent("Fahrten", isDirectory: true)
        let sessions = base.appendingPathComponent("Messreihen", isDirectory: true)
        try? fm.createDirectory(at: trips, withIntermediateDirectories: true)
        try? fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        var count = 0
        func put(_ src: URL, _ dst: URL) {
            try? fm.removeItem(at: dst)
            if (try? fm.copyItem(at: src, to: dst)) != nil { count += 1 }
        }
        let dec = JSONDecoder()
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let stamp = Int(Date().timeIntervalSince1970)
                put(url, base.appendingPathComponent(url.lastPathComponent + "-\(stamp)", isDirectory: true))
                continue
            }
            let ext = url.pathExtension.lowercased()
            let stem = url.deletingPathExtension().lastPathComponent
            if ext == "csv" {
                put(url, trips.appendingPathComponent(stem + ".csv"))
                let json = url.deletingPathExtension().appendingPathExtension("json")
                if fm.fileExists(atPath: json.path) {
                    put(json, trips.appendingPathComponent(stem + ".json"))
                } else {
                    // Zusammenfassung aus den Zeilen erzeugen
                    let rows = readRows(url)
                    guard !rows.isEmpty else { continue }
                    let start = startDate(url) ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                    let s = TripSummary.from(id: stem, start: start, rows: rows)
                    if let d = try? JSONEncoder().encode(s) {
                        try? d.write(to: trips.appendingPathComponent(stem + ".json"), options: .atomic)
                    }
                }
                continue
            }
            guard ext == "json", let data = try? Data(contentsOf: url) else { continue }
            let name = url.lastPathComponent
            if (try? dec.decode(TripSummary.self, from: data)) != nil {
                put(url, trips.appendingPathComponent(name))
                let csv = url.deletingPathExtension().appendingPathExtension("csv")
                if fm.fileExists(atPath: csv.path) { put(csv, trips.appendingPathComponent(stem + ".csv")) }
            } else if (try? dec.decode(TuningSession.self, from: data)) != nil {
                put(url, sessions.appendingPathComponent(name))
            } else if (try? dec.decode(CarbBook.self, from: data)) != nil {
                put(url, base.appendingPathComponent("Vergaser.json"))
            } else if (try? dec.decode([FuelEntry].self, from: data)) != nil {
                put(url, base.appendingPathComponent("Tankbuch.json"))
            } else if (try? dec.decode([Pull].self, from: data)) != nil {
                put(url, base.appendingPathComponent("Zuege.json"))
            } else if (try? dec.decode([TipInEvent].self, from: data)) != nil {
                put(url, base.appendingPathComponent("Gasstoesse.json"))
            }
        }
        return count
    }

    /// Startzeit aus der ersten Datenzeile der CSV ("yyyy-MM-dd HH:mm:ss.SS")
    nonisolated static func startDate(_ url: URL) -> Date? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 600), as: UTF8.self)
        let lines = head.split(separator: "\n")
        guard lines.count >= 2, let first = lines[1].split(separator: ";").first else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS"
        return f.date(from: String(first))
    }

    func showInFinder() {
        let url = demo ? DataPaths.base : DataPaths.base
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
