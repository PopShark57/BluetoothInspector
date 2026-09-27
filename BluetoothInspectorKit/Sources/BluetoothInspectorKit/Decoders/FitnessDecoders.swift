import Foundation

/// Cycling Speed and Cadence, Cycling Power, Running Speed and Cadence and
/// Fitness Machine decoders.
enum FitnessDecoders {
    static let all: [any PayloadDecoder] = [
        cscMeasurement, cscFeature, sensorLocation, cyclingPowerMeasurement, rscMeasurement,
        indoorBikeData, treadmillData, fitnessMachineFeature, trainingStatus, supportedSpeedRange,
        supportedPowerRange, supportedResistanceRange,
    ]

    /// 0x2A5B CSC Measurement (CSCS §3.1). Event times are in 1/1024 s.
    static let cscMeasurement = ClosureDecoder(name: "CSC Measurement", uuids: [0x2A5B]) { data in
        var reader = ByteReader(data)
        guard let flags = reader.readUInt8() else { return nil }
        var fields: [DecodedValue.Field] = []
        var parts: [String] = []
        if flags & 0x01 != 0 {
            guard let revolutions = reader.readUInt32(), let time = reader.readUInt16() else { return nil }
            fields.append(.init("Cumulative Wheel Revolutions", "\(revolutions)"))
            fields.append(.init("Last Wheel Event Time", DecodeFormat.number(Double(time) / 1024, decimals: 3) + " s"))
            parts.append("wheel \(revolutions)")
        }
        if flags & 0x02 != 0 {
            guard let revolutions = reader.readUInt16(), let time = reader.readUInt16() else { return nil }
            fields.append(.init("Cumulative Crank Revolutions", "\(revolutions)"))
            fields.append(.init("Last Crank Event Time", DecodeFormat.number(Double(time) / 1024, decimals: 3) + " s"))
            parts.append("crank \(revolutions)")
        }
        return DecodedValue(summary: "CSC: " + (parts.isEmpty ? "no data" : parts.joined(separator: ", ")),
                            fields: fields, decoder: "CSC Measurement")
    }

    static let cscFeature = ClosureDecoder(name: "CSC Feature", uuids: [0x2A5C]) { data in
        var reader = ByteReader(data)
        guard let bits = reader.readUInt16() else { return nil }
        let names = DecodeFormat.flags(UInt64(bits), names: [0: "Wheel Revolution Data", 1: "Crank Revolution Data", 2: "Multiple Sensor Locations"])
        return DecodedValue(summary: "CSC Features: " + (names.isEmpty ? "none" : names.joined(separator: ", ")), decoder: "CSC Feature")
    }

    static let sensorLocation = ClosureDecoder(name: "Sensor Location", uuids: [0x2A5D]) { data in
        guard let value = data.first else { return nil }
        let names = ["Other", "Top of shoe", "In shoe", "Hip", "Front Wheel", "Left Crank", "Right Crank",
                     "Left Pedal", "Right Pedal", "Front Hub", "Rear Dropout", "Chainstay", "Rear Wheel",
                     "Rear Hub", "Chest", "Spider", "Chain Ring"]
        return DecodedValue(summary: "Sensor Location: \(names[safe: Int(value)] ?? "Reserved (\(value))")", decoder: "Sensor Location")
    }

