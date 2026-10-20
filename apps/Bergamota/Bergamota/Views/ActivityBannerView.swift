import SwiftUI

struct ActivityBannerView: View {
    @Environment(AppModel.self) private var model
    var big = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let b = model.activityBanner(now: ctx.date)
            let dark = [Color.yellow, .orange, .cyan, .green].contains(b.color)
            let fg: Color = dark ? .black : .white
            HStack(spacing: big ? 28 : 16) {
                Image(systemName: b.symbol).font(.system(size: big ? 84 : 34, weight: .bold))
                VStack(alignment: .leading, spacing: big ? 8 : 2) {
                    Text(b.title).font(.system(size: big ? 64 : 30, weight: .heavy, design: .rounded)).lineLimit(1).minimumScaleFactor(0.4)
                    if !b.subtitle.isEmpty {
                        Text(b.subtitle).font(.system(size: big ? 28 : 14, weight: .semibold)).lineLimit(2).opacity(0.85)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(fg)
            .padding(big ? 24 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(b.color.gradient, in: RoundedRectangle(cornerRadius: big ? 28 : 14))
            .modifier(StateFlash(key: b.title + "|\(b.color)", radius: big ? 28 : 14))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Flashes the banner (three white blinks and a small pulse) whenever the state changes, so a
/// change is noticed from across the room. Elapsed-time updates in the subtitle don't count.
private struct StateFlash: ViewModifier {
    let key: String
    let radius: CGFloat
    @State private var flash = 0.0
    @State private var pulse = 1.0
    @State private var seen: String?

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: radius).fill(.white).opacity(flash).allowsHitTesting(false))
            .scaleEffect(pulse)
            .onAppear { seen = key }
            .onChange(of: key) { _, new in
                guard seen != nil, seen != new else { seen = new; return }
                seen = new
                Task { @MainActor in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { pulse = 1.03 }
                    for _ in 0..<3 {
                        withAnimation(.easeOut(duration: 0.08)) { flash = 0.85 }
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        withAnimation(.easeIn(duration: 0.25)) { flash = 0 }
                        try? await Task.sleep(nanoseconds: 260_000_000)
                    }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { pulse = 1 }
                }
            }
    }
}
