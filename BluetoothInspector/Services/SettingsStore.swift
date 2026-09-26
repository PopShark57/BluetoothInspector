import BluetoothInspectorKit
import Foundation

/// Persists `InspectorSettings` as JSON in UserDefaults.
struct SettingsStore {
    private let defaults: UserDefaults
    private let key = "InspectorSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> InspectorSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(InspectorSettings.self, from: data) else {
            return InspectorSettings()
        }
        return settings
    }

    func save(_ settings: InspectorSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
