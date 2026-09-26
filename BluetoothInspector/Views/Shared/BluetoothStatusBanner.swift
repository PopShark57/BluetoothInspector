import BluetoothInspectorKit
import SwiftUI

/// Explains why Bluetooth is unusable (off, denied, unsupported) and how to fix it.
/// Hidden when everything is fine.
struct BluetoothStatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let workspace = model.workspace
        if let guidance = workspace.powerState.guidance, workspace.powerState != .unknown || workspace.authorization == .denied {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(for: workspace.powerState))
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bluetooth \(workspace.powerState.title)")
                        .font(.headline)
                    Text(guidance)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch workspace.powerState {
                case .unauthorized:
                    Button("Open Privacy Settings") { SystemSettingsLink.open(SystemSettingsLink.bluetoothPrivacy) }
                case .poweredOff:
                    Button("Open Bluetooth Settings") { SystemSettingsLink.open(SystemSettingsLink.bluetooth) }
                default:
                    EmptyView()
                }
            }
            .padding(12)
            .glassEffect(.regular.tint(.orange.opacity(0.15)), in: RoundedRectangle(cornerRadius: 12))
            .padding([.horizontal, .top], 10)
        }
    }

    private func symbol(for state: BluetoothPowerState) -> String {
        switch state {
        case .unauthorized: "hand.raised.slash"
        case .poweredOff: "power"
        case .unsupported: "xmark.octagon"
        default: "exclamationmark.triangle"
        }
    }
}
