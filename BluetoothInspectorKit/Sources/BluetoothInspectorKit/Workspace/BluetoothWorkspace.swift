import Foundation
import Observation

/// The app's single source of truth for Bluetooth state.
///
/// The workspace owns device models, the activity log and device history, and
/// turns raw events from the BLE and Classic clients into that state. It is
/// hardware-agnostic: the app injects CoreBluetooth/IOBluetooth-backed
/// clients, tests inject scripted mocks.
///
/// Safety rule: nothing in the workspace writes to a device on its own. The
/// only write path is `write(_:to:on:type:)`, which the UI calls in response
/// to an explicit user action.
@MainActor
@Observable
public final class BluetoothWorkspace {
    // MARK: Dependencies

    @ObservationIgnored public let ble: any BLEClient
    @ObservationIgnored public let classicClient: (any ClassicClient)?
    @ObservationIgnored private let historyStore: (any DeviceHistoryPersisting)?
    @ObservationIgnored public var decoders: DecoderRegistry
    @ObservationIgnored let now: @MainActor () -> Date

    // MARK: Observable state

    public private(set) var devices: [DeviceID: InspectedDevice] = [:]
    /// Throttled, unfiltered snapshot for the device tables.
    public private(set) var deviceList: [DeviceListItem] = []
    public let log: ActivityLog
    public private(set) var history: DeviceHistory
    public var settings: InspectorSettings {
        didSet { applySettings(oldValue: oldValue) }
    }

    public private(set) var powerState: BluetoothPowerState = .unknown
    public private(set) var authorization: BluetoothAuthorization = .notDetermined
    public private(set) var isScanning = false
    public private(set) var scanStartedAt: Date?
    public private(set) var isInquiryRunning = false
    public private(set) var hostController = HostControllerInfo()
    public private(set) var historyError: String?

    public var classicAvailable: Bool { classicClient != nil }

    public var scannerState: ScannerState {
        if isScanning { return .scanning }
        return powerState == .poweredOn ? .idle : .unavailable
    }

    public var connectedDevices: [InspectedDevice] {
        devices.values.filter { $0.isConnected || $0.isSystemConnected || $0.connectionState == .connecting }
            .sorted { $0.displayName < $1.displayName }
    }

    // MARK: Private bookkeeping

    @ObservationIgnored private var listDirty = true
    @ObservationIgnored private var historyDirty = false
    @ObservationIgnored private var lastHistorySave: Date = .distantPast
    @ObservationIgnored private var lastRSSIPoll: Date = .distantPast
    @ObservationIgnored private var lastAdvertisementLog: [DeviceID: Date] = [:]
    @ObservationIgnored private var connectionTimeouts: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var valueRecordID: UInt64 = 1
    /// Scan was requested before Bluetooth powered on; start as soon as it does.
    @ObservationIgnored private var pendingScan = false
    /// Disconnects the user asked for (so they are not logged as errors).
    @ObservationIgnored private var requestedDisconnects: Set<UUID> = []

    public init(
        ble: any BLEClient,
        classic: (any ClassicClient)?,
        historyStore: (any DeviceHistoryPersisting)?,
        settings: InspectorSettings = InspectorSettings(),
        decoders: DecoderRegistry = .standard,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.ble = ble
        self.classicClient = classic
        self.historyStore = historyStore
        self.settings = settings
        self.decoders = decoders
        self.now = now
        self.log = ActivityLog(capacity: settings.logCapacity)
        do {
            history = try historyStore?.load() ?? DeviceHistory()
        } catch {
            history = DeviceHistory()
            historyError = "Could not load saved devices: \(error.localizedDescription)"
        }
        powerState = ble.powerState
        authorization = ble.authorization
        ble.eventHandler = { [weak self] event in self?.handle(event) }
        classic?.eventHandler = { [weak self] event in self?.handle(event) }
        if let historyError { log.append(.error, historyError) }
    }

