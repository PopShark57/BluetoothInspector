import BluetoothInspectorKit
import SwiftUI

/// Console-style view of all Bluetooth activity.
///
/// Rows come from the activity log's throttled snapshot (≤ 4 updates/s), so
/// high notification rates do not stall the UI. Pausing freezes the view while
/// events keep being recorded.
struct ConsoleView: View {
    @Environment(AppModel.self) private var model
    @State private var categories: Set<EventCategory> = Set(EventCategory.allCases)
    @State private var onlySelectedDevice = false
    @State private var autoScroll = true
    @State private var selection: Set<ActivityEvent.ID> = []

    private static let primaryCategories: [EventCategory] = [.scan, .connection, .service, .read, .write, .notify, .error]
    private static let secondaryCategories: [EventCategory] = [.decode, .rssi, .classic, .system]

    var body: some View {
        let log = model.workspace.log
        let filter = EventFilter(categories: categories, searchText: model.searchText,
                                 deviceID: onlySelectedDevice ? model.selectedDeviceID : nil)
        let events = log.events(matching: filter)
        VStack(spacing: 0) {
            filterBar(log: log, visible: events)
            Divider()
            ScrollViewReader { proxy in
                List(events, selection: $selection) { event in
                    ConsoleRow(event: event)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .contextMenu { rowMenu(event) }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 18)
                .onChange(of: events.last?.id) { _, last in
                    guard autoScroll, !log.isPaused, let last else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
                .onCopyCommand {
                    let lines = events.filter { selection.contains($0.id) }.map(\.consoleLine)
                    return [NSItemProvider(object: lines.joined(separator: "\n") as NSString)]
                }
            }
            .overlay {
                if events.isEmpty {
                    ContentUnavailableView(log.snapshot.isEmpty ? "No Activity Yet" : "No Matching Events",
                                           systemImage: "list.bullet.rectangle",
                                           description: Text(log.snapshot.isEmpty ? "Scan, connect or run an inquiry to see Bluetooth activity." : "Adjust the filters or search."))
                }
            }
            if let event = selectedEvent(in: events), let data = event.data {
                Divider()
                EventDataInspector(event: event, data: data)
            }
        }
    }

    private func filterBar(log: ActivityLog, visible: [ActivityEvent]) -> some View {
        HStack(spacing: 6) {
            ForEach(Self.primaryCategories) { category in
                categoryToggle(category)
            }
            Menu {
                ForEach(Self.secondaryCategories) { category in
                    Toggle(category.title, isOn: binding(for: category))
                }
                Divider()
                Button("Show All") { categories = Set(EventCategory.allCases) }
                Button("Errors Only") { categories = [.error] }
            } label: {
                Label("More", systemImage: "line.3.horizontal.decrease.circle")
            }
            .fixedSize()

            Toggle(isOn: $onlySelectedDevice) {
                Label("Selected Device", systemImage: "scope")
            }
            .toggleStyle(.button)
            .disabled(model.selectedDeviceID == nil)
            .help("Only show events for the device selected in Discover")

            Spacer()

            Text("\(visible.count) / \(log.snapshot.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("\(log.totalCount) events recorded in total; the newest \(log.capacity) are kept")

            Toggle(isOn: $autoScroll) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Follow new events")

            Toggle(isOn: Binding(get: { log.isPaused }, set: { log.isPaused = $0 })) {
                Image(systemName: log.isPaused ? "play.fill" : "pause.fill")
            }
            .toggleStyle(.button)
            .help(log.isPaused ? "Resume live updates (⇧⌘P)" : "Pause live updates; events are still recorded (⇧⌘P)")

            Button {
                let chosen = selection.isEmpty ? visible : visible.filter { selection.contains($0.id) }
                Pasteboard.copy(EventLog.consoleText(chosen))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy selected events, or all visible events if none are selected")

            Menu {
                Button("Export Visible as Text…") { export(visible, format: .text) }
                Button("Export Visible as CSV…") { export(visible, format: .csv) }
                Button("Export Visible as JSON…") { export(visible, format: .json) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .fixedSize()
            .help("Save events to a file")

            Button {
                log.clear()
                selection.removeAll()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear console (⌘K)")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func categoryToggle(_ category: EventCategory) -> some View {
        Toggle(isOn: binding(for: category)) {
            Label(category.title, systemImage: category.symbolName)
                .labelStyle(.titleAndIcon)
        }
        .toggleStyle(.button)
        .tint(category.color)
        .help("Show \(category.title.lowercased()) events")
    }

    private func binding(for category: EventCategory) -> Binding<Bool> {
        Binding(
            get: { categories.contains(category) },
            set: { isOn in
                if isOn { categories.insert(category) } else { categories.remove(category) }
            }
        )
    }

    @ViewBuilder
    private func rowMenu(_ event: ActivityEvent) -> some View {
        Button("Copy Line") { Pasteboard.copy(event.consoleLine) }
        Button("Copy Message") { Pasteboard.copy(event.message) }
        if let data = event.data {
            Button("Copy Hex") { Pasteboard.copy(data.hexString) }
        }
        if let uuid = event.uuid {
            Button("Copy UUID") { Pasteboard.copy(uuid.uuidString) }
        }
        if let id = event.deviceID {
            Button("Copy Device Identifier") { Pasteboard.copy(id.identifierString) }
            Button("Show Device") {
                model.selectedDeviceID = id
                model.section = .discover
            }
        }
    }

    private func selectedEvent(in events: [ActivityEvent]) -> ActivityEvent? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return events.first { $0.id == id }
    }

    private func export(_ events: [ActivityEvent], format: ExportFormat) {
        let document: ExportDocument
        switch format {
        case .text:
            document = ExportDocument(text: EventLog.consoleText(events) + "\n", format: .text)
        case .csv:
            document = ExportDocument(text: CSVExporter.events(events), format: .csv)
        case .json:
            do {
                document = ExportDocument(data: try ExportCoding.jsonEncoder().encode(events.map(EventExport.init)), format: .json)
            } catch {
                model.errorMessage = "Could not encode events: \(error.localizedDescription)"
                return
            }
        }
        model.present(PendingExport(document: document, filename: ExportDocument.filename("activity-log", format: format)))
    }
}

struct ConsoleRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.timeString)
                .foregroundStyle(.secondary)
            CategoryTag(category: event.category)
            if let name = event.deviceName {
                Text(name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .leading)
            }
            Text(event.message)
                .foregroundStyle(event.category == .error ? Color.red : Color.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(.callout, design: .monospaced))
    }
}

/// Multi-format view of the payload attached to the selected console event.
struct EventDataInspector: View {
    let event: ActivityEvent
    let data: Data
    @State private var format: ByteDisplayFormat = .hex

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.uuid?.displayName ?? "Payload").font(.headline)
                Text("\(data.count) bytes · \(DisplayFormatting.timeWithMilliseconds(event.timestamp))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 200, alignment: .leading)
            Picker("Format", selection: $format) {
                ForEach(ByteDisplayFormat.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Text(ByteFormatter.format(data, as: format))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: ByteFormatter.format(data, as: format))
        }
        .padding(10)
    }
}
