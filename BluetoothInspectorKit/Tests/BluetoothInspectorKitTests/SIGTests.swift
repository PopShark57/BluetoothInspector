import Foundation
import Testing
@testable import BluetoothInspectorKit

@Suite("Bluetooth UUIDs and SIG names")
struct SIGTests {
    @Test func shortAndLongFormsAreEqual() throws {
        let short = try #require(BluetoothUUID(string: "180d"))
        let long = try #require(BluetoothUUID(string: "0000180D-0000-1000-8000-00805F9B34FB"))
        #expect(short == long)
        #expect(short == BluetoothUUID(uint16: 0x180D))
        #expect(short.shortString == "180D")
        #expect(short.assignedNumber == 0x180D)
        #expect(BluetoothUUID(string: "0x2A37")?.shortString == "2A37")
    }

    @Test func thirtyTwoBitAndVendorUUIDs() throws {
        let thirtyTwo = try #require(BluetoothUUID(string: "1234ABCD"))
        #expect(thirtyTwo.isSIGBased)
        #expect(thirtyTwo.assignedNumber == nil)
        #expect(thirtyTwo.shortString == "1234ABCD")
        let vendor = try #require(BluetoothUUID(string: "6e400001b5a3f393e0a9e50e24dcca9e"))
        #expect(vendor.uuidString == "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        #expect(vendor.sigName == "Nordic UART Service")
        #expect(!vendor.isSIGBased)
    }

    @Test func invalidUUIDs() {
        #expect(BluetoothUUID(string: "") == nil)
        #expect(BluetoothUUID(string: "18") == nil)
        #expect(BluetoothUUID(string: "XYZW") == nil)
    }

    @Test func bytesRespectEndianness() {
        #expect(BluetoothUUID(bytes: [0x0D, 0x18], bigEndian: false)?.shortString == "180D")
        #expect(BluetoothUUID(bytes: [0x11, 0x0B], bigEndian: true)?.shortString == "110B")
    }

    @Test func codableUsesShortForm() throws {
        let data = try JSONEncoder().encode([BluetoothUUID(uint16: 0x180F)])
        #expect(String(decoding: data, as: UTF8.self) == "[\"180F\"]")
        let decoded = try JSONDecoder().decode([BluetoothUUID].self, from: Data("[\"0000180f-0000-1000-8000-00805f9b34fb\"]".utf8))
        #expect(decoded == [BluetoothUUID(uint16: 0x180F)])
    }

    @Test(arguments: [
        (UInt16(0x180D), "Heart Rate"), (0x180F, "Battery Service"), (0x180A, "Device Information"),
        (0x1810, "Blood Pressure"), (0x1822, "Pulse Oximeter"), (0x181A, "Environmental Sensing"),
        (0x1812, "Human Interface Device"), (0x1816, "Cycling Speed and Cadence"), (0x1818, "Cycling Power"),
        (0x1814, "Running Speed and Cadence"), (0x1826, "Fitness Machine"),
    ])
    func serviceNames(_ value: UInt16, _ name: String) {
        #expect(AssignedNumbers.serviceName(BluetoothUUID(uint16: value)) == name)
    }

    @Test func characteristicAndDescriptorNames() {
        #expect(BluetoothUUID(uint16: 0x2A37).sigName == "Heart Rate Measurement")
        #expect(BluetoothUUID(uint16: 0x2A19).sigName == "Battery Level")
        #expect(BluetoothUUID(uint16: 0x2902).sigName == "Client Characteristic Configuration")
        #expect(BluetoothUUID(uint16: 0x2A37).displayName == "2A37 Heart Rate Measurement")
        #expect(AssignedNumbers.entry(for: BluetoothUUID(uint16: 0x2A37))?.kind == .characteristic)
        #expect(AssignedNumbers.entry(for: BluetoothUUID(uint16: 0x110B))?.kind == .serviceClass)
    }

    @Test func companyAndAppearance() {
        #expect(AssignedNumbers.companyName(0x004C) == "Apple, Inc.")
        #expect(AssignedNumbers.companyName(0x0059) == "Nordic Semiconductor ASA")
        #expect(AssignedNumbers.appearanceName(0x0341)?.contains("Heart Rate") == true)
    }

    @Test func runtimeExtensionAddsCompanies() throws {
        let json = #"{"companies": {"FFFE": "Test Vendor"}, "uuids": {"FFF0": "Test Service"}}"#
        let count = try AssignedNumbers.loadExtension(from: Data(json.utf8))
        #expect(count == 2)
        #expect(AssignedNumbers.companyName(0xFFFE) == "Test Vendor")
        #expect(AssignedNumbers.companyName(0x004C) == "Apple, Inc.")
    }

    @Test func classOfDevice() {
        // 0x240404: Audio + Rendering services, Audio/Video major, Wearable Headset minor.
        let cod = ClassOfDevice(rawValue: 0x24_0404)
        #expect(cod.majorName == "Audio/Video")
        #expect(cod.minorName == "Wearable Headset")
        #expect(cod.serviceClasses == ["Rendering", "Audio"])
        // Keyboard (peripheral, minor 0x10).
        let keyboard = ClassOfDevice(rawValue: 0x00_0540)
        #expect(keyboard.majorName == "Peripheral")
        #expect(keyboard.minorName == "Keyboard")
        // Imaging: printer bit.
        #expect(ClassOfDevice(rawValue: 0x00_0680).minorName == "Printer")
        // Smartphone.
        #expect(ClassOfDevice(rawValue: 0x5A_020C).minorName == "Smartphone")
    }
}