    /// 0x2A63 Cycling Power Measurement (CPS §3.2).
    static let cyclingPowerMeasurement = ClosureDecoder(name: "Cycling Power Measurement", uuids: [0x2A63]) { data in
        var reader = ByteReader(data)
        guard let flags = reader.readUInt16(), let power = reader.readInt16() else { return nil }
        var fields: [DecodedValue.Field] = [.init("Instantaneous Power", "\(power) W")]
        if flags & 0x0001 != 0, let balance = reader.readUInt8() {
            let reference = flags & 0x0002 != 0 ? "left" : "unknown"
            fields.append(.init("Pedal Power Balance", DecodeFormat.number(Double(balance) / 2, decimals: 1) + " % (\(reference))"))
        }
        if flags & 0x0004 != 0, let torque = reader.readUInt16() {
            let source = flags & 0x0008 != 0 ? "crank" : "wheel"
            fields.append(.init("Accumulated Torque", DecodeFormat.number(Double(torque) / 32, decimals: 2) + " N·m (\(source))"))
        }
        if flags & 0x0010 != 0, let revolutions = reader.readUInt32(), let time = reader.readUInt16() {
            fields.append(.init("Cumulative Wheel Revolutions", "\(revolutions)"))
            // Cycling Power uses 1/2048 s for wheel events (unlike CSC's 1/1024 s).
            fields.append(.init("Last Wheel Event Time", DecodeFormat.number(Double(time) / 2048, decimals: 3) + " s"))
        }
        if flags & 0x0020 != 0, let revolutions = reader.readUInt16(), let time = reader.readUInt16() {
            fields.append(.init("Cumulative Crank Revolutions", "\(revolutions)"))
            fields.append(.init("Last Crank Event Time", DecodeFormat.number(Double(time) / 1024, decimals: 3) + " s"))
        }
        if flags & 0x0040 != 0, let maxForce = reader.readInt16(), let minForce = reader.readInt16() {
            fields.append(.init("Extreme Force", "max \(maxForce) N, min \(minForce) N"))
        }
        if flags & 0x0080 != 0, let maxTorque = reader.readInt16(), let minTorque = reader.readInt16() {
            fields.append(.init("Extreme Torque", "max \(DecodeFormat.number(Double(maxTorque) / 32, decimals: 2)) N·m, min \(DecodeFormat.number(Double(minTorque) / 32, decimals: 2)) N·m"))
        }
        if flags & 0x0100 != 0, let packed = reader.readUInt24() {
            fields.append(.init("Extreme Angles", "max \(packed & 0x0FFF)°, min \(packed >> 12)°"))
        }
        if flags & 0x0200 != 0, let angle = reader.readUInt16() {
            fields.append(.init("Top Dead Spot Angle", "\(angle)°"))
        }
        if flags & 0x0400 != 0, let angle = reader.readUInt16() {
            fields.append(.init("Bottom Dead Spot Angle", "\(angle)°"))
        }
        if flags & 0x0800 != 0, let energy = reader.readUInt16() {
            fields.append(.init("Accumulated Energy", "\(energy) kJ"))
        }
        if flags & 0x1000 != 0 {
            fields.append(.init("Offset Compensation Indicator", "Set"))
        }
        return DecodedValue(summary: "Power: \(power) W", fields: fields, decoder: "Cycling Power Measurement")
    }

    /// 0x2A53 RSC Measurement (RSCS §3.1).
    static let rscMeasurement = ClosureDecoder(name: "RSC Measurement", uuids: [0x2A53]) { data in
        var reader = ByteReader(data)
        guard let flags = reader.readUInt8(), let speed = reader.readUInt16(), let cadence = reader.readUInt8() else { return nil }
        let metersPerSecond = Double(speed) / 256
        var fields: [DecodedValue.Field] = [
            .init("Speed", DecodeFormat.number(metersPerSecond, decimals: 2) + " m/s (" + DecodeFormat.number(metersPerSecond * 3.6, decimals: 2) + " km/h)"),
            .init("Cadence", "\(cadence) steps/min"),
            .init("Activity", flags & 0x04 != 0 ? "Running" : "Walking"),
        ]
        if flags & 0x01 != 0, let stride = reader.readUInt16() {
            fields.append(.init("Stride Length", DecodeFormat.number(Double(stride) / 100, decimals: 2) + " m"))
        }
        if flags & 0x02 != 0, let distance = reader.readUInt32() {
            fields.append(.init("Total Distance", DecodeFormat.number(Double(distance) / 10, decimals: 1) + " m"))
        }
        return DecodedValue(summary: "RSC: " + DecodeFormat.number(metersPerSecond, decimals: 2) + " m/s, \(cadence) spm",
                            fields: fields, decoder: "RSC Measurement")
    }

