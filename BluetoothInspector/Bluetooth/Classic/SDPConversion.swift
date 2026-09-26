import BluetoothInspectorKit
import Foundation
import IOBluetooth

/// Converts IOBluetooth SDP objects into Kit value types.
enum SDPConversion {
    // SDP data element type descriptors (Core Spec Vol 3 Part B §3.2).
    private enum ElementType: UInt8 {
        case null = 0
        case unsignedInteger = 1
        case signedInteger = 2
        case uuid = 3
        case text = 4
        case boolean = 5
        case sequence = 6
        case alternative = 7
        case url = 8
    }

    static func record(_ record: IOBluetoothSDPServiceRecord) -> SDPServiceRecord {
        var attributes: [SDPAttribute] = []
        if let dictionary = record.attributes {
            for (key, value) in dictionary {
                // Keys are NSNumber attribute IDs; they may arrive bridged to Int.
                let id = (key.base as? NSNumber)?.uint16Value ?? (key.base as? Int).map { UInt16(truncatingIfNeeded: $0) }
                guard let id, let element = value as? IOBluetoothSDPDataElement else { continue }
                attributes.append(SDPAttribute(id: id, value: self.element(element)))
            }
        }
        return SDPServiceRecord(attributes: attributes, serviceName: record.getServiceName())
    }

    static func element(_ element: IOBluetoothSDPDataElement, depth: Int = 0) -> SDPDataElement {
        // Malicious or broken records can nest deeply; SDP never needs this much.
        guard depth < 16 else { return .raw(Data(), typeDescriptor: 255) }
        let size = Int(element.getSize())
        switch ElementType(rawValue: element.getTypeDescriptor()) {
        case .null:
            return .null
        case .unsignedInteger:
            if size <= 8, let number = element.getNumberValue() {
                return .unsignedInteger(number.uint64Value, bytes: max(size, 1))
            }
            return .largeInteger(element.getDataValue() ?? Data(), signed: false)
        case .signedInteger:
            if size <= 8, let number = element.getNumberValue() {
                return .signedInteger(number.int64Value, bytes: max(size, 1))
            }
            return .largeInteger(element.getDataValue() ?? Data(), signed: true)
        case .uuid:
            // IOBluetoothSDPUUID is an NSData subclass holding big-endian bytes.
            if let sdpUUID = element.getUUIDValue(),
               let uuid = BluetoothUUID(bytes: [UInt8](Data(referencing: sdpUUID)), bigEndian: true) {
                return .uuid(uuid)
            }
            return .raw(element.getDataValue() ?? Data(), typeDescriptor: 3)
        case .text:
            if let string = element.getStringValue() { return .text(string) }
            return .raw(element.getDataValue() ?? Data(), typeDescriptor: 4)
        case .boolean:
            return .boolean(element.getNumberValue()?.boolValue ?? false)
        case .sequence:
            return .sequence(children(element, depth: depth))
        case .alternative:
            return .alternative(children(element, depth: depth))
        case .url:
            if let string = element.getStringValue() { return .url(string) }
            return .raw(element.getDataValue() ?? Data(), typeDescriptor: 8)
        case nil:
            return .raw(element.getDataValue() ?? Data(), typeDescriptor: element.getTypeDescriptor())
        }
    }

    private static func children(_ element: IOBluetoothSDPDataElement, depth: Int) -> [SDPDataElement] {
        let array = element.getArrayValue() ?? []
        return array.compactMap { item in
            (item as? IOBluetoothSDPDataElement).map { self.element($0, depth: depth + 1) }
        }
    }
}