    /// Starts periodic UI publishing, RSSI polling and history saving, and
    /// loads Classic devices the system already knows.
    public func start() {
        guard tickTask == nil else { return }
        log.append(.system, "Bluetooth Inspector started")
        classicClient?.refreshHostController()
        classicClient?.loadKnownDevices()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    public func stop() {
        tickTask?.cancel()
        tickTask = nil
        saveHistoryIfNeeded(force: true)
    }

    /// Periodic work. Public so tests can drive time deterministically.
    public func tick() {
        let date = now()
        refreshDeviceListIfNeeded()
        log.flush()
        for device in devices.values { device.publishHistory() }
        pollRSSIIfNeeded(at: date)
        if date.timeIntervalSince(lastHistorySave) > 2 { saveHistoryIfNeeded() }
    }

    // MARK: Devices

    public func device(_ id: DeviceID) -> InspectedDevice? { devices[id] }

    @discardableResult
    func ensureDevice(_ id: DeviceID, at date: Date) -> InspectedDevice {
        if let existing = devices[id] { return existing }
        let device = InspectedDevice(id: id, firstSeen: date)
        devices[id] = device
        listDirty = true
        return device
    }

    /// Removes disconnected devices from the live list (saved devices stay saved).
    public func clearDiscoveredDevices() {
        devices = devices.filter { $0.value.isConnected || $0.value.connectionState != .disconnected || $0.value.isSystemConnected }
        listDirty = true
        refreshDeviceListIfNeeded()
        log.append(.scan, "Cleared discovered devices")
    }

    func markListDirty() { listDirty = true }

    /// Forces the device table to rebuild (e.g. after SIG names changed).
    public func markAllDevicesChanged() {
        listDirty = true
        refreshDeviceListIfNeeded()
    }

    public func refreshDeviceListIfNeeded(force: Bool = false) {
        guard listDirty || force else { return }
        listDirty = false
        updateDualModeHints()
        var items = devices.values.map(listItem(for:))
        // Saved devices that are not currently present still appear (grey) in Saved Devices.
        for saved in history.all where devices[saved.id] == nil {
            items.append(DeviceListItem(
                id: saved.id, name: saved.name, displayName: saved.displayName, transport: saved.transport,
                rssi: nil, manufacturer: saved.manufacturer, lastSeen: saved.lastSeen,
                isFavorite: saved.isFavorite, isSaved: true, isLive: false, serviceUUIDs: saved.knownServices,
                searchText: saved.notes
            ))
        }
        deviceList = items
    }

    func listItem(for device: InspectedDevice) -> DeviceListItem {
        let saved = history[device.id]
        return DeviceListItem(
            id: device.id,
            name: device.name,
            displayName: saved?.customName ?? device.name,
            transport: device.transport,
            dualModeHint: device.dualModeHint,
            rssi: device.rssi,
            connectionState: device.connectionState == .disconnected && (device.classic?.isConnected ?? false) ? .connected : device.connectionState,
            manufacturer: device.manufacturer,
            lastSeen: device.lastSeen,
            isConnectable: device.advertisement.isConnectable,
            isPaired: device.isPaired,
            isFavorite: saved?.isFavorite ?? false,
            isSaved: saved != nil,
            isSystemConnected: device.isSystemConnected,
            serviceUUIDs: device.knownServiceUUIDs,
            searchText: device.searchText + " " + (saved?.notes ?? "")
        )
    }

    /// See `DualModeHint`: a name match is the only evidence available.
    private func updateDualModeHints() {
        var classicNames: [String: Int] = [:]
        var bleNames: [String: Int] = [:]
        for device in devices.values {
            guard let name = device.name?.lowercased(), !name.isEmpty else { continue }
            switch device.transport {
            case .classic: classicNames[name, default: 0] += 1
            case .lowEnergy: bleNames[name, default: 0] += 1
            }
        }
        for device in devices.values {
            let key = device.name?.lowercased() ?? ""
            let other = device.transport == .classic ? bleNames : classicNames
            let hint: DualModeHint = !key.isEmpty && other[key] != nil ? .matchingName : .none
            if device.dualModeHint != hint { device.dualModeHint = hint }
        }
    }

    // MARK: Scanning

    public func toggleScan() {
        isScanning || pendingScan ? stopScan() : startScan()
    }

    public func startScan() {
        guard powerState == .poweredOn else {
            // CoreBluetooth ignores scan requests until powered on; remember
            // the intent so scanning starts when the state settles.
            pendingScan = powerState == .unknown || powerState == .resetting
            log.append(.error, "Cannot scan: Bluetooth is \(powerState.title.lowercased()). \(powerState.guidance ?? "")")
            return
        }
        pendingScan = false
        let options = settings.scanOptions
        ble.startScan(options: options)
        var description = options.allowDuplicates ? "reporting every advertisement" : "one report per device"
        if !options.serviceUUIDs.isEmpty {
            description += ", filtered to " + options.serviceUUIDs.map(\.shortString).joined(separator: ", ")
        }
        log.append(.scan, "Scan started (\(description))")
    }

    public func stopScan() {
        pendingScan = false
        guard isScanning else { return }
        ble.stopScan()
        log.append(.scan, "Scan stopped")
    }

    public func refreshSystemConnectedPeripherals() {
        let services = settings.systemConnectedServices
        guard !services.isEmpty else {
            log.append(.error, "No service UUIDs configured for retrieving system-connected peripherals")
            return
        }
        ble.retrieveConnectedPeripherals(withServices: services)
    }

    // MARK: Connections

    public func connect(_ id: DeviceID) {
        guard case .lowEnergy(let uuid) = id else {
            log.append(.error, "Classic devices are inspected through SDP; macOS offers no generic Classic connect for apps", deviceID: id)
            return
        }
        guard powerState == .poweredOn else {
            log.append(.error, "Cannot connect: Bluetooth is \(powerState.title.lowercased())", deviceID: id)
            return
        }
        let device = ensureDevice(id, at: now())
        guard device.connectionState == .disconnected else { return }
        device.connectionState = .connecting
        device.lastError = nil
        listDirty = true
        log.append(.connection, "Connecting…", deviceID: id, deviceName: device.name)
        ble.connect(uuid)
        scheduleConnectionTimeout(for: uuid)
    }

    public func disconnect(_ id: DeviceID) {
        guard case .lowEnergy(let uuid) = id, let device = devices[id] else { return }
        connectionTimeouts.removeValue(forKey: uuid)?.cancel()
        guard device.connectionState != .disconnected else { return }
        requestedDisconnects.insert(uuid)
        device.connectionState = .disconnecting
        listDirty = true
        log.append(.connection, "Disconnecting…", deviceID: id, deviceName: device.name)
        ble.disconnect(uuid)
    }

    public func toggleConnection(_ id: DeviceID) {
        guard let device = devices[id] else { return connect(id) }
        device.connectionState == .disconnected ? connect(id) : disconnect(id)
    }

    private func scheduleConnectionTimeout(for uuid: UUID) {
        connectionTimeouts[uuid]?.cancel()
        let timeout = settings.connectionTimeout
        guard timeout > 0 else { return }
        connectionTimeouts[uuid] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.connectionTimedOut(uuid, after: timeout)
        }
    }

