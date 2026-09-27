import Foundation
import Testing
@testable import BluetoothInspectorKit

@Suite("Characteristic decoders")
struct DecoderTests {
    let registry = DecoderRegistry.standard

    func decode(_ uuid: UInt16, _ bytes: [UInt8]) -> DecodedValue? {
        registry.decode(characteristic: BluetoothUUID(uint16: uuid), data: Data(bytes))
    }

    func field(_ value: DecodedValue?, _ name: String) -> String? {
        value?.fields.first { $0.name == name }?.value
    }

    @Test func heartRateUInt8() {
        let value = decode(0x2A37, [0x00, 0x48])
        #expect(value?.summary == "Heart Rate: 72 BPM")
        #expect(field(value, "Sensor Contact") == "Not supported")
    }

    @Test func heartRateUInt16WithEnergyAndRR() {
        // flags: 16-bit HR, contact detected (0b110), energy present, RR present.
        let value = decode(0x2A37, [0x1F, 0x2C, 0x01, 0x10, 0x00, 0x00, 0x04, 0x00, 0x02])
        #expect(value?.summary == "Heart Rate: 300 BPM")
        #expect(field(value, "Sensor Contact") == "Supported, detected")
        #expect(field(value, "Energy Expended") == "16 kJ")
        #expect(field(value, "RR Intervals") == "1000 ms, 500 ms")
    }

    @Test func heartRateTruncated() {
        #expect(decode(0x2A37, [0x01, 0x48]) == nil)
        #expect(decode(0x2A37, []) == nil)
    }

    @Test func batteryLevel() {
        #expect(decode(0x2A19, [0x55])?.summary == "Battery Level: 85%")
        #expect(decode(0x2A19, [0x55, 0x00]) == nil)
    }

    @Test func bloodPressureWithPulse() {
        // mmHg, pulse present: 120/80 mean 93, pulse 70.
        let value = decode(0x2A35, [0x04, 0x78, 0x00, 0x50, 0x00, 0x5D, 0x00, 0x46, 0x00])
        #expect(value?.summary == "Blood Pressure: 120/80 mmHg")
        #expect(field(value, "Pulse Rate") == "70 BPM")
    }

    @Test func plxContinuous() {
        let value = decode(0x2A5F, [0x00, 0x62, 0x00, 0x48, 0x00])
        #expect(value?.summary == "SpO₂: 98%, Pulse: 72 BPM")
    }

    @Test func healthThermometerFahrenheitWithType() {
        // flags: °F + type present; FLOAT 986 × 10^-1 = 98.6; type 6 (mouth).
        let value = decode(0x2A1C, [0x05, 0xDA, 0x03, 0x00, 0xFF, 0x06])
        #expect(value?.summary == "Temperature: 98.6 °F")
        #expect(field(value, "Temperature Type") == "Mouth")
    }

    @Test func environmentalSensing() {
        #expect(decode(0x2A6E, [0x4A, 0x09])?.summary == "Temperature: 23.78 °C")
        #expect(decode(0x2A6E, [0x00, 0x80])?.summary == "Temperature: unknown")
        #expect(decode(0x2A6F, [0x88, 0x13])?.summary == "Humidity: 50.00 %")
    }

    @Test func pressureConversion() {
        // 1013.25 hPa = 101325 Pa = 1013250 (0.1 Pa units) = 0x000F7602
        #expect(decode(0x2A6D, [0x02, 0x76, 0x0F, 0x00])?.summary == "Pressure: 1013.25 hPa")
    }

    @Test func cyclingSpeedAndCadence() {
        let value = decode(0x2A5B, [0x03, 0x10, 0x00, 0x00, 0x00, 0x00, 0x04, 0x05, 0x00, 0x00, 0x08])
        #expect(value?.summary == "CSC: wheel 16, crank 5")
        #expect(field(value, "Last Wheel Event Time") == "1.000 s")
        #expect(field(value, "Last Crank Event Time") == "2.000 s")
    }

