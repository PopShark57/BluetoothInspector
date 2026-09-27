import BluetoothInspectorKit
import SwiftUI

@main
struct BluetoothInspectorApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Bluetooth Inspector", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .defaultSize(width: 1380, height: 860)
        .commands {
            InspectorCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 560, height: 640)
        }
    }
}
