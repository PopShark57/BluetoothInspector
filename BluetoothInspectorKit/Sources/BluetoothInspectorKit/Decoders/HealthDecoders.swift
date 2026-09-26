import Foundation

/// Heart Rate, Battery, Blood Pressure, Pulse Oximeter, Health Thermometer,
/// Glucose and Weight Scale characteristic decoders.
enum HealthDecoders {
    static let all: [any PayloadDecoder] = [
        heartRateMeasurement, bodySensorLocation, batteryLevel, bloodPressureMeasurement,
        plxContinuous, plxSpotCheck, temperatureMeasurement, temperatureType, glucoseMeasurement,
        weightMeasurement,
    ]

    /// 0x2A37 Heart Rate Measurement (HRS §3.1).
    static let heartRateMeasurement = ClosureDecoder(name: "Heart Rate Measurement", uuids: [0x2A37]) { data in
        var reader = ByteReader(data)
        guard let flags = reader.readUInt8() else { return nil }
        let is16Bit = flags & 0x01 != 0
        guard let bpm = is16Bit ? reader.readUInt16().map(Int.init) : reader.readUInt8().map(Int.init) else { return nil }
        var fields: [DecodedValue.Field] = [.init("Heart Rate", "\(bpm) BPM"), .init("Format", is16Bit ? "UINT16" : "UINT8")]
        let contact: String
        switch (flags >> 1) & 0x03 {
        case 2: contact = "Supported, not detected"
        case 3: contact = "Supported, detected"
        default: contact = "Not supported"
        }
        fields.append(.init("Sensor Contact", contact))
        if flags & 0x08 != 0 {
            guard let energy = reader.readUInt16() else { return nil }
            fields.append(.init("Energy Expended", "\(energy) kJ"))
        }
        if flags & 0x10 != 0 {
            var intervals: [String] = []
            while let rr = reader.readUInt16() {
                intervals.append(String(format: "%.0f ms", Double(rr) / 1024.0 * 1000.0))
            }
            fields.append(.init("RR Intervals", intervals.isEmpty ? "none" : intervals.joined(separator: ", ")))
        }
        return DecodedValue(summary: "Heart Rate: \(bpm) BPM", fields: fields, decoder: "Heart Rate Measurement")
    }

    static let bodySensorLocation = ClosureDecoder(name: "Body Sensor Location", uuids: [0x2A38]) { data in
        guard let value = data.first else { return nil }
        let names = ["Other", "Chest", "Wrist", "Finger", "Hand", "Ear Lobe", "Foot"]
        let name = names[safe: Int(value)] ?? "Reserved (\(value))"
        return DecodedValue(summary: "Body Sensor Location: \(name)", decoder: "Body Sensor Location")
    }

    /// 0x2A19 Battery Level: uint8 percentage.
    static let batteryLevel = ClosureDecoder(name: "Battery Level", uuids: [0x2A19]) { data in
        guard data.count == 1, let level = data.first else { return nil }
        let note = level > 100 ? " (out of range)" : ""
        return DecodedValue(summary: "Battery Level: \(level)%\(note)", decoder: "Battery Level")
    }

    /// 0x2A35 Blood Pressure Measurement (BLS §3.1), IEEE-11073 SFLOAT values.
    static let bloodPressureMeasurement = ClosureDecoder(name: "Blood Pressure Measurement", uuids: [0x2A35, 0x2A36]) { data in
        var reader = ByteReader(data)
        guard let flags = reader.readUInt8(), let systolic = reader.readSFloat(),
              let diastolic = reader.readSFloat(), let mean = reader.readSFloat() else { return nil }
        let unit = flags & 0x01 != 0 ? "kPa" : "mmHg"
        var fields: [DecodedValue.Field] = [
            .init("Systolic", "\(systolic) \(unit)"),
            .init("Diastolic", "\(diastolic) \(unit)"),
            .init("Mean Arterial Pressure", "\(mean) \(unit)"),
        ]
        if flags & 0x02 != 0 {
            guard let stamp = DecodeFormat.dateTime(&reader) else { return nil }
            fields.append(.init("Time Stamp", stamp))
        }
        if flags & 0x04 != 0, let pulse = reader.readSFloat() {
            fields.append(.init("Pulse Rate", "\(pulse) BPM"))
        }
        if flags & 0x08 != 0, let user = reader.readUInt8() {
            fields.append(.init("User ID", user == 0xFF ? "Unknown user" : "\(user)"))
        }
        if flags & 0x10 != 0, let status = reader.readUInt16() {
            let names = [0: "Body movement detected", 1: "Cuff too loose", 2: "Irregular pulse detected",
                         5: "Improper measurement position"]
            var issues = DecodeFormat.flags(UInt64(status), names: names)
            switch (status >> 3) & 0x03 {
            case 1: issues.append("Pulse rate exceeds upper limit")
            case 2: issues.append("Pulse rate below lower limit")
            default: break
            }
            fields.append(.init("Measurement Status", issues.isEmpty ? "OK" : issues.joined(separator: ", ")))
        }
        return DecodedValue(summary: "Blood Pressure: \(systolic)/\(diastolic) \(unit)", fields: fields, decoder: "Blood Pressure Measurement")
    }