    @Test func cyclingPowerWithBalance() {
        // flags 0x0001 (balance present), 250 W, balance 100 (= 50 %).
        let value = decode(0x2A63, [0x01, 0x00, 0xFA, 0x00, 0x64])
        #expect(value?.summary == "Power: 250 W")
        #expect(field(value, "Pedal Power Balance") == "50.0 % (unknown)")
    }

    @Test func runningSpeedAndCadence() {
        // flags: running + stride; 3 m/s = 768/256; cadence 170; stride 1.20 m.
        let value = decode(0x2A53, [0x05, 0x00, 0x03, 0xAA, 0x78, 0x00])
        #expect(value?.summary == "RSC: 3.00 m/s, 170 spm")
        #expect(field(value, "Activity") == "Running")
        #expect(field(value, "Stride Length") == "1.20 m")
    }

    @Test func indoorBikeData() {
        // flags: speed present (bit0 = 0), cadence (bit2), power (bit6) → 0x0044.
        let value = decode(0x2AD2, [0x44, 0x00, 0xC4, 0x09, 0xB4, 0x00, 0x96, 0x00])
        #expect(value?.summary == "Indoor Bike: 25.00 km/h, 90.0 rpm, 150 W")
    }

    @Test func fitnessMachineFeature() {
        let value = decode(0x2ACC, [0x03, 0x40, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00])
        #expect(field(value, "Machine Features") == "Average Speed, Cadence, Power Measurement")
        #expect(field(value, "Target Settings") == "Resistance, Power")
    }

    @Test func deviceInformationStrings() {
        #expect(decode(0x2A29, Array("Acme\0".utf8))?.summary == "“Acme”")
        #expect(decode(0x2A24, [0xFF, 0xFE]) == nil)
    }

    @Test func pnpID() {
        let value = decode(0x2A50, [0x01, 0x4C, 0x00, 0x0B, 0x20, 0x10, 0x01])
        #expect(value?.summary.contains("Apple, Inc.") == true)
        #expect(field(value, "Product Version")?.hasPrefix("1.1.0") == true)
    }

    @Test func appearance() {
        #expect(decode(0x2A01, [0x41, 0x03])?.summary.contains("Heart Rate") == true)
    }

    @Test func preferredConnectionParameters() {
        let value = decode(0x2A04, [0x06, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x90, 0x01])
        #expect(field(value, "Minimum Connection Interval") == "7.50 ms")
        #expect(field(value, "Supervision Timeout") == "4000 ms")
    }

    @Test func descriptors() {
        let cccd = registry.decode(descriptor: BluetoothUUID(uint16: 0x2902), data: Data([0x01, 0x00]))
        #expect(cccd?.summary == "Notifications enabled")
        let both = registry.decode(descriptor: BluetoothUUID(uint16: 0x2902), data: Data([0x03, 0x00]))
        #expect(both?.summary == "Notifications enabled, Indications enabled")
        let user = registry.decode(descriptor: BluetoothUUID(uint16: 0x2901), data: Data("Speed".utf8))
        #expect(user?.summary == "“Speed”")
    }

    @Test func presentationFormatDrivesVendorDecoding() throws {
        // sint16, exponent -2, °C (0x272F), namespace SIG.
        let format = try #require(PresentationFormat(data: Data([0x0E, 0xFE, 0x2F, 0x27, 0x01, 0x00, 0x00])))
        #expect(format.formatName == "sint16")
        let vendor = try #require(BluetoothUUID(string: "12345678-1234-1234-1234-123456789ABC"))
        let value = registry.decode(characteristic: vendor, data: Data([0x4A, 0x09]), presentationFormat: format)
        #expect(value?.summary == "23.78 °C")
    }

