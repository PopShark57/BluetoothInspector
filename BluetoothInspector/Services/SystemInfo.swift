import BluetoothInspectorKit
import Foundation

/// Facts about the running app and Mac for diagnostics and exports.
enum SystemInfo {
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var operatingSystem: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (\(ProcessInfo.processInfo.operatingSystemVersionString))"
    }

    static var hardwareModel: String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static var diagnosticsContext: DiagnosticsContext {
        DiagnosticsContext(appVersion: appVersion, operatingSystem: operatingSystem, hardwareModel: hardwareModel)
    }
}