    /// Public for tests; normally triggered by the timeout task.
    public func connectionTimedOut(_ uuid: UUID, after timeout: TimeInterval) {
        connectionTimeouts[uuid] = nil
        let id = DeviceID.lowEnergy(uuid)
        guard let device = devices[id], device.connectionState == .connecting else { return }
        device.connectionState = .disconnected
        device.lastError = "Connection timed out after \(Int(timeout)) s. The device may be out of range, not connectable, or already connected to another central."
        listDirty = true
        log.append(.error, device.lastError ?? "Connection timed out", deviceID: id, deviceName: device.name)
        // Cancels the pending CoreBluetooth connection attempt.
        requestedDisconnects.insert(uuid)
        ble.disconnect(uuid)
    }

    private func pollRSSIIfNeeded(at date: Date) {
        let interval = settings.rssiPollInterval
        guard interval > 0, date.timeIntervalSince(lastRSSIPoll) >= interval else { return }
        lastRSSIPoll = date
        for device in devices.values where device.connectionState == .connected {
            if case .lowEnergy(let uuid) = device.id { ble.readRSSI(uuid) }
        }
    }

    // MARK: GATT operations

    public func discoverServices(_ id: DeviceID) {
        guard case .lowEnergy(let uuid) = id, let device = devices[id], device.connectionState == .connected else { return }
        device.gatt.serviceDiscovery = .discovering
        ble.discoverServices(uuid)
    }

    public func read(characteristic: GATTNodeID, on id: DeviceID) {
        guard let (uuid, device, characteristicModel) = resolve(characteristic, on: id, operation: "Read") else { return }
        guard characteristicModel.properties.isReadable else {
            log.append(.error, "\(characteristicModel.uuid.shortString) is not readable (properties: \(characteristicModel.properties.titles.joined(separator: ", ")))",
                       deviceID: id, deviceName: device.name, uuid: characteristicModel.uuid)
            return
        }
        log.append(.read, "Read requested \(characteristicModel.uuid.displayName)", deviceID: id, deviceName: device.name, uuid: characteristicModel.uuid)
        ble.read(characteristic: characteristic, on: uuid)
    }

    /// Reads every readable characteristic of a connected device. Explicit
    /// user action only (it may trigger pairing prompts).
    public func readAll(on id: DeviceID) {
        guard let device = devices[id], device.connectionState == .connected else { return }
        for characteristic in device.gatt.allCharacteristics where characteristic.properties.isReadable {
            read(characteristic: characteristic.id, on: id)
        }
    }

