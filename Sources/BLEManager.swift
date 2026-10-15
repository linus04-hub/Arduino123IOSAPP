import Foundation
import CoreBluetooth
import UIKit

// ── Messwerte, wie sie die BLE-Bridge schickt ─────────────────────
struct Reading: Equatable {
    var lambda: Double     // 4.5 = Sonde nicht bereit
    var pressure: Double   // bar, -1 = Sensorfehler
    var temp: Double       // °C,  -1 = Sensorfehler
    var tank: Double       // %, 255 = kein Tankwert
    var flags: UInt8       // Bit0: Bridge-Eingang ok, Bit1: Arduino-Signal ok

    var c6Ok: Bool      { flags & 0x01 != 0 }
    var arduinoOk: Bool { flags & 0x02 != 0 }
    var tankValue: Double? { tank <= 100 ? tank : nil }
}

extension Reading {
    /// 8-Byte-Paket, Little Endian — Aufbau wie `struct Packet` in ESP32_BLE_Bridge_V1
    init?(packet data: Data) {
        guard data.count >= 8 else { return nil }
        let b = [UInt8](data.prefix(8))
        let lam = UInt16(b[0]) | (UInt16(b[1]) << 8)
        let pr  = Int16(bitPattern: UInt16(b[2]) | (UInt16(b[3]) << 8))
        let t   = Int16(bitPattern: UInt16(b[4]) | (UInt16(b[5]) << 8))
        self.init(lambda: Double(lam) / 1000,
                  pressure: Double(pr) / 100,
                  temp: Double(t) / 10,
                  tank: Double(b[6]),
                  flags: b[7])
    }

    /// Gegenrichtung, damit der Demo-Modus durch denselben Decoder laeuft
    var packet: Data {
        let lam = UInt16(clamping: Int((lambda * 1000).rounded()))
        let pr  = UInt16(bitPattern: Int16(clamping: Int((pressure * 100).rounded())))
        let t   = UInt16(bitPattern: Int16(clamping: Int((temp * 10).rounded())))
        let tk  = UInt8(clamping: Int(tank.rounded()))
        return Data([UInt8(lam & 0xFF), UInt8(lam >> 8),
                     UInt8(pr & 0xFF),  UInt8(pr >> 8),
                     UInt8(t & 0xFF),   UInt8(t >> 8),
                     tk, flags])
    }
}

/// Ein Zeitpunkt im Verlauf (alle 0,25 s). nil = kein gueltiger Wert (Luecke in der Kurve)
struct Sample: Equatable {
    let time: Date
    var lambda: Double? = nil
    var rpm: Double? = nil
    var mapKPa: Double? = nil
    var oilP: Double? = nil
    var oilT: Double? = nil
    var tank: Double? = nil
    var advance: Double? = nil
    var voltage: Double? = nil
    var coil: Double? = nil
    var moduleTemp: Double? = nil
    var speed: Double? = nil          // km/h vom iPhone-GPS
}

/// Ein Punkt fuer "Lambda ueber Drehzahl"
struct ScatterPoint: Equatable {
    let rpm: Double
    let lambda: Double
    let mapKPa: Double?
}

enum LinkState: Equatable {
    case searching, connecting, live, demo, bluetoothOff, unauthorized
}

// ── Bluetooth: Bridge (Lambda/Oel/Tank) und 123ignition gleichzeitig ──
final class BLEManager: NSObject, ObservableObject {
    // Bridge — muss zur Firmware passen (SERVICE_UUID / DATA_UUID)
    static let bridgeService = CBUUID(string: "C172A000-2C60-4E6B-9F1D-7A3E5B8C0001")
    static let bridgeData    = CBUUID(string: "C172A001-2C60-4E6B-9F1D-7A3E5B8C0001")
    static let bridgeCtrl    = CBUUID(string: "C172A002-2C60-4E6B-9F1D-7A3E5B8C0001")  // ab Bridge v3
    // 123ignition, aeltere Modelle (BlueRadios BRSP, siehe Tune123.swift)
    static let tuneService = CBUUID(string: Tune123.serviceUUIDString)
    static let tuneMode    = CBUUID(string: Tune123.modeUUIDString)
    static let tuneRX      = CBUUID(string: Tune123.rxUUIDString)
    static let tuneTX      = CBUUID(string: Tune123.txUUIDString)
    // 123ignition, neuere Modelle (Nordic UART Service)
    static let nusService  = CBUUID(string: Tune123.nusServiceUUIDString)
    static let nusRX       = CBUUID(string: Tune123.nusRXUUIDString)
    static let nusTX       = CBUUID(string: Tune123.nusTXUUIDString)

