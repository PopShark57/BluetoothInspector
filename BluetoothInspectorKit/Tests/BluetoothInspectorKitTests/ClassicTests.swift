import Foundation
import Testing
@testable import BluetoothInspectorKit

@Suite("Bluetooth Classic models")
struct ClassicTests {
    /// A2DP sink record as a typical headphone reports it.
    static let audioSinkRecord = SDPServiceRecord(attributes: [
        SDPAttribute(id: 0x0000, value: .unsignedInteger(0x0001_0001, bytes: 4)),
        SDPAttribute(id: 0x0001, value: .sequence([.uuid(BluetoothUUID(uint16: 0x110B))])),
        SDPAttribute(id: 0x0004, value: .sequence([
            .sequence([.uuid(BluetoothUUID(uint16: 0x0100)), .unsignedInteger(0x0019, bytes: 2)]),
            .sequence([.uuid(BluetoothUUID(uint16: 0x0019)), .unsignedInteger(0x0103, bytes: 2)]),
        ])),
        SDPAttribute(id: 0x0009, value: .sequence([
            .sequence([.uuid(BluetoothUUID(uint16: 0x110D)), .unsignedInteger(0x0103, bytes: 2)]),
        ])),
        SDPAttribute(id: 0x0100, value: .text("Audio Sink")),
    ])

    static let serialPortRecord = SDPServiceRecord(attributes: [
        SDPAttribute(id: 0x0001, value: .sequence([.uuid(BluetoothUUID(uint16: 0x1101))])),
        SDPAttribute(id: 0x0004, value: .sequence([
            .sequence([.uuid(BluetoothUUID(uint16: 0x0100))]),
            .sequence([.uuid(BluetoothUUID(uint16: 0x0003)), .unsignedInteger(3, bytes: 1)]),
        ])),
    ])

    static let pnpRecord = SDPServiceRecord(attributes: [
        SDPAttribute(id: 0x0001, value: .sequence([.uuid(BluetoothUUID(uint16: 0x1200))])),
        SDPAttribute(id: 0x0200, value: .unsignedInteger(0x0103, bytes: 2)),
        SDPAttribute(id: 0x0201, value: .unsignedInteger(0x004C, bytes: 2)),
        SDPAttribute(id: 0x0202, value: .unsignedInteger(0x200E, bytes: 2)),
        SDPAttribute(id: 0x0203, value: .unsignedInteger(0x0120, bytes: 2)),
        SDPAttribute(id: 0x0205, value: .unsignedInteger(0x0001, bytes: 2)),
    ])

    @Test func sdpRecordAccessors() {
        let record = Self.audioSinkRecord
        #expect(record.serviceName == "Audio Sink")
        #expect(record.serviceClassIDs == [BluetoothUUID(uint16: 0x110B)])
        #expect(record.l2capPSM == 0x0019)
        #expect(record.rfcommChannel == nil)
        #expect(record.profiles.first?.version == "1.3")
        #expect(record.summary == "PSM 0x0019 · 110D Advanced Audio Distribution v1.3")
        #expect(record.id == "00010001")
    }

    @Test func rfcommChannel() {
        #expect(Self.serialPortRecord.rfcommChannel == 3)
        #expect(Self.serialPortRecord.title == "1101 Serial Port")
    }

    @Test func pnpInformation() throws {
        let pnp = try #require(Self.pnpRecord.pnpInformation)
        #expect(pnp.vendorName == "Apple, Inc.")
        #expect(pnp.productID == 0x200E)
        #expect(pnp.versionString == "1.2.0")
        #expect(SDPAttribute(id: 0x0201, value: .null).name(inPnPRecord: true) == "VendorID")
    }

    @Test func deviceInfoAggregates() {
        let info = ClassicDeviceInfo(address: "a4-83-e7-12-34-56", name: "Headphones",
                                     serviceRecords: [Self.audioSinkRecord, Self.pnpRecord], sources: [.paired])
        #expect(info.address == "A4:83:E7:12:34:56")
        #expect(info.oui == "A4:83:E7")
        #expect(info.pnpInformation?.vendorID == 0x004C)
        #expect(info.profileNames.contains("110B Audio Sink"))
    }

    @Test func mergingKeepsKnownFields() {
        let old = ClassicDeviceInfo(address: "00:11:22:33:44:55", name: "Speaker", classOfDevice: ClassOfDevice(rawValue: 0x240414),
                                    isPaired: true, serviceRecords: [Self.serialPortRecord], sources: [.paired])
        let inquiry = ClassicDeviceInfo(address: "00-11-22-33-44-55", isPaired: true, rssi: -60, sources: [.inquiry])
        let merged = old.merging(inquiry)
        #expect(merged.name == "Speaker")
        #expect(merged.classOfDevice == old.classOfDevice)
        #expect(merged.rssi == -60)
        #expect(merged.serviceRecords.count == 1)
        #expect(merged.sources == [.paired, .inquiry])
    }

    @Test func dataElementCodableRoundTrip() throws {
        let element = SDPDataElement.sequence([
            .uuid(BluetoothUUID(uint16: 0x1101)), .unsignedInteger(3, bytes: 1), .signedInteger(-5, bytes: 2),
            .text("Port"), .boolean(true), .url("http://x"), .null, .largeInteger(Data([1, 2]), signed: false),
            .alternative([.raw(Data([0xAB]), typeDescriptor: 9)]),
        ])
        let data = try JSONEncoder().encode(element)
        let decoded = try JSONDecoder().decode(SDPDataElement.self, from: data)
        #expect(decoded == element)
        #expect(element.render().contains("UInt8: 0x03 (3)"))
    }
}
