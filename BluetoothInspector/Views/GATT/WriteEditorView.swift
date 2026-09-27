import BluetoothInspectorKit
import SwiftUI

/// Composes and sends a characteristic write.
///
/// Nothing is sent until the user presses Write (and, by default, confirms).
/// The exact bytes are always previewed before sending.
struct WriteEditorView: View {
    @Environment(AppModel.self) private var model
    let device: InspectedDevice
    let characteristic: GATTCharacteristic

    @State private var text = ""
    @State private var inputFormat: WriteInputFormat = .hex
    @State private var width: IntegerWidth = .one
    @State private var endianness: Endianness = .little
    @State private var writeType: WriteType = .withResponse
    @State private var confirming = false

    private var availableTypes: [WriteType] {
        var types: [WriteType] = []
        if characteristic.properties.contains(.write) { types.append(.withResponse) }
        if characteristic.properties.contains(.writeWithoutResponse) { types.append(.withoutResponse) }
        return types
    }

    private var maximumLength: Int? {
        writeType == .withResponse ? device.maximumWriteLength : device.maximumWriteWithoutResponseLength
    }

    private var encoded: Result<Data, WriteEncodingError> {
        WriteValueEncoder(format: inputFormat, integerWidth: width, endianness: endianness)
            .encode(text, maximumLength: maximumLength)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Input", selection: $inputFormat) {
                        ForEach(WriteInputFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    if inputFormat.usesIntegerWidth {
                        Picker("Width", selection: $width) {
                            ForEach(IntegerWidth.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Picker("Byte Order", selection: $endianness) {
                            Text("LE").tag(Endianness.little)
                            Text("BE").tag(Endianness.big)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .help("Bluetooth SIG characteristics are little-endian")
                    }
                    Spacer()
                    Picker("Type", selection: $writeType) {
                        ForEach(availableTypes) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    .disabled(availableTypes.count < 2)
                }

                TextField(inputFormat.placeholder, text: $text, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(requestWrite)

                preview

                HStack {
                    if let maximumLength {
                        Text("Maximum \(maximumLength) bytes for write \(writeType.title.lowercased())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: nil, action: requestWrite) {
                        Label("Write", systemImage: "arrow.up.circle.fill")
                    }
                    .tint(.orange)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!canWrite)
                    .help("Send these bytes to the device (⇧⌘↩)")
                }
            }
            .padding(4)
        } label: {
            Label("Write", systemImage: "arrow.up.circle")
                .foregroundStyle(.orange)
        }
        .onAppear {
            if let first = availableTypes.first { writeType = first }
        }
        .confirmationDialog(confirmationTitle, isPresented: $confirming) {
            Button("Write \(pendingByteCount) Bytes") { send() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bytes: \((try? encoded.get())?.hexString ?? "")\n\nWrites change device state. Only continue if you know what this characteristic does.")
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch encoded {
        case .success(let data):
            HStack(alignment: .firstTextBaseline) {
                Text("Bytes to send (\(data.count)):").foregroundStyle(.secondary)
                Text(data.hexString)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            .font(.callout)
        case .failure(let error):
            if !text.isEmpty {
                Label(error.errorDescription ?? "Invalid input", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                Text("Enter a value to see the exact bytes that will be sent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canWrite: Bool {
        device.connectionState == .connected && (try? encoded.get()) != nil && availableTypes.contains(writeType)
    }

    private var pendingByteCount: Int { (try? encoded.get())?.count ?? 0 }

    private var confirmationTitle: String {
        "Write to \(characteristic.uuid.displayName)?"
    }

    private func requestWrite() {
        guard canWrite else { return }
        if model.workspace.settings.confirmWrites {
            confirming = true
        } else {
            send()
        }
    }

    private func send() {
        guard case .success(let data) = encoded else { return }
        model.workspace.write(data, to: characteristic.id, on: device.id, type: writeType)
    }
}