    static let graphStep: TimeInterval = 0.25         // Abstand der Punkte im Verlauf
    static let graphWindow: TimeInterval = 60         // Zeitfenster des Verlaufs
    static let scatterMax = 1200                      // 2 Punkte/s -> 10 min
    static let bridgeStaleAfter: TimeInterval = 3
    static let tuneStaleAfter: TimeInterval = 5       // 123 sendet nur ca. 3 Frames/s, reihum

    @Published private(set) var bridgeState: LinkState = .searching
    @Published private(set) var tuneState: LinkState = .searching
    // Letzte Messwerte. Das weiche Mitlaufen machen die Anzeigen selbst (Motion in Gauges.swift).
    @Published private(set) var shown: Reading?        // Bridge; nil = keine Daten
    @Published private(set) var tune: TuneReading?     // 123; nil = keine Daten
    @Published private(set) var history: [Sample] = []
    @Published private(set) var scatter: [ScatterPoint] = []
    @Published private(set) var warning: String?      // Bridge / Bluetooth allgemein
    @Published private(set) var tuneWarning: String?   // 123ignition
    @Published private(set) var bridgeVersion: String?     // z. B. "Bridge 3.0", nil = unbekannt
    @Published private(set) var bridgeCanUpdate = false    // Bridge v3+: Update-Modus per App

    var isDemo: Bool { bridgeState == .demo }
    var noSignal: Bool { bridgeState == .live && warning != nil }
    var anyLive: Bool { bridgeState == .live || tuneState == .live }

    /// Wird alle 0,25 s mit den aktuellen Werten aufgerufen (Fahrtenschreiber, Messreihen, Live-Aktivitaet)
    var onSample: ((Sample) -> Void)?
    /// Liefert das GPS-Tempo in km/h
    var speedSource: () -> Double? = { nil }

    private var central: CBCentralManager!
    private var bridge: CBPeripheral?
    private var ignition: CBPeripheral?
    private var tuneRXChar: CBCharacteristic?
    private var bridgeCtrlChar: CBCharacteristic?

    private var target: Reading?
    private var lastPacket = Date.distantPast
    private var tuneTarget: TuneReading?
    private var tuneParser = Tune123Parser()
    private var lastTuneFrame = Date.distantPast
    private var lastKeepalive = Date.distantPast

    private var lastGraph = Date()
    private var scatterTurn = false
    private var lastDemo = Date.distantPast
    private var demoTime: Double = 0
    private var demoCount = 0
    private var tuneDemo = Tune123Demo()
    private var timer: Timer?
    private var idleTimerOff = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        // 10 Hz fuer Demo, Keepalive, Verlauf und Warnungen. Die Anzeigen
        // animieren unabhaengig davon mit Bildschirmrate.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Bridge v3+ in den Update-Modus schicken (WLAN "Citroen-Update").
    /// Die Bridge startet dafuer neu und ist so lange nicht per Bluetooth da.
    @discardableResult
    func startBridgeUpdate() -> Bool {
        guard let c = bridgeCtrlChar, let p = bridge, bridgeState == .live else { return false }
        write(Data("UPDATE".utf8), to: c, on: p)
        return true
    }

    private func forgetBridgeControl() {
        bridgeCtrlChar = nil
        bridgeCanUpdate = false
    }

    /// Punktewolke leeren, z. B. nach einer Aenderung am Vergaser
    func clearScatter() {
        scatter = []
    }