    public func readDescriptor(_ descriptor: GATTNodeID, on id: DeviceID) {
        guard case .lowEnergy(let uuid) = id, let device = devices[id], device.connectionState == .connected,
              let (characteristic, _) = device.gatt.descriptor(descriptor) else { return }
        ble.read(descriptor: descriptor, of: characteristic.id, on: uuid)
    }

    /// Sends bytes to a characteristic. Must only be called from an explicit
    /// user action (see type documentation).
    public func write(_ data: Data, to characteristic: GATTNodeID, on id: DeviceID, type: WriteType) {
        guard let (uuid, device, model) = resolve(characteristic, on: id, operation: "Write") else { return }
        let allowed = type == .withResponse ? model.properties.contains(.write) : model.properties.contains(.writeWithoutResponse)
        guard allowed else {
            log.append(.error, "\(model.uuid.shortString) does not support write \(type.title.lowercased())", deviceID: id, deviceName: device.name, uuid: model.uuid)
            return
        }
        let limit = type == .withResponse ? device.maximumWriteLength : device.maximumWriteWithoutResponseLength
        if let limit, data.count > limit {
            log.append(.error, "Write of \(data.count) bytes exceeds the \(limit)-byte limit for write \(type.title.lowercased())",
                       deviceID: id, deviceName: device.name, uuid: model.uuid, data: data)
            return
        }
        log.append(.write, "Write \(type.title.lowercased()) \(model.uuid.shortString)  \(data.hexString)  (\(data.count) bytes)",
                   deviceID: id, deviceName: device.name, uuid: model.uuid, data: data)
        recordValue(.write, data: data, characteristic: model, on: device)
        ble.write(data, to: characteristic, on: uuid, type: type)
    }

    public func setNotify(_ enabled: Bool, for characteristic: GATTNodeID, on id: DeviceID) {
        guard let (uuid, device, model) = resolve(characteristic, on: id, operation: enabled ? "Subscribe" : "Unsubscribe") else { return }
        guard model.properties.canSubscribe else {
            log.append(.error, "\(model.uuid.shortString) supports neither notify nor indicate", deviceID: id, deviceName: device.name, uuid: model.uuid)
            return
        }
        log.append(.notify, "\(enabled ? "Subscribing to" : "Unsubscribing from") \(model.uuid.displayName)", deviceID: id, deviceName: device.name, uuid: model.uuid)
        ble.setNotify(enabled, for: characteristic, on: uuid)
    }

    private func resolve(_ characteristic: GATTNodeID, on id: DeviceID, operation: String) -> (UUID, InspectedDevice, GATTCharacteristic)? {
        guard case .lowEnergy(let uuid) = id, let device = devices[id] else { return nil }
        guard device.connectionState == .connected else {
            log.append(.error, "\(operation) failed: device is not connected", deviceID: id, deviceName: device.name)
            return nil
        }
        guard let model = device.gatt.characteristic(characteristic) else {
            log.append(.error, "\(operation) failed: characteristic no longer exists (services may have changed)", deviceID: id, deviceName: device.name)
            return nil
        }
        return (uuid, device, model)
    }

    func recordValue(_ kind: ValueRecord.Kind, data: Data, characteristic: GATTCharacteristic, on device: InspectedDevice, at date: Date? = nil) {
        let decoded = decoders.decode(characteristic: characteristic.uuid, data: data, presentationFormat: characteristic.presentationFormat)
        device.appendValue(ValueRecord(id: valueRecordID, timestamp: date ?? now(), kind: kind, characteristicID: characteristic.id,
                                       characteristicUUID: characteristic.uuid, data: data, decodedSummary: decoded?.summary))
        valueRecordID += 1
    }

    /// Decoded interpretation of a characteristic's current value.
    public func decodedValue(of characteristic: GATTCharacteristic) -> DecodedValue? {
        guard let value = characteristic.value else { return nil }
        return decoders.decode(characteristic: characteristic.uuid, data: value, presentationFormat: characteristic.presentationFormat)
    }

    public func decodedValue(of descriptor: GATTDescriptor) -> DecodedValue? {
        guard let value = descriptor.value else { return nil }
        return decoders.decode(descriptor: descriptor.uuid, data: value.data)
    }

    // MARK: Classic

    public func startInquiry() {
        guard let classicClient else { return }
        classicClient.startInquiry(duration: settings.classicInquiryDuration)
    }

    public func stopInquiry() {
        classicClient?.stopInquiry()
    }

    public func toggleInquiry() {
        isInquiryRunning ? stopInquiry() : startInquiry()
    }

    public func reloadClassicDevices() {
        classicClient?.refreshHostController()
        classicClient?.loadKnownDevices()
    }

