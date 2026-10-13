import SwiftUI

@main
struct CitroenAnzeigeApp: App {
    @StateObject private var ble = BLEManager()

    var body: some Scene {
        WindowGroup {
            ContentView(ble: ble)
        }
    }
}