    // ── Demo ──────────────────────────────────────────────────────
    func toggleDemo() {
        // Demo- und echte Werte nicht im Verlauf mischen
        history = []
        scatter = []
        if isDemo {
            target = nil
            tuneTarget = nil
            shown = nil
            tune = nil
            tuneParser.reset()
            bridgeState = .searching
            tuneState = .searching
            centralManagerDidUpdateState(central)   // scannt, oder zeigt "Bluetooth aus"
        } else {
            if central.state == .poweredOn {
                central.stopScan()
                // erst Referenzen loeschen, dann trennen: so verbindet didDisconnect nicht neu
                let old = [bridge, ignition].compactMap { $0 }
                bridge = nil
                ignition = nil
                tuneRXChar = nil
                forgetBridgeControl()
                old.forEach { central.cancelPeripheralConnection($0) }
            }
            bridge = nil
            ignition = nil
            target = nil
            tuneTarget = nil
            shown = nil
            tune = nil
            tuneParser.reset()
            demoTime = 0
            tuneDemo = Tune123Demo()
            bridgeState = .demo
            tuneState = .demo
            demoStep()
        }
    }

    private func demoStep() {
        demoTime += 0.1
        demoCount += 1
        let n = { Double.random(in: -0.5...0.5) }
        let r = Reading(lambda:   0.995 + 0.035 * sin(demoTime / 3.1) + 0.012 * n(),
                        pressure: 2.6 + 0.9 * sin(demoTime / 7) + 0.05 * n(),
                        temp:     min(96, 72 + demoTime * 0.12) + 0.2 * n(),
                        tank:     max(8, 62 - demoTime * 0.02),
                        flags:    0x03)
        receiveBridge(r.packet)                     // 10 Werte/s wie die Bridge
        if demoCount % 3 == 0 {
            receiveTune(tuneDemo.next())            // seltener, wie die 123; gleicher Parser wie echt
        }
    }

    // ── Takt: Demo, Keepalive, Verlauf, Warnungen ────────────────
    private func tick() {
        let now = Date()

        if isDemo, now.timeIntervalSince(lastDemo) >= 0.09 {
            lastDemo = now
            demoStep()
        }

        // Keepalive an die 123, wie es die 123-App macht
        if tuneState == .live, let rx = tuneRXChar, let p = ignition,
           now.timeIntervalSince(lastKeepalive) >= 1 {
            lastKeepalive = now
            write(Tune123.keepalive, to: rx, on: p)
        }

        if now.timeIntervalSince(lastGraph) >= Self.graphStep {
            lastGraph = now
            let sample = currentSample(now)
            var h = history
            h.append(sample)
            // etwas mehr als 60 s behalten, damit die Kurve links sauber rauslaeuft
            if let cut = h.firstIndex(where: { now.timeIntervalSince($0.time) <= Self.graphWindow + 1 }) {
                h.removeFirst(cut)
            }
            history = h
            onSample?(sample)

            // Punktewolke nur jeden zweiten Takt (2 Punkte/s), und nur mit Lambda UND Drehzahl
            scatterTurn.toggle()
            if scatterTurn, let l = sample.lambda, let r = sample.rpm, r >= 500 {
                var sc = scatter
                sc.append(ScatterPoint(rpm: r, lambda: l, mapKPa: sample.mapKPa))
                if sc.count > Self.scatterMax { sc.removeFirst(sc.count - Self.scatterMax) }
                scatter = sc
            }
        }

        updateWarnings(now: now)

        // Bildschirm nicht sperren, solange ein Geraet verbunden ist
        if anyLive != idleTimerOff {
            idleTimerOff = anyLive
            UIApplication.shared.isIdleTimerDisabled = anyLive
        }
    }

    /// Aktuelle Werte fuer den Verlauf; veraltete Werte werden zur Luecke
    private func currentSample(_ now: Date) -> Sample {
        var s = Sample(time: now)
        let bridgeFresh = (bridgeState == .live || bridgeState == .demo)
            && now.timeIntervalSince(lastPacket) <= Self.bridgeStaleAfter
        if bridgeFresh, let t = target {
            if t.lambda <= 2 { s.lambda = t.lambda }
            if t.pressure >= 0 { s.oilP = t.pressure }
            if t.temp >= 0 { s.oilT = t.temp }
            s.tank = t.tankValue
        }
        let tuneFresh = (tuneState == .live || tuneState == .demo)
            && now.timeIntervalSince(lastTuneFrame) <= Self.tuneStaleAfter
        if tuneFresh, let t = tuneTarget {
            s.rpm = t.rpm
            s.mapKPa = t.mapKPa
            s.advance = t.advance
            s.voltage = t.voltage
            s.coil = t.coilCurrent
            s.moduleTemp = t.moduleTemp
        }
        s.speed = speedSource()
        return s
    }

