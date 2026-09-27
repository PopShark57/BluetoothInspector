import BluetoothInspectorKit
import CoreBluetooth
import Foundation

/// Conversions between CoreBluetooth types and the hardware-independent Kit models.
enum CoreBluetoothMapping {
    static func uuid(_ cbuuid: CBUUID) -> BluetoothUUID? {
        // CBUUID.uuidString is "180D" for SIG UUIDs and the full form otherwise.
        BluetoothUUID(string: cbuuid.uuidString) ?? BluetoothUUID(bytes: [UInt8](cbuuid.data), bigEndian: true)
    }

    static func cbuuid(_ uuid: BluetoothUUID) -> CBUUID {
        CBUUID(string: uuid.shortString)
    }

    static func powerState(_ state: CBManagerState) -> BluetoothPowerState {
        switch state {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .resetting: .resetting
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    static func authorization(_ authorization: CBManagerAuthorization) -> BluetoothAuthorization {
        switch authorization {
        case .allowedAlways: .allowedAlways
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    /// Parses the advertisement dictionary CoreBluetooth hands to
    /// `centralManager(_:didDiscover:advertisementData:rssi:)`.
    static func advertisement(_ dictionary: [String: Any]) -> AdvertisementData {
        func uuids(_ key: String) -> [BluetoothUUID] {
            (dictionary[key] as? [CBUUID])?.compactMap(uuid) ?? []
        }
        let serviceData = (dictionary[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?
            .compactMap { key, value in uuid(key).map { ServiceDataEntry(uuid: $0, data: value) } } ?? []
        return AdvertisementData(
            localName: dictionary[CBAdvertisementDataLocalNameKey] as? String,
            serviceUUIDs: uuids(CBAdvertisementDataServiceUUIDsKey),
            overflowServiceUUIDs: uuids(CBAdvertisementDataOverflowServiceUUIDsKey),
            solicitedServiceUUIDs: uuids(CBAdvertisementDataSolicitedServiceUUIDsKey),
            manufacturerData: dictionary[CBAdvertisementDataManufacturerDataKey] as? Data,
            serviceData: serviceData,
            txPowerLevel: (dictionary[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue,
            isConnectable: (dictionary[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        )
    }

    /// CoreBluetooth converts some descriptor values to Foundation types:
    /// NSNumber for Extended Properties / CCCD / SCCD (0x2900, 0x2902, 0x2903),
    /// NSString for User Description (0x2901), NSData for everything else.
    /// Normalize them back to little-endian bytes so they decode uniformly.
    static func descriptorValue(_ value: Any?) -> DescriptorValue? {
        switch value {
        case let data as Data:
            return DescriptorValue(data: data, displayText: data.isEmpty ? "(empty)" : data.hexString)
        case let string as String:
            return DescriptorValue(data: Data(string.utf8), displayText: string)
        case let number as NSNumber:
            let raw = number.uint16Value
            return DescriptorValue(data: Data([UInt8(raw & 0xFF), UInt8(raw >> 8)]), displayText: number.stringValue)
        default:
            return nil
        }
    }

    /// Error text that explains the likely cause, not just the code.
    static func describe(_ error: (any Error)?) -> String? {
        guard let error else { return nil }
        let nsError = error as NSError
        if nsError.domain == CBATTErrorDomain, let code = CBATTError.Code(rawValue: nsError.code) {
            return attDescription(code) + " (ATT error 0x\(String(format: "%02X", nsError.code)))"
        }
        if nsError.domain == CBErrorDomain, let code = CBError.Code(rawValue: nsError.code) {
            return cbDescription(code, fallback: nsError.localizedDescription)
        }
        return nsError.localizedDescription
    }

    private static func attDescription(_ code: CBATTError.Code) -> String {
        switch code {
        case .invalidHandle: "Invalid attribute handle"
        case .readNotPermitted: "The peripheral does not permit reading this attribute"
        case .writeNotPermitted: "The peripheral does not permit writing this attribute"
        case .invalidPdu: "The peripheral rejected the request as malformed"
        case .insufficientAuthentication: "Insufficient authentication. The attribute requires pairing; macOS normally shows a pairing prompt"
        case .requestNotSupported: "The peripheral does not support this request"
        case .invalidOffset: "Invalid offset for this attribute"
        case .insufficientAuthorization: "Insufficient authorization"
        case .prepareQueueFull: "The peripheral's prepare-write queue is full"
        case .attributeNotFound: "Attribute not found"
        case .attributeNotLong: "Attribute is not a long attribute"
        case .insufficientEncryptionKeySize: "Insufficient encryption key size"
        case .invalidAttributeValueLength: "The value length is invalid for this attribute"
        case .unlikelyError: "The request failed for an unlikely reason (peripheral-specific)"
        case .insufficientEncryption: "Insufficient encryption. The link must be encrypted (paired) first"
        case .unsupportedGroupType: "Unsupported group type"
        case .insufficientResources: "The peripheral has insufficient resources"
        case .success: "Success"
        @unknown default: "ATT error"
        }
    }

    private static func cbDescription(_ code: CBError.Code, fallback: String) -> String {
        switch code {
        case .connectionTimeout: "The connection timed out (the device may have moved out of range)"
        case .peripheralDisconnected: "The peripheral disconnected"
        case .connectionFailed: "The connection failed. The device may not be connectable or accepts one central at a time"
        case .notConnected: "The peripheral is not connected"
        case .uuidNotAllowed: "macOS does not allow apps to access this UUID (reserved by the system)"
        case .encryptionTimedOut: "Encryption timed out (pairing may have been rejected)"
        case .peerRemovedPairingInformation: "The peripheral removed its pairing information. Remove the device in System Settings › Bluetooth and pair again"
        case .connectionLimitReached: "The system connection limit was reached"
        case .operationNotSupported: "The operation is not supported"
        case .tooManyLEPairedDevices: "Too many LE devices are paired"
        default: fallback
        }
    }
}
