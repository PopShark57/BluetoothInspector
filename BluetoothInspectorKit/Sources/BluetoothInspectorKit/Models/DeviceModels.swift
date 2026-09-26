import Foundation

/// Stable identity for a device across BLE and Classic.
///
/// CoreBluetooth never exposes a BLE device's Bluetooth address; it hands out a
/// per-Mac UUID instead (which also changes when a device uses a resolvable
/// private address the Mac has not bonded with). IOBluetooth, by contrast,
/// identifies Classic devices by their public BD_ADDR. The two namespaces can
/// not be joined through any public API, so they are kept distinct.
public enum DeviceID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    case lowEnergy(UUID)
    case classic(address: String)

    public var rawValue: String {
        switch self {
        case .lowEnergy(let uuid): "ble:\(uuid.uuidString)"
        case .classic(let address): "classic:\(address)"
        }
    }

    public init?(rawValue: String) {
        if rawValue.hasPrefix("ble:"), let uuid = UUID(uuidString: String(rawValue.dropFirst(4))) {
            self = .lowEnergy(uuid)
        } else if rawValue.hasPrefix("classic:") {
            self = .classic(address: String(rawValue.dropFirst(8)))
        } else {
            return nil
        }
    }

    /// The identifier a developer would copy: the CoreBluetooth UUID or the BD_ADDR.
    public var identifierString: String {
        switch self {
        case .lowEnergy(let uuid): uuid.uuidString
        case .classic(let address): address
        }
    }

    public var transport: BluetoothTransport {
        switch self {
        case .lowEnergy: .lowEnergy
        case .classic: .classic
        }
    }

    public var description: String { rawValue }

    public static func < (lhs: DeviceID, rhs: DeviceID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = DeviceID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid device id \(raw)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum BluetoothTransport: String, Codable, Sendable, CaseIterable, Identifiable {
    case lowEnergy
    case classic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lowEnergy: "BLE"
        case .classic: "Classic"
        }
    }

    public var longTitle: String {
        switch self {
        case .lowEnergy: "Bluetooth Low Energy"
        case .classic: "Bluetooth Classic (BR/EDR)"
        }
    }
}

/// How confident we are that a device is dual-mode.
///
/// macOS offers no API that links a CoreBluetooth peripheral to an IOBluetooth
/// device, and CoreBluetooth hides the AD Flags field that would say whether a
/// peripheral also supports BR/EDR. Dual-mode is therefore only ever a
/// *heuristic* in this app and is labelled as such.
public enum DualModeHint: String, Codable, Sendable {
    case none
    /// A BLE peripheral and a Classic device report the same non-empty name.
    case matchingName

    public var explanation: String {
        switch self {
        case .none: "No dual-mode evidence"
        case .matchingName: "Possibly dual-mode: a BLE peripheral and a Classic device share this name (heuristic, not verified)"
        }
    }
}

public enum ConnectionState: String, Codable, Sendable, CaseIterable {
    case disconnected
    case connecting
    case connected
    case disconnecting

    public var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting…"
        }
    }

    public var isActive: Bool { self == .connected || self == .connecting }
}

/// Central manager power state, mirroring `CBManagerState` without importing CoreBluetooth.
public enum BluetoothPowerState: String, Codable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    public var title: String {
        switch self {
        case .unknown: "Unknown"
        case .resetting: "Resetting"
        case .unsupported: "Unsupported"
        case .unauthorized: "Unauthorized"
        case .poweredOff: "Powered Off"
        case .poweredOn: "Powered On"
        }
    }

    /// What the user can do about the state, or nil when everything is fine.
    public var guidance: String? {
        switch self {
        case .unknown: "Waiting for the Bluetooth system to report its state."
        case .resetting: "The Bluetooth system is restarting. Scanning resumes when it is back."
        case .unsupported: "This Mac does not support Bluetooth Low Energy central mode."
        case .unauthorized: "Bluetooth access was denied. Allow Bluetooth Inspector in System Settings › Privacy & Security › Bluetooth."
        case .poweredOff: "Bluetooth is turned off. Turn it on in Control Center or System Settings › Bluetooth."
        case .poweredOn: nil
        }
    }
}

/// App-level Bluetooth privacy authorization, mirroring `CBManagerAuthorization`.
public enum BluetoothAuthorization: String, Codable, Sendable {
    case notDetermined
    case restricted
    case denied
    case allowedAlways

    public var title: String {
        switch self {
        case .notDetermined: "Not Determined"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .allowedAlways: "Allowed"
        }
    }
}

public enum ScannerState: String, Codable, Sendable {
    case idle
    case scanning
    case unavailable

    public var title: String {
        switch self {
        case .idle: "Idle"
        case .scanning: "Scanning"
        case .unavailable: "Unavailable"
        }
    }
}

/// One RSSI reading. CoreBluetooth reports 127 when RSSI is unavailable; such
/// readings never become samples.
public struct RSSISample: Hashable, Codable, Sendable {
    public let timestamp: Date
    public let value: Int

    public init(timestamp: Date, value: Int) {
        self.timestamp = timestamp
        self.value = value
    }

    public static func isValid(_ value: Int) -> Bool {
        value != 127 && (-127...20).contains(value)
    }
}
