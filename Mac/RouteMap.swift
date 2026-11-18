import SwiftUI
import MapKit

// ── Strecke auf der Karte, eingefaerbt nach dem Gemisch ─────────

struct RouteSegment: Identifiable {
    let id: Int
    let coords: [CLLocationCoordinate2D]
    let color: Color
}

struct RouteMarker: Identifiable {
    let id: Int
    let coord: CLLocationCoordinate2D
}

enum RouteBuilder {
    /// Hoechstens ~900 Punkte, Abschnitte gleicher Farbe zusammengefasst
    static func segments(_ rows: [TripRow], targets: MixtureTargets) -> [RouteSegment] {
        let withPos = rows.filter { $0.lat != nil && $0.lon != nil && $0.lat != 0 }
        guard withPos.count >= 2 else { return [] }
        let step = max(1, withPos.count / 900)
        var out: [RouteSegment] = []
        var coords: [CLLocationCoordinate2D] = []
        var color: Color?
        var i = 0
        while i < withPos.count {
            let r = withPos[i]
            let c = CLLocationCoordinate2D(latitude: r.lat!, longitude: r.lon!)
            var col = Color.gray
            if let l = r.lambdaValid, let rpm = r.rpm, rpm >= 300, let k = r.map {
                let j = MixtureJudge.judge(lambda: l, regime: Regime.of(rpm: rpm, kPa: k), targets: targets)
                if j.target != nil { col = j.severity.tint }
            }
            if let cur = color, cur != col, coords.count >= 2 {
                out.append(RouteSegment(id: out.count, coords: coords, color: cur))
                coords = [coords.last!]
            }
            color = col
            coords.append(c)
            i += step
        }
        if let cur = color, coords.count >= 2 { out.append(RouteSegment(id: out.count, coords: coords, color: cur)) }
        return out
    }

    static func markers(_ rows: [TripRow]) -> [RouteMarker] {
        rows.compactMap { r in
            guard let m = r.marker, let la = r.lat, let lo = r.lon else { return nil }
            return RouteMarker(id: m, coord: CLLocationCoordinate2D(latitude: la, longitude: lo))
        }
    }
}

struct RouteMapView: View {
    let segments: [RouteSegment]
    let markers: [RouteMarker]
    let rows: [TripRow]
    let cursor: TripCursor

    var body: some View {
        Map(initialPosition: .automatic) {
            ForEach(segments) { s in
                MapPolyline(coordinates: s.coords)
                    .stroke(s.color, lineWidth: 4)
            }
            ForEach(markers) { m in
                Marker("\(m.id)", systemImage: "flag.fill", coordinate: m.coord)
                    .tint(.orange)
            }
            if let c = cursorCoordinate {
                Annotation("", coordinate: c) {
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.black, lineWidth: 2))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapZoomStepper()
            MapCompass()
        }
    }

    private var cursorCoordinate: CLLocationCoordinate2D? {
        guard let t = cursor.hover, let i = TripIndex.nearest(rows, t),
              let la = rows[i].lat, let lo = rows[i].lon else { return nil }
        return CLLocationCoordinate2D(latitude: la, longitude: lo)
    }
}
