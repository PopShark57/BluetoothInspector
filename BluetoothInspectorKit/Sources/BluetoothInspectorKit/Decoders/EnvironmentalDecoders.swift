import Foundation

/// Environmental Sensing Service characteristic decoders (ESS / GSS).
enum EnvironmentalDecoders {
    static let all: [any PayloadDecoder] = [temperature, humidity, pressure, uvIndex, dewPoint, elevation, irradiance]

    /// 0x2A6E Temperature: sint16, 0.01 °C, 0x8000 = unknown.
    static let temperature = ClosureDecoder(name: "Temperature", uuids: [0x2A6E]) { data in
        var reader = ByteReader(data)
        guard data.count == 2, let raw = reader.readInt16() else { return nil }
        if raw == Int16.min { return DecodedValue(summary: "Temperature: unknown", decoder: "Temperature") }
        return DecodedValue(summary: "Temperature: \(DecodeFormat.number(Double(raw) / 100, decimals: 2)) °C", decoder: "Temperature")
    }

    /// 0x2A6F Humidity: uint16, 0.01 %, 0xFFFF = unknown.
    static let humidity = ClosureDecoder(name: "Humidity", uuids: [0x2A6F]) { data in
        var reader = ByteReader(data)
        guard data.count == 2, let raw = reader.readUInt16() else { return nil }
        if raw == 0xFFFF { return DecodedValue(summary: "Humidity: unknown", decoder: "Humidity") }
        return DecodedValue(summary: "Humidity: \(DecodeFormat.number(Double(raw) / 100, decimals: 2)) %", decoder: "Humidity")
    }

    /// 0x2A6D Pressure: uint32, 0.1 Pa.
    static let pressure = ClosureDecoder(name: "Pressure", uuids: [0x2A6D]) { data in
        var reader = ByteReader(data)
        guard data.count == 4, let raw = reader.readUInt32() else { return nil }
        let pascals = Double(raw) / 10
        return DecodedValue(summary: "Pressure: \(DecodeFormat.number(pascals / 100, decimals: 2)) hPa",
                            fields: [.init("Pressure", "\(DecodeFormat.number(pascals, decimals: 1)) Pa")], decoder: "Pressure")
    }

    static let uvIndex = ClosureDecoder(name: "UV Index", uuids: [0x2A76]) { data in
        guard data.count == 1, let value = data.first else { return nil }
        return DecodedValue(summary: "UV Index: \(value)", decoder: "UV Index")
    }

    static let dewPoint = ClosureDecoder(name: "Dew Point", uuids: [0x2A7B]) { data in
        guard data.count == 1, let value = data.first else { return nil }
        return DecodedValue(summary: "Dew Point: \(Int8(bitPattern: value)) °C", decoder: "Dew Point")
    }

    /// 0x2A6C Elevation: sint24, 0.01 m.
    static let elevation = ClosureDecoder(name: "Elevation", uuids: [0x2A6C]) { data in
        var reader = ByteReader(data)
        guard data.count == 3, let raw = reader.readInt24() else { return nil }
        return DecodedValue(summary: "Elevation: \(DecodeFormat.number(Double(raw) / 100, decimals: 2)) m", decoder: "Elevation")
    }

    /// 0x2A77 Irradiance: uint16, 0.1 W/m².
    static let irradiance = ClosureDecoder(name: "Irradiance", uuids: [0x2A77]) { data in
        var reader = ByteReader(data)
        guard data.count == 2, let raw = reader.readUInt16() else { return nil }
        return DecodedValue(summary: "Irradiance: \(DecodeFormat.number(Double(raw) / 10, decimals: 1)) W/m²", decoder: "Irradiance")
    }
}
