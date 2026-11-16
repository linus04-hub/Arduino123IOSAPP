import Foundation

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
    /// nil, solange die Sonde heizt oder nicht bereit ist
    var lambdaValue: Double? { lambda <= 2 ? lambda : nil }
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

// ── Mittelwert und Streuung in einem Zeitfenster des Verlaufs ────
struct WindowStat {
    let mean: Double
    let spread: Double
    let count: Int
    let min: Double
    let max: Double
}

enum SampleWindow {
    static func stat(_ samples: [Sample], from: Date, to: Date, _ value: (Sample) -> Double?) -> WindowStat? {
        var vals: [Double] = []
        for s in samples where s.time >= from && s.time <= to {
            if let v = value(s) { vals.append(v) }
        }
        guard vals.count >= 4 else { return nil }
        let n = Double(vals.count)
        let m = vals.reduce(0, +) / n
        var sq = 0.0
        for v in vals { sq += (v - m) * (v - m) }
        return WindowStat(mean: m, spread: (sq / n).squareRoot(), count: vals.count,
                          min: vals.min() ?? m, max: vals.max() ?? m)
    }
}
