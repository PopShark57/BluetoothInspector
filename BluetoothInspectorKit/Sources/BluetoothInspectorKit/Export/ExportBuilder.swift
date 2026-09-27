import Foundation

/// Environment facts included in diagnostics and exports. The app fills this
/// in (it knows the bundle version and OS); tests use fixed values.
public struct DiagnosticsContext: Sendable, Hashable {
    public var appVersion: String
    public var operatingSystem: String
    public var hardwareModel: String?

    public init(appVersion: String, operatingSystem: String, hardwareModel: String? = nil) {
        self.appVersion = appVersion
        self.operatingSystem = operatingSystem
        self.hardwareModel = hardwareModel
    }

    public var generator: ExportGenerator {
        ExportGenerator(appVersion: appVersion, operatingSystem: operatingSystem)
    }
}

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case json
    case csv
    case text

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .json: "JSON"
        case .csv: "CSV"
        case .text: "Plain Text Report"
        }
    }
    public var fileExtension: String {
        switch self {
        case .json: "json"
        case .csv: "csv"
        case .text: "txt"
        }
    }
}

/// Builds exports from live workspace state.
@MainActor
public struct ExportBuilder {
    public let workspace: BluetoothWorkspace
    public let context: DiagnosticsContext

    public init(workspace: BluetoothWorkspace, context: DiagnosticsContext) {
        self.workspace = workspace
        self.context = context
    }

    // MARK: Structured

    public func deviceExport(_ device: InspectedDevice, at date: Date = Date()) -> DeviceExport {
        let saved = workspace.history[device.id]
        let summary = DeviceSummaryExport(
            id: device.id.rawValue,
            identifier: device.id.identifierString,
            identifierKind: device.transport == .lowEnergy ? "CoreBluetooth peripheral UUID (per-Mac, not a Bluetooth address)" : "BD_ADDR",
            transport: device.transport.rawValue,
            name: device.name,
            customName: saved?.customName,
            connectionState: device.connectionState.rawValue,
            systemConnected: device.isSystemConnected,
            rssi: device.rssi,
            firstSeen: device.firstSeen,
            lastSeen: device.lastSeen,
            manufacturer: device.manufacturer,
            txPowerLevel: device.advertisement.txPowerLevel,
            connectable: device.advertisement.isConnectable,
            paired: device.isPaired,
            dualModeHint: device.dualModeHint.rawValue,
            favorite: saved?.isFavorite ?? false,
            notes: saved?.notes.isEmpty == false ? saved?.notes : nil,
            maximumWriteLength: device.maximumWriteLength,
            maximumWriteWithoutResponseLength: device.maximumWriteWithoutResponseLength,
            lastError: device.lastError
        )
        let services = device.gatt.services.map { service in
            ServiceExport(id: service.id.description, service: UUIDExport(service.uuid), primary: service.isPrimary,
                          includedServiceIDs: service.includedServiceIDs.map(\.description),
                          characteristicIDs: service.characteristics.map(\.id.description),
                          discovery: service.characteristicDiscovery.rawValue, error: service.lastError)
        }
        let characteristics = device.gatt.services.flatMap { service in
            service.characteristics.map { characteristicExport($0, service: service) }
        }
        let events = workspace.log.allEvents.filter { $0.deviceID == device.id }.map(EventExport.init)
        return DeviceExport(
            exportedAt: date,
            generator: context.generator,
            device: summary,
            advertisement: device.transport == .lowEnergy
                ? AdvertisementExport(device.advertisement, packetCount: device.advertisementPacketCount, changeCount: device.advertisementChangeCount)
                : nil,
            services: services,
            characteristics: characteristics,
            values: device.valueRecords.map(ValueRecordExport.init),
            rssi: RSSIExport(device.rssiHistory),
            classic: device.classic.map(ClassicExport.init),
            events: events
        )
    }