    /// 0x2AD2 Indoor Bike Data (FTMS §4.9). Bit 0 ("More Data") is inverted:
    /// Instantaneous Speed is present when it is 0.
    static let indoorBikeData = ClosureDecoder(name: "Indoor Bike Data", uuids: [0x2AD2]) { data in
        var reader = ByteReader(data)
        guard let flags = reader.readUInt16() else { return nil }
        var fields: [DecodedValue.Field] = []
        var summary: [String] = []
        func present(_ bit: UInt16) -> Bool { flags & (1 << bit) != 0 }
        if !present(0), let speed = reader.readUInt16() {
            let text = DecodeFormat.number(Double(speed) / 100, decimals: 2) + " km/h"
            fields.append(.init("Instantaneous Speed", text))
            summary.append(text)
        }
        if present(1), let speed = reader.readUInt16() {
            fields.append(.init("Average Speed", DecodeFormat.number(Double(speed) / 100, decimals: 2) + " km/h"))
        }
        if present(2), let cadence = reader.readUInt16() {
            let text = DecodeFormat.number(Double(cadence) / 2, decimals: 1) + " rpm"
            fields.append(.init("Instantaneous Cadence", text))
            summary.append(text)
        }
        if present(3), let cadence = reader.readUInt16() {
            fields.append(.init("Average Cadence", DecodeFormat.number(Double(cadence) / 2, decimals: 1) + " rpm"))
        }
        if present(4), let distance = reader.readUInt24() {
            fields.append(.init("Total Distance", "\(distance) m"))
        }
        if present(5), let resistance = reader.readInt16() {
            fields.append(.init("Resistance Level", "\(resistance)"))
        }
        if present(6), let power = reader.readInt16() {
            fields.append(.init("Instantaneous Power", "\(power) W"))
            summary.append("\(power) W")
        }
        if present(7), let power = reader.readInt16() {
            fields.append(.init("Average Power", "\(power) W"))
        }
        if present(8), let total = reader.readUInt16(), let perHour = reader.readUInt16(), let perMinute = reader.readUInt8() {
            fields.append(.init("Expended Energy", "\(total) kcal total, \(perHour) kcal/h, \(perMinute) kcal/min"))
        }
        if present(9), let heartRate = reader.readUInt8() {
            fields.append(.init("Heart Rate", "\(heartRate) BPM"))
        }
        if present(10), let met = reader.readUInt8() {
            fields.append(.init("Metabolic Equivalent", DecodeFormat.number(Double(met) / 10, decimals: 1)))
        }
        if present(11), let elapsed = reader.readUInt16() {
            fields.append(.init("Elapsed Time", "\(elapsed) s"))
        }
        if present(12), let remaining = reader.readUInt16() {
            fields.append(.init("Remaining Time", "\(remaining) s"))
        }
        return DecodedValue(summary: "Indoor Bike: " + (summary.isEmpty ? "partial record" : summary.joined(separator: ", ")),
                            fields: fields, decoder: "Indoor Bike Data")
    }

    /// 0x2ACD Treadmill Data (FTMS §4.4). Decodes the leading fields whose
    /// layout is stable across FTMS revisions and lists any later fields that
    /// are flagged present.
    static let treadmillData = ClosureDecoder(name: "Treadmill Data", uuids: [0x2ACD]) { data in
        var reader = ByteReader(data)
        guard let flags = reader.readUInt16() else { return nil }
        var fields: [DecodedValue.Field] = []
        var summary = "partial record"
        func present(_ bit: UInt16) -> Bool { flags & (1 << bit) != 0 }
        if !present(0), let speed = reader.readUInt16() {
            summary = DecodeFormat.number(Double(speed) / 100, decimals: 2) + " km/h"
            fields.append(.init("Instantaneous Speed", summary))
        }
        if present(1), let speed = reader.readUInt16() {
            fields.append(.init("Average Speed", DecodeFormat.number(Double(speed) / 100, decimals: 2) + " km/h"))
        }
        if present(2), let distance = reader.readUInt24() {
            fields.append(.init("Total Distance", "\(distance) m"))
        }
        if present(3), let inclination = reader.readInt16(), let ramp = reader.readInt16() {
            fields.append(.init("Inclination", DecodeFormat.number(Double(inclination) / 10, decimals: 1) + " %"))
            fields.append(.init("Ramp Angle", DecodeFormat.number(Double(ramp) / 10, decimals: 1) + "°"))
        }
        if present(4), let positive = reader.readUInt16(), let negative = reader.readUInt16() {
            fields.append(.init("Elevation Gain", DecodeFormat.number(Double(positive) / 10, decimals: 1) + " m up, " + DecodeFormat.number(Double(negative) / 10, decimals: 1) + " m down"))
        }
        let later = DecodeFormat.flags(UInt64(flags), names: [5: "Instantaneous Pace", 6: "Average Pace", 7: "Expended Energy",
                                                             8: "Heart Rate", 9: "Metabolic Equivalent", 10: "Elapsed Time",
                                                             11: "Remaining Time", 12: "Force on Belt and Power Output"])
        if !later.isEmpty {
            fields.append(.init("Also present (not decoded)", later.joined(separator: ", ")))
        }
        return DecodedValue(summary: "Treadmill: \(summary)", fields: fields, decoder: "Treadmill Data")
    }

