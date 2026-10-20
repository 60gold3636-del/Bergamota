import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", log = "Live Log", ci = "CI", boot = "Boot Queue", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .log: "text.alignleft"
        case .ci: "hammer"
        case .boot: "bolt.horizontal.circle"
        case .settings: "gearshape"
        }
    }
}

func stateColor(_ s: PhoneState) -> Color {
    switch s {
    case .ios: .green
    case .fastboot: .orange
    case .recovery: .purple
    case .android: .teal
    case .iosBooting: .yellow
    case .offline: .gray
    case .unknown: .secondary
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .badge(item == .boot ? model.queue.pending.count : 0)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Circle().fill(stateColor(model.monitor.state)).frame(width: 10, height: 10)
                    Text(model.monitor.state.title).font(.callout)
                    Spacer()
                }
                .padding(12)
            }
        } detail: {
            switch selection ?? .dashboard {
            case .dashboard: DashboardView()
            case .log: LogView()
            case .ci: CIView()
            case .boot: BootView()
            case .settings: SettingsView()
            }
        }
    }
}
