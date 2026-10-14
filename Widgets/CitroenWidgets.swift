import WidgetKit
import SwiftUI
import ActivityKit

// ── Widget-Erweiterung: nur die Live-Aktivitaet ──────────────────

@main
struct CitroenWidgets: WidgetBundle {
    var body: some Widget {
        CitroenLiveActivity()
    }
}

enum LiveTheme {
    static let fg = Color(red: 0.93, green: 0.93, blue: 0.95)
    static let muted = Color(red: 0.60, green: 0.60, blue: 0.66)
    static let accent = Color(red: 0.99, green: 0.55, blue: 0.0)
    static let ok = Color(red: 0.18, green: 0.80, blue: 0.44)
    static let warn = Color(red: 0.95, green: 0.77, blue: 0.06)
    static let crit = Color(red: 0.91, green: 0.30, blue: 0.24)

    static func lambdaValue(_ l: Double?) -> Double? {
        guard let l, l <= 2 else { return nil }
        return l
    }

    static func lambda(_ l: Double?) -> Color {
        guard let l = lambdaValue(l) else { return muted }
        if l < 0.94 || l > 1.06 { return crit }
        if l < 0.98 || l > 1.02 { return warn }
        return ok
    }

    static func oilT(_ t: Double?) -> Color {
        guard let t else { return muted }
        if t >= 145 { return crit }
        if t >= 130 { return warn }
        if t < 60 { return muted }
        return ok
    }

    static func oilP(_ p: Double?) -> Color {
        guard let p else { return muted }
        if p < 1 { return crit }
        if p < 2 { return warn }
        return ok
    }

    static func text(_ v: Double?, _ format: String) -> String {
        guard let v else { return "--" }
        return String(format: format, v)
    }
}

struct LiveValue: View {
    let title: String
    let text: String
    var color: Color = LiveTheme.fg
    var size: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(LiveTheme.muted)
                .lineLimit(1)
            Text(text)
                .font(.system(size: size, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

struct LockScreenLiveView: View {
    let state: CitroenActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("CITROËN")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(LiveTheme.accent)
                if state.recording {
                    Circle().fill(LiveTheme.crit).frame(width: 7, height: 7)
                    Text("Aufnahme")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LiveTheme.muted)
                }
                Spacer()
                if let a = state.alert {
                    Text(a)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(LiveTheme.crit)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .top) {
                LiveValue(title: "LAMBDA",
                          text: LiveTheme.text(LiveTheme.lambdaValue(state.lambda), "%.3f"),
                          color: LiveTheme.lambda(state.lambda))
                Spacer(minLength: 4)
                LiveValue(title: "ÖLTEMP °C", text: LiveTheme.text(state.oilT, "%.0f"),
                          color: LiveTheme.oilT(state.oilT))
                Spacer(minLength: 4)
                LiveValue(title: "ÖLDRUCK", text: LiveTheme.text(state.oilP, "%.1f"),
                          color: LiveTheme.oilP(state.oilP))
                Spacer(minLength: 4)
                LiveValue(title: "U/MIN", text: LiveTheme.text(state.rpm, "%.0f"))
                Spacer(minLength: 4)
                LiveValue(title: "KM/H", text: LiveTheme.text(state.speed, "%.0f"))
            }
        }
        .padding(14)
    }
}

struct CitroenLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CitroenActivityAttributes.self) { context in
            LockScreenLiveView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.8))
                .activitySystemActionForegroundColor(LiveTheme.fg)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveValue(title: "LAMBDA",
                              text: LiveTheme.text(LiveTheme.lambdaValue(context.state.lambda), "%.3f"),
                              color: LiveTheme.lambda(context.state.lambda), size: 24)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveValue(title: "ÖLTEMP °C", text: LiveTheme.text(context.state.oilT, "%.0f"),
                              color: LiveTheme.oilT(context.state.oilT), size: 24)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        HStack {
                            LiveValue(title: "ÖLDRUCK", text: LiveTheme.text(context.state.oilP, "%.1f"),
                                      color: LiveTheme.oilP(context.state.oilP), size: 18)
                            Spacer()
                            LiveValue(title: "U/MIN", text: LiveTheme.text(context.state.rpm, "%.0f"), size: 18)
                            Spacer()
                            LiveValue(title: "KM/H", text: LiveTheme.text(context.state.speed, "%.0f"), size: 18)
                        }
                        if let a = context.state.alert {
                            Text(a)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(LiveTheme.crit)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Text(LiveTheme.text(LiveTheme.lambdaValue(context.state.lambda), "%.2f"))
                    .font(.system(size: 15, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundColor(LiveTheme.lambda(context.state.lambda))
            } compactTrailing: {
                Text(LiveTheme.text(context.state.oilT, "%.0f") + "°")
                    .font(.system(size: 15, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundColor(context.state.alert == nil ? LiveTheme.oilT(context.state.oilT) : LiveTheme.crit)
            } minimal: {
                Text("λ")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(context.state.alert == nil ? LiveTheme.lambda(context.state.lambda) : LiveTheme.crit)
            }
        }
    }
}
