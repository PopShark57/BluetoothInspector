import AppKit
import BluetoothInspectorKit
import SwiftUI

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// A label/value row whose value is selectable and copyable.
struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false
    var help: String?

    init(_ label: String, _ value: String, monospaced: Bool = false, help: String? = nil) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
        self.help = help
    }

    var body: some View {
        LabeledContent {
            Text(value.isEmpty ? "—" : value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        } label: {
            Text(label)
                .help(help ?? "")
        }
        .contextMenu {
            Button("Copy \(label)") { Pasteboard.copy(value) }
            Button("Copy “\(label): \(value)”") { Pasteboard.copy("\(label): \(value)") }
        }
    }
}

struct CopyButton: View {
    let text: String
    var help = "Copy"

    var body: some View {
        Button {
            Pasteboard.copy(text)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Signal bars plus dBm. RSSI is relative signal strength, not distance.
struct RSSIIndicator: View {
    let rssi: Int?
    var showValue = true

    private var fraction: Double {
        guard let rssi else { return 0 }
        return min(1, max(0, Double(rssi + 100) / 60))
    }

    private var color: Color {
        guard let rssi else { return .secondary }
        if rssi >= -60 { return .green }
        if rssi >= -75 { return .yellow }
        if rssi >= -90 { return .orange }
        return .red
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cellularbars", variableValue: fraction)
                .foregroundStyle(color)
            if showValue {
                Text(rssi.map { "\($0) dBm" } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(rssi == nil ? .secondary : .primary)
            }
        }
        .help("Received signal strength (relative; not a distance measurement)")
        .accessibilityElement(children: .combine)
    }
}

struct TransportBadge: View {
    let transport: BluetoothTransport
    var dualModeHint: DualModeHint = .none

    var body: some View {
        HStack(spacing: 3) {
            Text(transport.title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(transport == .lowEnergy ? Color.blue.opacity(0.18) : Color.purple.opacity(0.18), in: Capsule())
                .foregroundStyle(transport == .lowEnergy ? Color.blue : Color.purple)
            if dualModeHint != .none {
                Image(systemName: "questionmark.diamond")
                    .foregroundStyle(.orange)
                    .help(dualModeHint.explanation)
            }
        }
        .help(transport.longTitle)
    }
}

struct ConnectionBadge: View {
    let state: ConnectionState
    var systemConnected = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(systemConnected && state == .disconnected ? "System" : state.title)
                .foregroundStyle(state == .disconnected && !systemConnected ? .secondary : .primary)
        }
        .help(systemConnected ? "Connected to this Mac by the system or another app" : state.title)
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .connecting, .disconnecting: .orange
        case .disconnected: systemConnected ? .teal : .gray.opacity(0.5)
        }
    }
}

/// Characteristic property chips. Read/write/notify families get distinct
/// colors so reads, writes and notifications are never confused.
struct PropertyChips: View {
    let properties: GATTProperties
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(properties.descriptors, id: \.property.rawValue) { descriptor in
                Text(compact ? descriptor.shortTitle : descriptor.title)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Self.color(for: descriptor.property).opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(Self.color(for: descriptor.property))
                    .help(descriptor.title)
            }
        }
    }

    static func color(for property: GATTProperties) -> Color {
        if property == .read { return .blue }
        if property == .write || property == .writeWithoutResponse || property == .authenticatedSignedWrites { return .orange }
        if property == .notify || property == .indicate { return .purple }
        return .gray
    }
}

extension EventCategory {
    var color: Color {
        switch self {
        case .scan: .teal
        case .rssi: .mint
        case .connection: .green
        case .service: .indigo
        case .read: .blue
        case .write: .orange
        case .notify: .purple
        case .decode: .cyan
        case .classic: .pink
        case .system: .secondary
        case .error: .red
        }
    }
}

struct CategoryTag: View {
    let category: EventCategory

    var body: some View {
        Text(category.tag)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(category.color)
            .frame(width: 64, alignment: .leading)
    }
}

extension ValueRecord.Kind {
    var color: Color {
        switch self {
        case .read: .blue
        case .notification: .purple
        case .write: .orange
        }
    }

    var symbolName: String {
        switch self {
        case .read: "arrow.down.circle"
        case .notification: "bell"
        case .write: "arrow.up.circle"
        }
    }
}

enum DisplayFormatting {
    static let time: Date.FormatStyle = .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)

    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(time)
    }

    static func timeWithMilliseconds(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3)))
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}

/// Opens the relevant pane of System Settings.
enum SystemSettingsLink {
    static let bluetoothPrivacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
    static let bluetooth = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")

    static func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