    public func performSDPQuery(_ id: DeviceID) {
        guard case .classic(let address) = id, let classicClient else { return }
        devices[id]?.isSDPQueryRunning = true
        classicClient.performSDPQuery(address: address)
    }

    // MARK: History

    public func setFavorite(_ id: DeviceID, _ isFavorite: Bool) {
        ensureSaved(id)
        history.setFavorite(id, isFavorite)
        historyChanged()
    }

    public func rename(_ id: DeviceID, to name: String?) {
        ensureSaved(id)
        history.rename(id, to: name)
        historyChanged()
    }

    public func setNotes(_ id: DeviceID, _ notes: String) {
        ensureSaved(id)
        history.setNotes(id, notes)
        historyChanged()
    }

    public func forget(_ id: DeviceID) {
        history.forget(id)
        historyChanged()
        log.append(.system, "Forgot saved device", deviceID: id)
    }

    public func forgetAllSavedDevices() {
        history.forgetAll()
        historyChanged()
        log.append(.system, "Forgot all saved devices")
    }

    /// Saving a device explicitly (favorite, rename, notes) always works, even
    /// when automatic history is off.
    private func ensureSaved(_ id: DeviceID) {
        guard history[id] == nil else { return }
        let device = devices[id]
        history.record(id: id, name: device?.name, transport: id.transport, services: device?.knownServiceUUIDs ?? [],
                       manufacturer: device?.manufacturer, at: device?.lastSeen ?? now())
    }

    func remember(_ device: InspectedDevice, reason: HistoryMode) {
        switch settings.historyMode {
        case .off: return
        case .connectedAndFavorites:
            guard reason == .connectedAndFavorites || history[device.id] != nil else { return }
        case .everything: break
        }
        history.record(id: device.id, name: device.name, transport: device.transport, services: device.knownServiceUUIDs,
                       manufacturer: device.manufacturer, at: device.lastSeen ?? now())
        historyDirty = true
    }

    private func historyChanged() {
        historyDirty = true
        listDirty = true
        saveHistoryIfNeeded(force: true)
        refreshDeviceListIfNeeded()
    }

    public func saveHistoryIfNeeded(force: Bool = false) {
        guard historyDirty, let historyStore else { return }
        do {
            try historyStore.save(history)
            historyDirty = false
            historyError = nil
            lastHistorySave = now()
        } catch {
            if historyError == nil || force {
                historyError = "Could not save devices: \(error.localizedDescription)"
                log.append(.error, historyError ?? "")
            }
        }
    }

    // MARK: Settings

    private func applySettings(oldValue: InspectorSettings) {
        if settings.logCapacity != oldValue.logCapacity {
            log.setCapacity(settings.logCapacity)
        }
        if settings.scanOptions != oldValue.scanOptions, isScanning {
            // Scan options only take effect when a scan starts.
            ble.stopScan()
            ble.startScan(options: settings.scanOptions)
            log.append(.scan, "Scan restarted with new options")
        }
    }

    // MARK: Internal helpers for event handling

    func cancelConnectionTimeout(_ uuid: UUID) {
        connectionTimeouts.removeValue(forKey: uuid)?.cancel()
    }

    func consumeRequestedDisconnect(_ uuid: UUID) -> Bool {
        requestedDisconnects.remove(uuid) != nil
    }

    func setPowerState(_ state: BluetoothPowerState, authorization: BluetoothAuthorization) {
        let changed = state != powerState
        powerState = state
        self.authorization = authorization
        guard changed else { return }
        log.append(state == .poweredOn ? .system : .error, "Bluetooth state: \(state.title)" + (state.guidance.map { ". \($0)" } ?? ""))
        if state != .poweredOn {
            isScanning = false
            // CoreBluetooth invalidates every connection when the radio goes away.
            for device in devices.values where device.connectionState != .disconnected {
                device.connectionState = .disconnected
                device.gatt.clearNotifications()
            }
            listDirty = true
        } else if pendingScan {
            startScan()
        }
    }

    func setScanning(_ scanning: Bool) {
        isScanning = scanning
        scanStartedAt = scanning ? now() : nil
    }

    func setInquiryRunning(_ running: Bool) { isInquiryRunning = running }
    func setHostController(_ info: HostControllerInfo) { hostController = info }

    func shouldLogAdvertisementChange(for id: DeviceID, at date: Date) -> Bool {
        guard settings.logAdvertisementChanges else { return false }
        if let last = lastAdvertisementLog[id], date.timeIntervalSince(last) < 1 { return false }
        lastAdvertisementLog[id] = date
        return true
    }
}