    @Test func customDecoderRegistration() {
        var custom = DecoderRegistry()
        custom.register(characteristic: ClosureDecoder(name: "Test", uuids: [0xFFF1]) { data in
            DecodedValue(summary: "len \(data.count)", decoder: "Test")
        })
        #expect(custom.decode(characteristic: BluetoothUUID(uint16: 0xFFF1), data: Data([1, 2]))?.summary == "len 2")
        #expect(custom.decode(characteristic: BluetoothUUID(uint16: 0x2A37), data: Data([0, 1])) == nil)
    }
}

@Suite("Advertisement decoding")
struct AdvertisementDecodingTests {
    @Test func iBeacon() throws {
        var payload: [UInt8] = [0x4C, 0x00, 0x02, 0x15]
        payload += [0xE2, 0xC5, 0x6D, 0xB5, 0xDF, 0xFB, 0x48, 0xD2, 0xB0, 0x60, 0xD0, 0xF5, 0xA7, 0x10, 0x96, 0xE0]
        payload += [0x00, 0x01, 0x00, 0x02, 0xC5]
        let manufacturer = try #require(ManufacturerData(data: Data(payload)))
        #expect(manufacturer.companyID == 0x004C)
        let decoded = try #require(manufacturer.vendorDecoded)
        #expect(decoded.summary == "iBeacon")
        #expect(decoded.fields.contains(.init("iBeacon UUID", "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")))
        #expect(decoded.fields.contains(.init("Major", "1")))
        #expect(decoded.fields.contains(.init("Minor", "2")))
        #expect(decoded.fields.contains(.init("Measured Power", "-59 dBm @ 1 m")))
    }

    @Test func unknownCompany() throws {
        let manufacturer = try #require(ManufacturerData(data: Data([0x34, 0x12, 0xAA])))
        #expect(manufacturer.companyDescription.contains("0x1234"))
        #expect(ManufacturerData(data: Data([0x01])) == nil)
    }

    @Test func eddystoneURL() {
        let data = Data([0x10, 0xEB, 0x03] + Array("example".utf8) + [0x07])
        let value = ServiceDataDecoder.decode(uuid: BluetoothUUID(uint16: 0xFEAA), data: data)
        #expect(value?.summary == "Eddystone-URL https://example.com")
    }

    @Test func eddystoneTLM() {
        let data = Data([0x20, 0x00, 0x0B, 0xB8, 0x19, 0x80, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x64])
        let value = ServiceDataDecoder.decode(uuid: BluetoothUUID(uint16: 0xFEAA), data: data)
        #expect(value?.fields.first { $0.name == "Battery" }?.value == "3000 mV")
        #expect(value?.fields.first { $0.name == "Temperature" }?.value == "25.50 °C")
    }

    @Test func mergingKeepsScanResponseFields() {
        let advertising = AdvertisementData(serviceUUIDs: [BluetoothUUID(uint16: 0x180D)], manufacturerData: Data([0x59, 0x00, 0x01]), isConnectable: true)
        let scanResponse = AdvertisementData(localName: "HRM", txPowerLevel: 4)
        let merged = advertising.merging(scanResponse)
        #expect(merged.localName == "HRM")
        #expect(merged.serviceUUIDs == [BluetoothUUID(uint16: 0x180D)])
        #expect(merged.txPowerLevel == 4)
        #expect(merged.isConnectable == true)
        #expect(merged.manufacturerData == Data([0x59, 0x00, 0x01]))
    }

    @Test func fieldsIncludeRawHex() {
        let advertisement = AdvertisementData(localName: "A", manufacturerData: Data([0x4C, 0x00, 0x10, 0x01, 0x00]), txPowerLevel: -8)
        let fields = advertisement.fields
        #expect(fields.first { $0.id == "name" }?.rawHex == "41")
        #expect(fields.first { $0.id == "tx" }?.rawHex == "F8")
        #expect(fields.first { $0.id == "mfr" }?.value.contains("Apple") == true)
    }
}
