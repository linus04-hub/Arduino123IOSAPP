import Foundation
import ActivityKit

// ── Live-Aktivitaet starten, aktualisieren, beenden ──────────────
// Laeuft, solange Anzeige oder 123 verbunden sind. Aktualisiert hoechstens
// alle 2 s und nur bei Aenderung, damit iOS nicht drosselt.
final class LiveActivityController {
    private var activity: Activity<CitroenActivityAttributes>?
    private var lastState: CitroenActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast
    private var lastAttempt = Date.distantPast

    func update(enabled: Bool, active: Bool, state: CitroenActivityAttributes.ContentState) {
        guard enabled, active else {
            end()
            return
        }
        guard let a = activity else {
            start(state)
            return
        }
        let now = Date()
        guard state != lastState, now.timeIntervalSince(lastUpdate) >= 2 else { return }
        lastUpdate = now
        lastState = state
        Task {
            await a.update(using: state)
        }
    }

    func end() {
        guard let a = activity else { return }
        activity = nil
        lastState = nil
        Task {
            await a.end(using: nil, dismissalPolicy: .immediate)
        }
    }

    /// Reste einer frueheren Sitzung entfernen (z. B. nach Absturz)
    func endAll() {
        Task {
            for a in Activity<CitroenActivityAttributes>.activities {
                await a.end(using: nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func start(_ state: CitroenActivityAttributes.ContentState) {
        // Starten geht nur im Vordergrund; bei Fehler spaeter erneut versuchen
        let now = Date()
        guard now.timeIntervalSince(lastAttempt) >= 5 else { return }
        lastAttempt = now
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity<CitroenActivityAttributes>.request(
                attributes: CitroenActivityAttributes(title: "Citroën"),
                contentState: state,
                pushType: nil)
            lastState = state
            lastUpdate = now
        } catch {
            activity = nil
        }
    }
}
