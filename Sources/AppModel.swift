import Foundation
import SwiftUI

// ── Einstellungen ────────────────────────────────────────────────
enum SettingKey {
    static let night = "nightMode"
    static let liveActivity = "liveActivity"
    static let gps = "gps"
    static let autoRecord = "autoRecord"
}

enum NightMode: String, CaseIterable, Identifiable {
    case off, on, auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:  return "Aus"
        case .on:   return "An"
        case .auto: return "Nachts (20–7 Uhr)"
        }
    }
}

// ── Verteiler: Bluetooth, GPS, Fahrtenschreiber, Messreihen, Live-Aktivitaet ──
final class AppModel: ObservableObject {
    let ble = BLEManager()
    let location = LocationManager()
    let recorder = TripRecorder()
    let tuning = TuningStore()
    let idle = IdleAssistant()
    let tipIns = TipInAnalyzer()
    let pulls = PullStore()
    let alerts = AlertCenter()
    let carb = CarbLog()
    let fuel = FuelStore()
    private let live = LiveActivityController()

    @Published private(set) var isNight = false

    private var clock: Timer?
    private var settingsObserver: NSObjectProtocol?

    init() {
        LiveContext.reload()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            LiveContext.reload()
        }
        ble.speedSource = { [weak self] in self?.location.speedKmh }
        ble.onSample = { [weak self] s in self?.handle(s) }
        if Self.flag(SettingKey.gps, default: true) { location.requestPermissionIfNeeded() }
        live.endAll()
        updateNight()

        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateNight()
            self?.tuning.persist()
        }
        RunLoop.main.add(t, forMode: .common)
        clock = t
    }

    static func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    func setGPS(_ on: Bool) {
        if on {
            location.requestPermissionIfNeeded()
        } else {
            location.enabled = false
        }
    }

    func updateNight() {
        let raw = UserDefaults.standard.string(forKey: SettingKey.night) ?? NightMode.off.rawValue
        let mode = NightMode(rawValue: raw) ?? .off
        let night: Bool
        switch mode {
        case .off:
            night = false
        case .on:
            night = true
        case .auto:
            let h = Calendar.current.component(.hour, from: Date())
            night = h >= 20 || h < 7
        }
        if night != isNight {
            Theme.night = night
            isNight = night
        }
    }

    /// App geht in den Hintergrund: Daten sichern
    func saveAll() {
        tuning.persist()
        recorder.flushNow()
    }

    func refreshLiveActivity() {
        if !Self.flag(SettingKey.liveActivity, default: true) { live.end() }
    }

    private func handle(_ s: Sample) {
        // GPS nur, wenn es gebraucht wird
        let wantGPS = Self.flag(SettingKey.gps, default: true) && (recorder.isRecording || ble.anyLive)
        if location.enabled != wantGPS { location.enabled = wantGPS }

        location.expireIfStale(now: s.time)

        if ble.isDemo {
            // Demo-Werte nicht aufzeichnen. Nur fuer Bildschirmfotos im Simulator
            // (Startparameter -screenshotRecordDemo YES) fuellt die Demo die Messreihe.
            if UserDefaults.standard.bool(forKey: "screenshotRecordDemo") {
                tuning.add(s)
                tipIns.add(s)
                pulls.add(s)
            }
            _ = alerts.update(s)
            return
        }
        tuning.add(s)
        tipIns.add(s)
        pulls.add(s)
        for a in alerts.update(s) {
            alerts.notify(a)
            // in der laufenden Fahrt festhalten, aber dafuer keine Aufnahme starten
            if recorder.isRecording { recorder.addMarker(note: "Warnung: " + a.kind.title + " (" + a.detail + ")") }
        }
        // Motor laeuft: Die Drehzahl der 123 entscheidet. Nur ohne 123 zaehlt der Oeldruck,
        // und dann erst ab 0,5 bar, damit ein Sensor mit Nullpunktfehler keine Fahrt startet.
        let running: Bool
        if let r = s.rpm {
            running = r >= 300
        } else {
            running = (s.oilP ?? 0) >= 0.5
        }
        recorder.autoCheck(engineRunning: running,
                           enabled: Self.flag(SettingKey.autoRecord, default: true),
                           now: s.time)
        recorder.record(s, location: location.freshLocation)
        updateLiveActivity(s)
    }

    private func updateLiveActivity(_ s: Sample) {
        let alert: String? = alerts.top?.kind.title ?? ble.warning ?? ble.tuneWarning
        func number(_ l: Level) -> Int {
            switch l {
            case .ok:   return 1
            case .warn: return 2
            case .crit: return 3
            default:    return 0
            }
        }
        let lam = LiveJudge.lambda(s.lambda, rpm: s.rpm, kPa: s.mapKPa)
        let oil = s.oilP.map { ContextJudge.pressure($0, rpm: s.rpm).0.level }
        // Drehzahl auf 50 runden, sonst aendert sich der Stand bei jedem Takt
        let state = CitroenActivityAttributes.ContentState(
            lambda: s.lambda.map { ($0 * 100).rounded() / 100 },
            oilT: s.oilT.map { $0.rounded() }, oilP: s.oilP.map { ($0 * 10).rounded() / 10 },
            rpm: s.rpm.map { ($0 / 50).rounded() * 50 }, speed: s.speed.map { $0.rounded() },
            alert: alert, recording: recorder.isRecording,
            lambdaLevel: number(lam.level), oilPLevel: oil.map { number($0) })
        live.update(enabled: Self.flag(SettingKey.liveActivity, default: true),
                    active: ble.anyLive, state: state)
    }
}
