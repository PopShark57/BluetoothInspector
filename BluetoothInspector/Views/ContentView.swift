import BluetoothInspectorKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            detail
                .navigationTitle(model.section.title)
                .navigationSubtitle(subtitle)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: model.section.searchPrompt)
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .toolbar { MainToolbar(model: model) }
        .sheet(isPresented: $model.isExportSheetPresented) {
            ExportSheet()
        }
        .fileExporter(
            isPresented: Binding(get: { model.pendingExport != nil }, set: { if !$0 { model.pendingExport = nil } }),
            document: model.pendingExport?.document,
            contentType: model.pendingExport?.document.contentType ?? .json,
            defaultFilename: model.pendingExport?.filename
        ) { result in
            switch result {
            case .success(let url):
                model.workspace.log.append(.system, "Exported \(url.lastPathComponent)")
            case .failure(let error):
                model.errorMessage = "Export failed: \(error.localizedDescription)"
            }
            model.pendingExport = nil
        }
        .alert("Bluetooth Inspector", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .discover, .connected, .saved:
            DeviceBrowserView(section: model.section)
        case .activity:
            ConsoleView()
        case .assignedNumbers:
            AssignedNumbersView()
        case .diagnostics:
            DiagnosticsView()
        case .settings:
            SettingsView()
        }
    }

    private var subtitle: String {
        let workspace = model.workspace
        switch model.section {
        case .discover:
            return workspace.isScanning ? "Scanning · \(workspace.devices.count) devices" : "\(workspace.devices.count) devices"
        case .connected:
            return "\(workspace.connectedDevices.count) connected"
        case .saved:
            return "\(workspace.history.devices.count) saved"
        case .activity:
            return "\(workspace.log.snapshot.count) events" + (workspace.log.isPaused ? " · paused" : "")
        default:
            return "Bluetooth \(workspace.powerState.title)"
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })) {
            Section("Devices") {
                row(.discover)
                row(.connected)
                row(.saved)
            }
            Section("Tools") {
                row(.activity)
                row(.assignedNumbers)
                row(.diagnostics)
            }
            Section("App") {
                row(.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarStatusFooter()
        }
    }

    private func row(_ section: SidebarSection) -> some View {
        Label(section.title, systemImage: section.symbolName)
            .badge(badge(for: section))
            .tag(section)
    }

    private func badge(for section: SidebarSection) -> Int {
        switch section {
        case .discover, .connected, .saved, .activity: model.count(for: section)
        default: 0
        }
    }
}

/// Always-visible Bluetooth and scanner state at the bottom of the sidebar.
struct SidebarStatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let workspace = model.workspace
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(workspace.powerState == .poweredOn ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text("Bluetooth \(workspace.powerState.title)")
                    .font(.caption.weight(.medium))
            }
            HStack(spacing: 6) {
                if workspace.isScanning {
                    ProgressView().controlSize(.mini)
                    Text("Scanning")
                } else {
                    Image(systemName: "pause.circle")
                    Text("Scanner idle")
                }
                if workspace.isInquiryRunning {
                    Text("· Inquiry")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .help("Authorization: \(workspace.authorization.title)")
    }
}

struct MainToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        let workspace = model.workspace
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.toggleScan()
            } label: {
                Label(workspace.isScanning ? "Stop Scan" : "Scan",
                      systemImage: workspace.isScanning ? "stop.circle" : "dot.radiowaves.left.and.right")
            }
            .help(workspace.isScanning ? "Stop scanning for BLE advertisements (⌘R)" : "Scan for BLE advertisements (⌘R)")
            .disabled(workspace.powerState != .poweredOn && !workspace.isScanning)

            Button {
                workspace.toggleInquiry()
            } label: {
                Label(workspace.isInquiryRunning ? "Stop Inquiry" : "Classic Inquiry",
                      systemImage: workspace.isInquiryRunning ? "stop.circle" : "antenna.radiowaves.left.and.right")
            }
            .help("Search for discoverable Bluetooth Classic devices (⇧⌘I)")
            .disabled(!workspace.classicAvailable)

            Button {
                model.isExportSheetPresented = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export device data or the activity log (⌘E)")
        }
    }
}
