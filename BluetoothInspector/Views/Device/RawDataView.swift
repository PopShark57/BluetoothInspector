import BluetoothInspectorKit
import SwiftUI

/// Shows any payload of the device in hex, ASCII, integer, UTF-8 or binary form.
struct RawDataView: View {
    let device: InspectedDevice
    @State private var sourceID: String = "mfr"
    @State private var format: ByteDisplayFormat = .hex
    @State private var endianness: Endianness = .little

    private struct Source: Identifiable, Hashable {
        let id: String
        let title: String
        let data: Data
    }

    private var sources: [Source] {
        var result: [Source] = []
        if let data = device.advertisement.manufacturerData {
            result.append(Source(id: "mfr", title: "Manufacturer Data", data: data))
        }
        for entry in device.advertisement.serviceData {
            result.append(Source(id: "sd-\(entry.uuid.uuidString)", title: "Service Data \(entry.uuid.displayName)", data: entry.data))
        }
        if let name = device.advertisement.localName {
            result.append(Source(id: "name", title: "Local Name (UTF-8 bytes)", data: Data(name.utf8)))
        }
        for characteristic in device.gatt.allCharacteristics {
            if let value = characteristic.value {
                result.append(Source(id: characteristic.id.description, title: "Characteristic \(characteristic.uuid.displayName)", data: value))
            }
            for descriptor in characteristic.descriptors {
                if let value = descriptor.value {
                    result.append(Source(id: descriptor.id.description,
                                         title: "Descriptor \(descriptor.uuid.displayName) of \(characteristic.uuid.shortString)",
                                         data: value.data))
                }
            }
        }
        return result
    }

    var body: some View {
        let sources = sources
        let selected = sources.first { $0.id == sourceID } ?? sources.first
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Source", selection: $sourceID) {
                    ForEach(sources) { Text($0.title).tag($0.id) }
                }
                .frame(maxWidth: 360)
                .disabled(sources.isEmpty)
                Picker("Format", selection: $format) {
                    ForEach(ByteDisplayFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if format == .unsignedInteger || format == .signedInteger {
                    Picker("Byte Order", selection: $endianness) {
                        ForEach(Endianness.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
            }

            if let selected {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(selected.data.count) bytes").foregroundStyle(.secondary)
                            Spacer()
                            CopyButton(text: ByteFormatter.format(selected.data, as: format, endianness: endianness), help: "Copy in this format")
                        }
                        Text(ByteFormatter.format(selected.data, as: format, endianness: endianness))
                            .font(.system(.title3, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(4)
                }
                GroupBox("Hex Dump") {
                    ScrollView {
                        Text(ByteFormatter.hexDump(selected.data))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }
                }
            } else {
                ContentUnavailableView("No Raw Data", systemImage: "number",
                                       description: Text("Manufacturer data, service data and read characteristic values appear here."))
            }
        }
        .padding(12)
    }
}
