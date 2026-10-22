import XCTest

// Geht im Demo-Modus durch die App und speichert Bildschirmfotos.
// Laeuft nur im Workflow "Screenshots" (Simulator), nicht beim normalen Build.
// Bilder landen in ~/app-screens auf dem Mac, der den Simulator startet.

final class ScreenshotTests: XCTestCase {
    private let app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var outDir: URL!

    override func setUp() {
        continueAfterFailure = true
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSTemporaryDirectory()
        outDir = URL(fileURLWithPath: home).appendingPathComponent("app-screens")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    private func launch(layout: String) {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-layout", layout,
                               "-screenshotRecordDemo", "YES"]
        app.launch()
        dismissAlerts()
        startDemo()
    }

    private func dismissAlerts() {
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { return }
            let preferred = ["Beim Verwenden der App erlauben", "Erlauben", "Allow While Using App", "Allow", "OK"]
            if let b = preferred.map({ alert.buttons[$0] }).first(where: { $0.exists }) {
                b.tap()
            } else {
                alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
            }
        }
    }

    private func startDemo() {
        let demo = app.buttons["Demo-Werte zeigen"]
        if demo.waitForExistence(timeout: 8) { demo.tap() }
        sleep(6)                     // Werte laufen ein, Demo liest die Zuendkurven
        toTop()
    }

    private func toTop() {
        let sv = app.scrollViews.firstMatch
        if sv.exists {
            sv.swipeDown(velocity: .fast)
            sv.swipeDown(velocity: .fast)
        }
        sleep(1)
    }

    private func shot(_ name: String) {
        sleep(1)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: outDir.appendingPathComponent(name + ".png"))
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func scrollShot(_ name: String) {
        let sv = app.scrollViews.firstMatch
        guard sv.exists else { return }
        sv.swipeUp(velocity: .slow)
        shot(name)
    }

    private func tab(_ title: String) {
        let b = app.tabBars.buttons[title]
        if b.waitForExistence(timeout: 5) { b.tap() }
        sleep(1)
    }

    private func segment(_ title: String) {
        let b = app.segmentedControls.firstMatch.buttons[title]   // oberste Leiste
        if b.waitForExistence(timeout: 5) { b.tap() }
        sleep(1)
    }

    private func back() {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.exists { b.tap() }
        sleep(1)
    }

    private func open(_ text: String) {
        let t = app.staticTexts[text].firstMatch
        if t.waitForExistence(timeout: 5) { t.tap() }
        sleep(2)
    }

    func testScreens() {
        // Live in allen vier Ansichten
        launch(layout: "standard")
        shot("01-live-standard")
        scrollShot("02-live-standard-unten")

        // Abstimmung: etwas warten, damit sich Kennfeld und Zuendkurve fuellen
        sleep(40)
        tab("Abstimmung")
        segment("Kennfeld")
        shot("10-kennfeld")
        segment("Zündung")
        shot("11-zuendung")
        segment("Werkzeuge")
        shot("12-werkzeuge")
        open("Zündkurven der 123")
        shot("13-zuendkurven-1")
        scrollShot("14-zuendkurven-2")
        scrollShot("15-zuendkurven-3")
        scrollShot("16-zuendkurven-4")
        back()
        open("Leerlauf-Assistent")
        shot("17-leerlauf")
        back()
        open("Düsen-Rechner")
        shot("18-duesen")
        back()
        segment("Vergleich")
        shot("19-vergleich")

        tab("Fahrten")
        shot("20-fahrten")
        tab("Einstellungen")
        shot("30-einstellungen")
        scrollShot("31-einstellungen-unten")

        for (n, l) in [("03", "dials"), ("04", "focus"), ("05", "tuning")] {
            launch(layout: l)
            shot("\(n)-live-\(l)")
        }
    }
}
