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
    private let live = LiveActivityController()

    @Published private(set) var isNight = false

    private var clock: Timer?

    init() {
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

        guard !ble.isDemo else { return }      // Demo-Werte nicht aufzeichnen
        tuning.add(s)
        tipIns.add(s)
        let running = (s.rpm ?? 0) >= 300 || (s.oilP ?? 0) >= 0.3
        recorder.autoCheck(engineRunning: running,
                           enabled: Self.flag(SettingKey.autoRecord, default: true),
                           now: s.time)
        recorder.record(s, location: location.freshLocation)
        updateLiveActivity(s)
    }

    private func updateLiveActivity(_ s: Sample) {
        var alert: String? = ble.warning ?? ble.tuneWarning
        if alert == nil {
            if let p = s.oilP, (s.rpm ?? 0) >= 800, p < 1.0 {
                alert = "Öldruck zu niedrig"
            } else if let t = s.oilT, t >= 145 {
                alert = "Öltemperatur kritisch"
            } else if let v = s.voltage, v < 11.8 {
                alert = "Bordnetz niedrig"
            }
        }
        let state = CitroenActivityAttributes.ContentState(
            lambda: s.lambda, oilT: s.oilT, oilP: s.oilP, rpm: s.rpm, speed: s.speed,
            alert: alert, recording: recorder.isRecording)
        live.update(enabled: Self.flag(SettingKey.liveActivity, default: true),
                    active: ble.anyLive, state: state)
    }
}