    /// 0x2A5F PLX Continuous Measurement (PLXS §3.2).
    static let plxContinuous = ClosureDecoder(name: "PLX Continuous Measurement", uuids: [0x2A5F]) { data in
        var reader = ByteReader(data)
        guard let flags = reader.readUInt8(), let spo2 = reader.readSFloat(), let pulse = reader.readSFloat() else { return nil }
        var fields: [DecodedValue.Field] = [.init("SpO₂", "\(spo2) %"), .init("Pulse Rate", "\(pulse) BPM")]
        if flags & 0x01 != 0, let fast = reader.readSFloat(), let fastPR = reader.readSFloat() {
            fields.append(.init("SpO₂/PR Fast", "\(fast) % / \(fastPR) BPM"))
        }
        if flags & 0x02 != 0, let slow = reader.readSFloat(), let slowPR = reader.readSFloat() {
            fields.append(.init("SpO₂/PR Slow", "\(slow) % / \(slowPR) BPM"))
        }
        if flags & 0x04 != 0, let status = reader.readUInt16() {
            fields.append(.init("Measurement Status", DecodeFormat.hex16(status)))
        }
        if flags & 0x08 != 0, let status = reader.readUInt24() {
            fields.append(.init("Device & Sensor Status", String(format: "0x%06X", status)))
        }
        if flags & 0x10 != 0, let pai = reader.readSFloat() {
            fields.append(.init("Pulse Amplitude Index", "\(pai) %"))
        }
        return DecodedValue(summary: "SpO₂: \(spo2)%, Pulse: \(pulse) BPM", fields: fields, decoder: "PLX Continuous Measurement")
    }

    /// 0x2A5E PLX Spot-Check Measurement (PLXS §3.1).
    static let plxSpotCheck = ClosureDecoder(name: "PLX Spot-Check Measurement", uuids: [0x2A5E]) { data in
        var reader = ByteReader(data)
        guard let flags = reader.readUInt8(), let spo2 = reader.readSFloat(), let pulse = reader.readSFloat() else { return nil }
        var fields: [DecodedValue.Field] = [.init("SpO₂", "\(spo2) %"), .init("Pulse Rate", "\(pulse) BPM")]
        if flags & 0x01 != 0, let stamp = DecodeFormat.dateTime(&reader) {
            fields.append(.init("Time Stamp", stamp))
        }
        return DecodedValue(summary: "SpO₂: \(spo2)%, Pulse: \(pulse) BPM", fields: fields, decoder: "PLX Spot-Check Measurement")
    }

    static let temperatureTypes = ["Reserved", "Armpit", "Body (general)", "Ear", "Finger", "Gastrointestinal tract",
                                   "Mouth", "Rectum", "Toe", "Tympanum (ear drum)"]

