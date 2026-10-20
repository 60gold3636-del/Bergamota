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
            .accessibilityElement(children: .combine)
        }
    }
}