    private func characteristicExport(_ characteristic: GATTCharacteristic, service: GATTService) -> CharacteristicExport {
        CharacteristicExport(
            id: characteristic.id.description,
            serviceID: service.id.description,
            service: UUIDExport(service.uuid),
            characteristic: UUIDExport(characteristic.uuid),
            properties: characteristic.properties.titles,
            propertiesRaw: characteristic.properties.rawValue,
            hex: characteristic.value.map(ByteFormatter.compactHex),
            utf8: characteristic.value.flatMap(ByteFormatter.utf8),
            decoded: workspace.decodedValue(of: characteristic).map(DecodedExport.init),
            valueUpdatedAt: characteristic.valueUpdatedAt,
            notifying: characteristic.isNotifying,
            descriptors: characteristic.descriptors.map { descriptor in
                DescriptorExport(id: descriptor.id.description, descriptor: UUIDExport(descriptor.uuid),
                                 hex: descriptor.value.map { ByteFormatter.compactHex($0.data) },
                                 display: descriptor.value?.displayText,
                                 decoded: workspace.decodedValue(of: descriptor).map(DecodedExport.init),
                                 error: descriptor.lastError)
            },
            error: characteristic.lastError
        )
    }

    public func sessionExport(at date: Date = Date()) -> SessionExport {
        let devices = workspace.devices.values.sorted { $0.id < $1.id }.map { device in
            var export = deviceExport(device, at: date)
            export.events = [] // session-level events below avoid duplication
            return export
        }
        return SessionExport(exportedAt: date, generator: context.generator, diagnostics: diagnostics(),
                             devices: devices, events: workspace.log.allEvents.map(EventExport.init))
    }

    public func json<T: Encodable>(_ value: T) throws -> Data {
        try ExportCoding.jsonEncoder().encode(value)
    }

    // MARK: Diagnostics

    public func diagnostics() -> [String: String] {
        var info: [String: String] = [
            "App Version": context.appVersion,
            "Operating System": context.operatingSystem,
            "Bluetooth Power State": workspace.powerState.title,
            "Bluetooth Authorization": workspace.authorization.title,
            "Scanner State": workspace.scannerState.title,
            "Scan Options": describe(workspace.settings.scanOptions),
            "Devices Known": "\(workspace.devices.count)",
            "Connected Peripherals": workspace.connectedDevices.map { "\($0.displayName) [\($0.id.identifierString)]" }.joined(separator: "; "),
            "Classic Support": workspace.classicAvailable ? "IOBluetooth available" : "Unavailable",
            "Classic Inquiry": workspace.isInquiryRunning ? "Running" : "Idle",
            "Saved Devices": "\(workspace.history.devices.count)",
            "Log Events": "\(workspace.log.totalCount) total, \(workspace.log.allEvents.count) retained, \(workspace.log.errorCount) errors",
            "SIG Extension Entries": "\(AssignedNumbers.extensionEntryCount)",
        ]
        if let hardwareModel = context.hardwareModel { info["Hardware Model"] = hardwareModel }
        let host = workspace.hostController
        if let address = host.address { info["Host Controller Address"] = address }
        if let name = host.name { info["Host Controller Name"] = name }
        if let powered = host.isPoweredOn { info["Host Controller Power"] = powered ? "On" : "Off" }
        if let cod = host.classOfDevice { info["Host Class of Device"] = "\(cod.hexString) \(cod.summary)" }
        return info
    }