    private func updateWarnings(now: Date) {
        var w: String?
        switch bridgeState {
        case .live:
            let age = now.timeIntervalSince(lastPacket)
            if age > Self.bridgeStaleAfter {
                w = "Keine Daten seit \(Int(age)) s"
            } else if let t = target, !t.c6Ok {
                w = "Keine Daten vom Display-ESP32 – Kabel C6 → Bridge prüfen"
            } else if let t = target, !t.arduinoOk {
                w = "Kein Signal vom Arduino – Werte sind veraltet"
            }
        case .connecting where target != nil:
            w = "Verbindung zur Anzeige weg – verbinde neu …"
        case .bluetoothOff:
            w = "Bluetooth ist aus"
        case .unauthorized:
            w = "Kein Bluetooth-Zugriff: Einstellungen → Citroën → Bluetooth erlauben"
        default:
            break
        }
        if w != warning { warning = w }

        var tw: String?
        switch tuneState {
        case .live:
            let age = now.timeIntervalSince(lastTuneFrame)
            if age > Self.tuneStaleAfter {
                tw = "123ignition: keine Daten seit \(Int(age)) s"
            } else if tuneTarget?.tuningMode == true {
                tw = "123ignition im Tuning-Modus – Zündwinkel weicht von der Kurve ab"
            }
        case .connecting where tuneTarget != nil:
            tw = "Verbindung zur 123ignition weg – verbinde neu …"
        default:
            break
        }
        if tw != tuneWarning { tuneWarning = tw }
    }

    private func receiveBridge(_ data: Data) {
        guard let r = Reading(packet: data) else { return }
        target = r
        if r != shown { shown = r }
        lastPacket = Date()
    }

    private func receiveTune(_ data: Data) {
        let frames = tuneParser.feed(data)
        guard !frames.isEmpty else { return }
        var t = tuneTarget ?? TuneReading()
        frames.forEach { t.apply($0) }
        tuneTarget = t
        if t != tune { tune = t }
        lastTuneFrame = Date()
    }

    private func write(_ data: Data, to ch: CBCharacteristic, on p: CBPeripheral) {
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(data, for: ch, type: type)
    }

