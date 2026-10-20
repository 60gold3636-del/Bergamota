import SwiftUI

@main
struct BergamotaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Bergamota") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .task { model.start() }
        }
        .defaultSize(width: 1180, height: 760)
        Settings {
            SettingsView().environment(model).frame(width: 560)
        }
    }
}