    /// 0x2ACC Fitness Machine Feature: two 32-bit bitfields.
    static let fitnessMachineFeature = ClosureDecoder(name: "Fitness Machine Feature", uuids: [0x2ACC]) { data in
        var reader = ByteReader(data)
        guard let machine = reader.readUInt32(), let target = reader.readUInt32() else { return nil }
        let machineNames: [Int: String] = [
            0: "Average Speed", 1: "Cadence", 2: "Total Distance", 3: "Inclination", 4: "Elevation Gain",
            5: "Pace", 6: "Step Count", 7: "Resistance Level", 8: "Stride Count", 9: "Expended Energy",
            10: "Heart Rate Measurement", 11: "Metabolic Equivalent", 12: "Elapsed Time", 13: "Remaining Time",
            14: "Power Measurement", 15: "Force on Belt and Power Output", 16: "User Data Retention",
        ]
        let targetNames: [Int: String] = [
            0: "Speed", 1: "Inclination", 2: "Resistance", 3: "Power", 4: "Heart Rate",
            5: "Targeted Expended Energy", 6: "Targeted Step Number", 7: "Targeted Stride Number",
            8: "Targeted Distance", 9: "Targeted Training Time", 10: "Targeted Time in Two HR Zones",
            11: "Targeted Time in Three HR Zones", 12: "Targeted Time in Five HR Zones",
            13: "Indoor Bike Simulation", 14: "Wheel Circumference", 15: "Spin Down Control", 16: "Targeted Cadence",
        ]
        let machineList = DecodeFormat.flags(UInt64(machine), names: machineNames)
        let targetList = DecodeFormat.flags(UInt64(target), names: targetNames)
        return DecodedValue(summary: "Fitness Machine: \(machineList.count) features, \(targetList.count) target settings", fields: [
            .init("Machine Features", machineList.isEmpty ? "none" : machineList.joined(separator: ", ")),
            .init("Target Settings", targetList.isEmpty ? "none" : targetList.joined(separator: ", ")),
        ], decoder: "Fitness Machine Feature")
    }

    static let trainingStatus = ClosureDecoder(name: "Training Status", uuids: [0x2AD3]) { data in
        var reader = ByteReader(data)
        guard let flags = reader.readUInt8(), let status = reader.readUInt8() else { return nil }
        let names = ["Other", "Idle", "Warming Up", "Low Intensity Interval", "High Intensity Interval",
                     "Recovery Interval", "Isometric", "Heart Rate Control", "Fitness Test",
                     "Speed Outside Control Region (Low)", "Speed Outside Control Region (High)", "Cool Down",
                     "Watt Control", "Manual Mode (Quick Start)", "Pre-Workout", "Post-Workout"]
        let name = names[safe: Int(status)] ?? "Reserved (\(status))"
        var fields = [DecodedValue.Field("Status", name)]
        if flags & 0x01 != 0 {
            fields.append(.init("Status String", String(decoding: reader.readRemaining(), as: UTF8.self)))
        }
        return DecodedValue(summary: "Training Status: \(name)", fields: fields, decoder: "Training Status")
    }

    static let supportedSpeedRange = ClosureDecoder(name: "Supported Speed Range", uuids: [0x2AD4]) { data in
        var reader = ByteReader(data)
        guard let minimum = reader.readUInt16(), let maximum = reader.readUInt16(), let step = reader.readUInt16() else { return nil }
        let text = "\(DecodeFormat.number(Double(minimum) / 100, decimals: 2))–\(DecodeFormat.number(Double(maximum) / 100, decimals: 2)) km/h, step \(DecodeFormat.number(Double(step) / 100, decimals: 2))"
        return DecodedValue(summary: "Speed Range: \(text)", decoder: "Supported Speed Range")
    }

    static let supportedPowerRange = ClosureDecoder(name: "Supported Power Range", uuids: [0x2AD8]) { data in
        var reader = ByteReader(data)
        guard let minimum = reader.readInt16(), let maximum = reader.readInt16(), let step = reader.readUInt16() else { return nil }
        return DecodedValue(summary: "Power Range: \(minimum)–\(maximum) W, step \(step) W", decoder: "Supported Power Range")
    }

    static let supportedResistanceRange = ClosureDecoder(name: "Supported Resistance Level Range", uuids: [0x2AD6]) { data in
        var reader = ByteReader(data)
        guard let minimum = reader.readInt16(), let maximum = reader.readInt16(), let step = reader.readUInt16() else { return nil }
        return DecodedValue(summary: "Resistance Range: \(DecodeFormat.number(Double(minimum) / 10, decimals: 1))–\(DecodeFormat.number(Double(maximum) / 10, decimals: 1)), step \(DecodeFormat.number(Double(step) / 10, decimals: 1))",
                            decoder: "Supported Resistance Level Range")
    }
}