    public func diagnosticsText() -> String {
        diagnostics().sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.isEmpty ? "—" : $0.value)" }
            .joined(separator: "\n")
    }

    private func describe(_ options: ScanOptions) -> String {
        var parts = [options.allowDuplicates ? "duplicates allowed" : "duplicates filtered"]
        if !options.serviceUUIDs.isEmpty { parts.append("services: " + options.serviceUUIDs.map(\.shortString).joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }

    // MARK: Plain text

    public func textReport(for device: InspectedDevice, at date: Date = Date()) -> String {
        var lines: [String] = []
        func section(_ title: String) {
            lines.append("")
            lines.append(title)
            lines.append(String(repeating: "=", count: title.count))
        }
        let saved = workspace.history[device.id]
        lines.append("Bluetooth Inspector Diagnostic Report")
        lines.append("Generated: \(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))")
        lines.append("App \(context.appVersion) on \(context.operatingSystem)")

        section("Device")
        lines.append("Name:            \(saved?.customName.map { "\($0) (device name: \(device.displayName))" } ?? device.displayName)")
        lines.append("Identifier:      \(device.id.identifierString)")
        lines.append("Transport:       \(device.transport.longTitle)")
        if device.dualModeHint != .none { lines.append("Dual-mode:       \(device.dualModeHint.explanation)") }
        lines.append("Connection:      \(device.connectionState.title)\(device.isSystemConnected ? " (system-connected)" : "")")
        lines.append("RSSI:            \(device.rssi.map { "\($0) dBm" } ?? "n/a")")
        lines.append("Manufacturer:    \(device.manufacturer ?? "unknown")")
        lines.append("First seen:      \(device.firstSeen)")
        lines.append("Last seen:       \(device.lastSeen.map { "\($0)" } ?? "n/a")")
        if let error = device.lastError { lines.append("Last error:      \(error)") }
        if let notes = saved?.notes, !notes.isEmpty { lines.append("Notes:           \(notes)") }

        if device.transport == .lowEnergy {
            section("Advertisement")
            if device.advertisement.isEmpty { lines.append("(none received)") }
            for field in device.advertisement.fields {
                lines.append("\(field.name): \(field.value)\(field.rawHex.isEmpty ? "" : "  [\(field.rawHex)]")")
            }
            lines.append("Packets: \(device.advertisementPacketCount), content changes: \(device.advertisementChangeCount)")
        }

        if !device.gatt.isEmpty {
            section("GATT")
            for service in device.gatt.services {
                lines.append("\(service.isPrimary ? "Primary" : "Secondary") Service \(service.uuid.displayName)")
                for characteristic in service.characteristics {
                    let properties = characteristic.properties.titles.joined(separator: ", ")
                    lines.append("  ├─ \(characteristic.uuid.displayName) [\(properties)]\(characteristic.isNotifying ? " (notifying)" : "")")
                    if let value = characteristic.value {
                        lines.append("  │    value: \(value.hexString)")
                        if let decoded = workspace.decodedValue(of: characteristic) { lines.append("  │    decoded: \(decoded.summary)") }
                    }
                    if let error = characteristic.lastError { lines.append("  │    error: \(error)") }
                    for descriptor in characteristic.descriptors {
                        lines.append("  │    └─ \(descriptor.uuid.displayName): \(descriptor.value?.displayText ?? "not read")")
                    }
                }
            }
        }

        if let classic = device.classic {
            section("Bluetooth Classic")
            lines.append("Address:         \(classic.address) (OUI \(classic.oui))")
            if let cod = classic.classOfDevice { lines.append("Class of Device: \(cod.hexString) \(cod.summary)") }
            lines.append("Paired:          \(classic.isPaired ? "Yes" : "No")")
            lines.append("Connected:       \(classic.isConnected ? "Yes" : "No")")
            if let pnp = classic.pnpInformation { lines.append("PnP:             \(pnp.vendorDescription), product 0x\(String(format: "%04X", pnp.productID)), version \(pnp.versionString)") }
            for record in classic.serviceRecords {
                lines.append("SDP: \(record.title)\(record.summary.isEmpty ? "" : " — \(record.summary)")")
            }
        }

        let stats = RSSIHistory.statistics(for: device.rssiHistory.samples)
        if stats.count > 0 {
            section("RSSI (\(stats.count) samples)")
            lines.append("Average \(stats.average.map { String(format: "%.1f", $0) } ?? "n/a") dBm, min \(stats.minimum ?? 0), max \(stats.maximum ?? 0), trend \(stats.trend.title)")
            lines.append("RSSI is relative signal strength, not a distance measurement.")
        }

        let events = workspace.log.allEvents.filter { $0.deviceID == device.id }
        if !events.isEmpty {
            section("Activity (\(events.count) events)")
            lines += events.suffix(500).map(\.consoleLine)
        }

        section("Environment")
        lines.append(diagnosticsText())
        return lines.joined(separator: "\n") + "\n"
    }
}