    // ── Verbindungsaufbau ─────────────────────────────────────────
    private func startScanIfPossible() {
        guard central.state == .poweredOn, !isDemo else { return }
        var services: [CBUUID] = []
        if bridge == nil   { services.append(Self.bridgeService); bridgeState = .searching }
        if ignition == nil {
            services += [Self.tuneService, Self.nusService]
            tuneState = .searching
        }
        guard !services.isEmpty else { central.stopScan(); return }
        // Duplikate erlauben: Name und Hersteller-ID der 123 kommen evtl. erst mit der Scan-Antwort
        central.scanForPeripherals(withServices: services,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// Nordic UART nutzen viele Geraete. Als 123 zaehlt es nur mit passendem Namen oder Hersteller.
    private func is123(name: String, advertisementData: [String: Any]) -> Bool {
        let n = name.uppercased()
        if n.contains("123") || n.contains("TUNE") { return true }
        if let m = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2 {
            let id = UInt16(m[m.startIndex]) | (UInt16(m[m.startIndex + 1]) << 8)
            return id == Tune123.albertronicID
        }
        return false
    }

    private func retryLater() {
        guard !isDemo else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.startScanIfPossible()
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !isDemo else { return }
        switch central.state {
        case .poweredOn:
            startScanIfPossible()
        default:
            bridge = nil
            ignition = nil
            tuneRXChar = nil
            forgetBridgeControl()
            target = nil
            tuneTarget = nil
            shown = nil
            tune = nil
            tuneParser.reset()
            let s: LinkState = central.state == .unauthorized ? .unauthorized : .bluetoothOff
            bridgeState = s
            tuneState = s
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !isDemo, peripheral != bridge, peripheral != ignition else { return }
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
                  + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""

        if bridge == nil, uuids.contains(Self.bridgeService) || name.hasPrefix("Citroen") {
            bridge = peripheral             // starke Referenz halten, sonst bricht iOS die Verbindung ab
            bridgeState = .connecting
            central.connect(peripheral, options: nil)
        } else if ignition == nil,
                  uuids.contains(Self.tuneService)
                  || (uuids.contains(Self.nusService) && is123(name: name, advertisementData: advertisementData)) {
            ignition = peripheral
            tuneState = .connecting
            central.connect(peripheral, options: nil)
        }
        if bridge != nil && ignition != nil { central.stopScan() }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        if peripheral == bridge {
            peripheral.discoverServices([Self.bridgeService])
        } else if peripheral == ignition {
            tuneParser.reset()
            peripheral.discoverServices([Self.tuneService, Self.nusService])
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral == bridge { bridge = nil; forgetBridgeControl() }
        if peripheral == ignition { ignition = nil; tuneRXChar = nil }
        retryLater()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard !isDemo else { return }
        // Verbindungswunsch bleibt offen: iOS verbindet von selbst neu,
        // sobald das Geraet wieder Strom hat und in Reichweite ist.
        if peripheral == bridge {
            forgetBridgeControl()
            bridgeState = .connecting
            central.connect(peripheral, options: nil)
        } else if peripheral == ignition {
            tuneRXChar = nil
            tuneState = .connecting
            central.connect(peripheral, options: nil)
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let wanted: [CBUUID: [CBUUID]]
        if peripheral == bridge {
            wanted = [Self.bridgeService: [Self.bridgeData, Self.bridgeCtrl]]
        } else if peripheral == ignition {
            wanted = [Self.tuneService: [Self.tuneMode, Self.tuneRX, Self.tuneTX],
                      Self.nusService:  [Self.nusRX, Self.nusTX]]
        } else { return }

        guard let svc = peripheral.services?.first(where: { wanted[$0.uuid] != nil }),
              let chars = wanted[svc.uuid] else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics(chars, for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []

        if peripheral == bridge {
            guard let ch = chars.first(where: { $0.uuid == Self.bridgeData }) else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.setNotifyValue(true, for: ch)
            peripheral.readValue(for: ch)
            // Ab v3: Version lesen, Update-Modus moeglich
            if let ctrl = chars.first(where: { $0.uuid == Self.bridgeCtrl }) {
                bridgeCtrlChar = ctrl
                bridgeCanUpdate = true
                peripheral.readValue(for: ctrl)
            } else {
                forgetBridgeControl()
                bridgeVersion = nil
            }
            lastPacket = Date()
            bridgeState = .live

        } else if peripheral == ignition {
            let nus = service.uuid == Self.nusService
            guard let tx = chars.first(where: { $0.uuid == (nus ? Self.nusTX : Self.tuneTX) }),
                  let rx = chars.first(where: { $0.uuid == (nus ? Self.nusRX : Self.tuneRX) }) else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.setNotifyValue(true, for: tx)
            if let mode = chars.first(where: { $0.uuid == Self.tuneMode }) {
                write(Data([Tune123.dataMode]), to: mode, on: peripheral)
            }
            write(Tune123.hello, to: rx, on: peripheral)
            tuneRXChar = rx
            lastTuneFrame = Date()       // Schonfrist, bevor "keine Daten" erscheint
            lastKeepalive = Date()
            tuneState = .live
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        if peripheral == bridge, characteristic.uuid == Self.bridgeCtrl {
            bridgeVersion = String(data: data, encoding: .utf8)
        } else if peripheral == bridge, bridgeState == .live, characteristic.uuid == Self.bridgeData {
            receiveBridge(data)
        } else if peripheral == ignition, tuneState == .live,
                  characteristic.uuid == Self.tuneTX || characteristic.uuid == Self.nusTX {
            receiveTune(data)
        }
    }
}
