import Foundation
import ActivityKit

// Gemeinsam fuer App und Widget-Erweiterung: Inhalt der Live-Aktivitaet
// auf dem Sperrbildschirm und in der Dynamic Island.
struct CitroenActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var lambda: Double?
        var oilT: Double?
        var oilP: Double?
        var rpm: Double?
        var speed: Double?
        var alert: String?        // kurze Warnung, nil = alles in Ordnung
        var recording: Bool
    }

    var title: String
}
