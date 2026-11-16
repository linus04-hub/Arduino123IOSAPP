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
        // Einstufung aus der App (0 grau, 1 gruen, 2 gelb, 3 rot). nil = feste Grenzen.
        // Die App bewertet Lambda gegen das Ziel des Betriebsbereichs und den Oeldruck je
        // nach Motorlauf; das Widget kennt beides nicht.
        var lambdaLevel: Int? = nil
        var oilPLevel: Int? = nil
    }

    var title: String
}