    /// 0x2A1C Temperature Measurement / 0x2A1E Intermediate Temperature (HTS §3.1).
    static let temperatureMeasurement = ClosureDecoder(name: "Temperature Measurement", uuids: [0x2A1C, 0x2A1E]) { data in
        var reader = ByteReader(data)
        guard let flags = reader.readUInt8(), let value = reader.readFloat32() else { return nil }
        let unit = flags & 0x01 != 0 ? "°F" : "°C"
        var fields: [DecodedValue.Field] = [.init("Temperature", "\(value) \(unit)")]
        if flags & 0x02 != 0, let stamp = DecodeFormat.dateTime(&reader) {
            fields.append(.init("Time Stamp", stamp))
        }
        if flags & 0x04 != 0, let type = reader.readUInt8() {
            fields.append(.init("Temperature Type", temperatureTypes[safe: Int(type)] ?? "Reserved (\(type))"))
        }
        return DecodedValue(summary: "Temperature: \(value) \(unit)", fields: fields, decoder: "Temperature Measurement")
    }

    static let temperatureType = ClosureDecoder(name: "Temperature Type", uuids: [0x2A1D]) { data in
        guard let type = data.first else { return nil }
        return DecodedValue(summary: "Temperature Type: \(temperatureTypes[safe: Int(type)] ?? "Reserved (\(type))")", decoder: "Temperature Type")
    }

    /// 0x2A18 Glucose Measurement (GLS §3.1).
    static let glucoseMeasurement = ClosureDecoder(name: "Glucose Measurement", uuids: [0x2A18]) { data in
        var reader = ByteReader(data)
        guard let flags = reader.readUInt8(), let sequence = reader.readUInt16(),
              let baseTime = DecodeFormat.dateTime(&reader) else { return nil }
        var fields: [DecodedValue.Field] = [.init("Sequence Number", "\(sequence)"), .init("Base Time", baseTime)]
        if flags & 0x01 != 0, let offset = reader.readInt16() {
            fields.append(.init("Time Offset", "\(offset) min"))
        }
        var summary = "Glucose record #\(sequence)"
        if flags & 0x02 != 0, let concentration = reader.readSFloat(), let typeLocation = reader.readUInt8() {
            // kg/L and mol/L are the specification's base units; convert to the
            // units clinicians read (mg/dL, mmol/L).
            let text: String
            if flags & 0x04 != 0 {
                text = concentration.doubleValue.map { DecodeFormat.number($0 * 1000, decimals: 1) + " mmol/L" } ?? "\(concentration)"
            } else {
                text = concentration.doubleValue.map { DecodeFormat.number($0 * 100_000, decimals: 0) + " mg/dL" } ?? "\(concentration)"
            }
            fields.append(.init("Concentration", text))
            fields.append(.init("Type / Sample Location", String(format: "type %d, location %d", typeLocation & 0x0F, typeLocation >> 4)))
            summary = "Glucose: \(text)"
        }
        return DecodedValue(summary: summary, fields: fields, decoder: "Glucose Measurement")
    }

    /// 0x2A9D Weight Measurement (WSS §3.1).
    static let weightMeasurement = ClosureDecoder(name: "Weight Measurement", uuids: [0x2A9D]) { data in
        var reader = ByteReader(data)
        guard let flags = reader.readUInt8(), let raw = reader.readUInt16() else { return nil }
        let imperial = flags & 0x01 != 0
        let weight = raw == 0xFFFF ? "Measurement unsuccessful"
            : imperial ? DecodeFormat.number(Double(raw) * 0.01, decimals: 2) + " lb"
            : DecodeFormat.number(Double(raw) * 0.005, decimals: 3) + " kg"
        var fields: [DecodedValue.Field] = [.init("Weight", weight)]
        if flags & 0x02 != 0, let stamp = DecodeFormat.dateTime(&reader) {
            fields.append(.init("Time Stamp", stamp))
        }
        if flags & 0x04 != 0, let user = reader.readUInt8() {
            fields.append(.init("User ID", user == 0xFF ? "Unknown user" : "\(user)"))
        }
        if flags & 0x08 != 0, let bmi = reader.readUInt16(), let height = reader.readUInt16() {
            fields.append(.init("BMI", DecodeFormat.number(Double(bmi) * 0.1, decimals: 1)))
            fields.append(.init("Height", imperial ? DecodeFormat.number(Double(height) * 0.1, decimals: 1) + " in"
                                                   : DecodeFormat.number(Double(height) * 0.001, decimals: 3) + " m"))
        }
        return DecodedValue(summary: "Weight: \(weight)", fields: fields, decoder: "Weight Measurement")
    }
}
