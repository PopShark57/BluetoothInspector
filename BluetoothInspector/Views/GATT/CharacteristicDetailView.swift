import BluetoothInspectorKit
import SwiftUI

struct CharacteristicDetailView: View {
    @Environment(AppModel.self) private var model
    let device: InspectedDevice
    let characteristicID: GATTNodeID
    @State private var format: ByteDisplayFormat = .hex
    @State private var endianness: Endianness = .little

    var body: some View {
        if let characteristic = device.gatt.characteristic(characteristicID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(characteristic)
                    valueSection(characteristic)
                    if characteristic.properties.isWritable {
                        WriteEditorView(device: device, characteristic: characteristic)
                    }
                    descriptorSection(characteristic)
                    recentValues
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView("Characteristic Unavailable", systemImage: "questionmark.circle",
                                   description: Text("The peripheral may have changed its services."))
        }
    }

    private func header(_ characteristic: GATTCharacteristic) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(characteristic.name).font(.title3.weight(.semibold))
                Spacer()
                if let service = device.gatt.service(characteristic.serviceID) {
                    Text("in \(service.uuid.displayName)").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(characteristic.uuid.uuidString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                CopyButton(text: characteristic.uuid.uuidString, help: "Copy UUID")
            }
            if let description = characteristic.userDescription {
                Text("“\(description)”").font(.callout).foregroundStyle(.secondary)
            }
            PropertyChips(properties: characteristic.properties)
            if let error = characteristic.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
    }

    private func valueSection(_ characteristic: GATTCharacteristic) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if characteristic.properties.isReadable {
                        Button {
                            model.workspace.read(characteristic: characteristic.id, on: device.id)
                        } label: {
                            Label("Read", systemImage: "arrow.down.circle")
                        }
                        .tint(.blue)
                        .help("Read the current value from the device")
                    }
                    if characteristic.properties.canSubscribe {
                        Toggle(isOn: Binding(
                            get: { characteristic.isNotifying },
                            set: { model.workspace.setNotify($0, for: characteristic.id, on: device.id) }
                        )) {
                            Label(characteristic.properties.contains(.indicate) && !characteristic.properties.contains(.notify) ? "Indications" : "Notifications",
                                  systemImage: characteristic.isNotifying ? "bell.fill" : "bell")
                        }
                        .toggleStyle(.button)
                        .tint(.purple)
                        .help("Subscribe to value updates. macOS writes the CCCD for you.")
                    }
                    Spacer()
                    Picker("Format", selection: $format) {
                        ForEach(ByteDisplayFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if format == .unsignedInteger || format == .signedInteger {
                        Picker("Byte Order", selection: $endianness) {
                            Text("LE").tag(Endianness.little)
                            Text("BE").tag(Endianness.big)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
                .disabled(device.connectionState != .connected)

                if let value = characteristic.value {
                    HStack(alignment: .top) {
                        Text(ByteFormatter.format(value, as: format, endianness: endianness))
                            .font(.system(.title3, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CopyButton(text: value.hexString, help: "Copy hex")
                    }
                    HStack {
                        Text("\(value.count) bytes")
                        if let updated = characteristic.valueUpdatedAt {
                            Text("· updated \(DisplayFormatting.timeWithMilliseconds(updated))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let decoded = model.workspace.decodedValue(of: characteristic) {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(decoded.summary).font(.headline)
                            ForEach(decoded.fields, id: \.self) { field in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(field.name).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(field.value).textSelection(.enabled).multilineTextAlignment(.trailing)
                                }
                                .font(.callout)
                            }
                            Text("Decoded by \(decoded.decoder)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contextMenu {
                            Button("Copy Decoded Value") {
                                Pasteboard.copy(([decoded.summary] + decoded.fields.map { "\($0.name): \($0.value)" }).joined(separator: "\n"))
                            }
                        }
                    }
                } else {
                    Text(characteristic.properties.isReadable ? "No value yet. Press Read." :
                            characteristic.properties.canSubscribe ? "No value yet. Enable notifications to receive updates." :
                            "This characteristic cannot be read.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        } label: {
            Label("Value", systemImage: "arrow.down.circle")
        }
    }

    @ViewBuilder
    private func descriptorSection(_ characteristic: GATTCharacteristic) -> some View {
        if !characteristic.descriptors.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(characteristic.descriptors) { descriptor in
                        HStack(alignment: .firstTextBaseline) {
                            Text(descriptor.uuid.shortString).font(.system(.body, design: .monospaced))
                            Text(descriptor.name).lineLimit(1)
                            Spacer()
                            Text(model.workspace.decodedValue(of: descriptor)?.summary ?? descriptor.value?.displayText ?? "—")
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Button {
                                model.workspace.readDescriptor(descriptor.id, on: device.id)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Read descriptor")
                            .disabled(device.connectionState != .connected)
                        }
                        .contextMenu {
                            Button("Copy UUID") { Pasteboard.copy(descriptor.uuid.uuidString) }
                            if let value = descriptor.value { Button("Copy Hex") { Pasteboard.copy(value.data.hexString) } }
                        }
                    }
                }
                .padding(4)
            } label: {
                Label("Descriptors", systemImage: "tag")
            }
        }
    }

    private var recentValues: some View {
        GroupBox {
            ValueHistoryView(device: device, characteristicID: characteristicID)
                .frame(height: 220)
        } label: {
            Label("History", systemImage: "clock")
        }
    }
}
