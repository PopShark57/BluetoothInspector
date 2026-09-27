import BluetoothInspectorKit
import OSLog

/// Mirrors activity-log events into the unified log so they can be followed
/// in Console.app (`subsystem:io.github.popshark57.BluetoothInspector`).
enum AppLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "BluetoothInspector"
    private static let activity = Logger(subsystem: subsystem, category: "Activity")

    @MainActor
    static func mirror(_ event: ActivityEvent) {
        let tag = event.category.tag
        let device = event.deviceName ?? event.deviceID?.identifierString ?? "-"
        // Device names and payloads can be personal data; keep them private in the system log.
        if event.category == .error {
            activity.error("\(tag, privacy: .public) [\(device, privacy: .private)] \(event.message, privacy: .private)")
        } else {
            activity.debug("\(tag, privacy: .public) [\(device, privacy: .private)] \(event.message, privacy: .private)")
        }
    }
}
