import SwiftUI

extension ToolMeta {
    /// The span an agent is deliberately sitting out, from the hub's epoch-ms stamps.
    var waitRange: ClosedRange<Date>? {
        guard let s = waitSince, let u = waitUntil, u > s else { return nil }
        return Date(timeIntervalSince1970: s / 1000)...Date(timeIntervalSince1970: u / 1000)
    }
}

/// An agent paused on a timer, drawn as a tool row: a draining ring, the reason, and the time left.
struct WaitCard: View {
    var item: Item
    var range: ClosedRange<Date>

    private var total: TimeInterval { range.upperBound.timeIntervalSince(range.lowerBound) }

    /// The hub's label is a full sentence for the lock screen; next to "Waiting" it only needs the reason.
    private var reason: String {
        let l = item.tool?.meta?.waitLabel ?? "Timer"
        for p in ["Waiting for ", "Waiting on a ", "Waiting on "] where l.hasPrefix(p) { return String(l.dropFirst(p.count)) }
        return l
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, range.upperBound.timeIntervalSince(ctx.date))
            let done = left <= 0
            HStack(spacing: 8) {
                ZStack {
                    if done {
                        Image(systemName: "hourglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(BUI.ink3)
                            .transition(.opacity)
                    } else {
                        DrainRing(fraction: left / total)
                            .transition(.opacity)
                    }
                }
                .frame(width: 16, height: 16)

                Group {
                    if done { Text("Waited").font(.inter(13, .medium)).foregroundStyle(BUI.ink) }
                    else { ShimmerText(text: "Waiting", font: .inter(13, .medium)) }
                }
                .fixedSize()

                HStack(spacing: 6) {
                    Text(reason)
                        .font(.inter(11.5))
                        .foregroundStyle(BUI.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(done ? WaitCard.span(total) : WaitCard.clock(left))
                        .font(.jbMono(11.5, .medium)).monospacedDigit()
                        .foregroundStyle(done ? BUI.ink3 : BUI.accentInk)
                        .contentTransition(.numericText(countsDown: true))
                }
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(BUI.field, in: RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous))
                .elevation(.hairline, radius: BUI.Radius.chip)
            }
            .frame(height: 30)
            .animation(BUI.easeOutFast, value: Int(left))
            .animation(BUI.easeOutStrong, value: done)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(done ? "Waited \(WaitCard.span(total))" : "Waiting, \(WaitCard.span(left)) left")
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func span(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s / 60 % 60)m"
    }
}

/// What's left of the wait, as an accent arc on a hairline track.
private struct DrainRing: View {
    var fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(BUI.lineStrong, lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(BUI.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(BUI.easeOutStrong, value: fraction)
        }
        .frame(width: 12, height: 12)
    }
}
