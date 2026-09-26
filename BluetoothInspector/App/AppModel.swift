import BluetoothInspectorKit
import Foundation
import Observation
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case discover
    case connected
    case saved
    case activity
    case assignedNumbers
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discover: "Discover"
        case .connected: "Connected"
        case .saved: "Saved Devices"
        case .activity: "Activity Log"
        case .assignedNumbers: "Assigned Numbers"
        case .diagnostics: "Diagnostics"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .discover: "dot.radiowaves.left.and.right"
        case .connected: "link"
        case .saved: "star"
        case .activity: "list.bullet.rectangle"
        case .assignedNumbers: "number"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape"
        }
    }

    var isDeviceList: Bool { self == .discover || self == .connected || self == .saved }

    var searchPrompt: String {
        switch self {
        case .discover, .connected, .saved: "Name, UUID, service, manufacturer"
        case .activity: "Search console"
        case .assignedNumbers: "UUID or name"
        case .diagnostics, .settings: "Search"
        }
    }
}

/// A finished export waiting for the save panel.
struct PendingExport: Identifiable {
    let id = UUID()
    let document: ExportDocument
    let filename: String
}

/// Composition root and UI state that spans views.
///
/// Creates the real CoreBluetooth/IOBluetooth clients, the history store and
/// the workspace; everything Bluetooth-related lives in the workspace.
@MainActor
@Observable
final class AppModel {
    let workspace: BluetoothWorkspace
    let context = SystemInfo.diagnosticsContext
    @ObservationIgnored private let settingsStore = SettingsStore()

    var section: SidebarSection = .discover
    var selectedDeviceID: DeviceID?
    var searchText = ""
    /// Incremented to ask the window to focus the search field (⌘F).
    var searchFocusRequest = 0
    var filter = DeviceFilter()
    var sortOrder = [KeyPathComparator(\DeviceListItem.rssiSortValue, order: .reverse)]
    var isExportSheetPresented = false
    var pendingExport: PendingExport?
    var errorMessage: String?

    init() {
        let settings = SettingsStore().load()
        let historyStore: (any DeviceHistoryPersisting)?
        do {
            historyStore = FileDeviceHistoryStore(url: try FileDeviceHistoryStore.defaultURL())
        } catch {
            historyStore = nil
        }
        workspace = BluetoothWorkspace(
            ble: CoreBluetoothClient(),
            classic: IOBluetoothClassicClient(),
            historyStore: historyStore,
            settings: settings
        )
        workspace.log.mirror = { AppLogger.mirror($0) }
        if historyStore == nil {
            workspace.log.append(.error, "Application Support is unavailable; saved devices will not persist this session")
        }
        workspace.start()
    }

    var exportBuilder: ExportBuilder { ExportBuilder(workspace: workspace, context: context) }

    var selectedDevice: InspectedDevice? {
        selectedDeviceID.flatMap(workspace.device)
    }

    // MARK: Device lists

    func items(for section: SidebarSection) -> [DeviceListItem] {
        var filter = self.filter
        filter.searchText = searchText
        let base = workspace.deviceList.filter { item in
            switch section {
            case .connected: item.connectionState != .disconnected || item.isSystemConnected
            case .saved: item.isSaved
            default: item.isLive
            }
        }
        return base.filter(filter.matches).sorted(using: sortOrder)
    }

    func count(for section: SidebarSection) -> Int {
        switch section {
        case .discover: workspace.devices.count
        case .connected: workspace.connectedDevices.count
        case .saved: workspace.history.devices.count
        case .activity: workspace.log.errorCount
        default: 0
        }
    }

    // MARK: Settings

    func updateSettings(_ change: (inout InspectorSettings) -> Void) {
        var settings = workspace.settings
        change(&settings)
        guard settings != workspace.settings else { return }
        workspace.settings = settings
        settingsStore.save(settings)
    }

    func settingBinding<Value>(_ keyPath: WritableKeyPath<InspectorSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.workspace.settings[keyPath: keyPath] },
            set: { newValue in self.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
    }

    // MARK: Commands

    func focusSearch() {
        searchFocusRequest += 1
    }

    func toggleSelectedConnection() {
        guard let id = selectedDeviceID else { return }
        if case .classic = id {
            workspace.performSDPQuery(id)
        } else {
            workspace.toggleConnection(id)
        }
    }

    func readAllOnSelectedDevice() {
        guard let id = selectedDeviceID else { return }
        workspace.readAll(on: id)
    }

    func present(_ export: PendingExport) {
        pendingExport = export
    }

    func loadSIGExtension(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let count = try AssignedNumbers.loadExtension(from: Data(contentsOf: url))
            workspace.log.append(.system, "Loaded \(count) extra Bluetooth SIG entries from \(url.lastPathComponent)")
            workspace.markAllDevicesChanged()
        } catch {
            errorMessage = "Could not load the SIG database: \(error.localizedDescription)"
            workspace.log.append(.error, errorMessage ?? "")
        }
    }
}
