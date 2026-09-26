import BluetoothInspectorKit
import CoreBluetooth
import Foundation
import OSLog

/// `BLEClient` backed by CoreBluetooth.
///
/// The central manager is created with `queue: nil`, so CoreBluetooth calls
/// every delegate method on the main queue. That is what makes it safe for
/// this main-actor type to adopt the delegate protocols with
/// `@preconcurrency` (the runtime still checks isolation on each call).
///
/// CoreBluetooth hands out reference-type `CBService`/`CBCharacteristic`/
/// `CBDescriptor` objects and exposes no ATT handles. The client mints a
/// `GATTNodeID` per object and keeps the objects here, so the rest of the app
/// only ever deals with value types.
@MainActor
final class CoreBluetoothClient: NSObject, BLEClient {
    var eventHandler: (@MainActor (BLEEvent) -> Void)?
    private(set) var isScanning = false

    private let logger = Logger(subsystem: AppLogger.subsystem, category: "CoreBluetooth")
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]

    private var nodeIDs: [ObjectIdentifier: GATTNodeID] = [:]
    private var services: [GATTNodeID: CBService] = [:]
    private var characteristics: [GATTNodeID: CBCharacteristic] = [:]
    private var descriptors: [GATTNodeID: CBDescriptor] = [:]
    private var nodesByPeripheral: [UUID: Set<GATTNodeID>] = [:]
    /// Services whose characteristics were already requested (included
    /// services can be reported by several parents).
    private var characteristicDiscoveryRequested: Set<GATTNodeID> = []
    /// Outstanding reads per characteristic, used to tell read responses from
    /// notifications: CoreBluetooth reports both via `didUpdateValueFor`.
    private var pendingReads: [GATTNodeID: Int] = [:]

    override init() {
        super.init()
        // Creating the manager triggers the Bluetooth privacy prompt on first launch.
        central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    var powerState: BluetoothPowerState {
        central.map { CoreBluetoothMapping.powerState($0.state) } ?? .unknown
    }

    var authorization: BluetoothAuthorization {
        CoreBluetoothMapping.authorization(CBManager.authorization)
    }

    fileprivate func emit(_ event: BLEEvent) {
        eventHandler?(event)
    }

    // MARK: Scanning

    func startScan(options: ScanOptions) {
        guard let central, central.state == .poweredOn else {
            emit(.operationFailed(peripheral: nil, operation: "Scan", error: "Bluetooth is not powered on"))
            return
        }
        var scanOptions: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: options.allowDuplicates]
        if !options.solicitedServiceUUIDs.isEmpty {
            scanOptions[CBCentralManagerScanOptionSolicitedServiceUUIDsKey] = options.solicitedServiceUUIDs.map(CoreBluetoothMapping.cbuuid)
        }
        let services = options.serviceUUIDs.isEmpty ? nil : options.serviceUUIDs.map(CoreBluetoothMapping.cbuuid)
        central.scanForPeripherals(withServices: services, options: scanOptions)
        isScanning = true
        logger.debug("Scan started")
        emit(.scanStateChanged(isScanning: true))
    }

    func stopScan() {
        central?.stopScan()
        isScanning = false
        emit(.scanStateChanged(isScanning: false))
    }

    func retrieveConnectedPeripherals(withServices services: [BluetoothUUID]) {
        guard let central, central.state == .poweredOn else { return }
        let found = central.retrieveConnectedPeripherals(withServices: services.map(CoreBluetoothMapping.cbuuid))
        for peripheral in found {
            track(peripheral)
            emit(.retrievedConnected(peripheral: peripheral.identifier, name: peripheral.name))
        }
        if found.isEmpty {
            logger.info("No system-connected peripherals expose the requested services")
        }
    }

    // MARK: Connections

    func connect(_ identifier: UUID) {
        guard let central else { return }
        guard let peripheral = peripherals[identifier] ?? central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            emit(.connectionFailed(peripheral: identifier, error: "CoreBluetooth no longer knows this peripheral. Scan again so it can be rediscovered."))
            return
        }
        track(peripheral)
        central.connect(peripheral, options: nil)
        emit(.connecting(peripheral: identifier))
    }

    func disconnect(_ identifier: UUID) {
        guard let central, let peripheral = peripherals[identifier] else {
            emit(.disconnected(peripheral: identifier, error: nil))
            return
        }
        let wasConnected = peripheral.state == .connected || peripheral.state == .disconnecting
        central.cancelPeripheralConnection(peripheral)
        // Cancelling a *pending* connection does not produce a disconnect
        // callback, so report it ourselves.
        if !wasConnected {
            forgetNodes(of: identifier)
            emit(.disconnected(peripheral: identifier, error: nil))
        }
    }

    func readRSSI(_ identifier: UUID) {
        guard let peripheral = peripherals[identifier], peripheral.state == .connected else { return }
        peripheral.readRSSI()
    }

    private func track(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripherals[peripheral.identifier] = peripheral
    }

    // MARK: GATT

    func discoverServices(_ identifier: UUID) {
        guard let peripheral = connectedPeripheral(identifier, operation: "Service discovery") else { return }
        peripheral.discoverServices(nil)
    }

    func read(characteristic id: GATTNodeID, on identifier: UUID) {
        guard let peripheral = connectedPeripheral(identifier, operation: "Read"),
              let characteristic = characteristics[id] else { return missing(id, identifier, "Read") }
        pendingReads[id, default: 0] += 1
        peripheral.readValue(for: characteristic)
    }

    func write(_ data: Data, to id: GATTNodeID, on identifier: UUID, type: WriteType) {
        guard let peripheral = connectedPeripheral(identifier, operation: "Write"),
              let characteristic = characteristics[id] else { return missing(id, identifier, "Write") }
        switch type {
        case .withResponse:
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        case .withoutResponse:
            // Writes without response are queued in the controller; when the
            // queue is full CoreBluetooth silently drops further writes, so
            // refuse instead of pretending the bytes went out.
            guard peripheral.canSendWriteWithoutResponse else {
                emit(.operationFailed(peripheral: identifier, operation: "Write without response",
                                      error: "The write-without-response queue is full. Wait a moment and send again."))
                return
            }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            emit(.writeWithoutResponseSent(peripheral: identifier, characteristicID: id))
        }
    }

    func setNotify(_ enabled: Bool, for id: GATTNodeID, on identifier: UUID) {
        guard let peripheral = connectedPeripheral(identifier, operation: "Subscribe"),
              let characteristic = characteristics[id] else { return missing(id, identifier, "Subscribe") }
        peripheral.setNotifyValue(enabled, for: characteristic)
    }

    func read(descriptor id: GATTNodeID, of characteristicID: GATTNodeID, on identifier: UUID) {
        guard let peripheral = connectedPeripheral(identifier, operation: "Descriptor read"),
              let descriptor = descriptors[id] else { return missing(id, identifier, "Descriptor read") }
        peripheral.readValue(for: descriptor)
    }

    private func connectedPeripheral(_ identifier: UUID, operation: String) -> CBPeripheral? {
        guard let peripheral = peripherals[identifier], peripheral.state == .connected else {
            emit(.operationFailed(peripheral: identifier, operation: operation, error: "The peripheral is not connected"))
            return nil
        }
        return peripheral
    }

    private func missing(_ id: GATTNodeID, _ identifier: UUID, _ operation: String) {
        guard peripherals[identifier]?.state == .connected else { return }
        emit(.operationFailed(peripheral: identifier, operation: operation,
                              error: "The attribute is no longer available (the peripheral may have changed its services)"))
    }

    // MARK: Node bookkeeping

    fileprivate func nodeID(for object: AnyObject, peripheral: UUID) -> GATTNodeID {
        let key = ObjectIdentifier(object)
        if let existing = nodeIDs[key] { return existing }
        let id = GATTNodeID()
        nodeIDs[key] = id
        nodesByPeripheral[peripheral, default: []].insert(id)
        return id
    }

    fileprivate func model(for service: CBService, peripheral: UUID) -> GATTService? {
        guard let uuid = CoreBluetoothMapping.uuid(service.uuid) else { return nil }
        let id = nodeID(for: service, peripheral: peripheral)
        services[id] = service
        return GATTService(id: id, uuid: uuid, isPrimary: service.isPrimary)
    }

    fileprivate func model(for characteristic: CBCharacteristic, serviceID: GATTNodeID, peripheral: UUID) -> GATTCharacteristic? {
        guard let uuid = CoreBluetoothMapping.uuid(characteristic.uuid) else { return nil }
        let id = nodeID(for: characteristic, peripheral: peripheral)
        characteristics[id] = characteristic
        return GATTCharacteristic(id: id, serviceID: serviceID, uuid: uuid,
                                  properties: GATTProperties(rawValue: characteristic.properties.rawValue),
                                  value: characteristic.value, isNotifying: characteristic.isNotifying)
    }

    fileprivate func model(for descriptor: CBDescriptor, peripheral: UUID) -> GATTDescriptor? {
        guard let uuid = CoreBluetoothMapping.uuid(descriptor.uuid) else { return nil }
        let id = nodeID(for: descriptor, peripheral: peripheral)
        descriptors[id] = descriptor
        return GATTDescriptor(id: id, uuid: uuid, value: CoreBluetoothMapping.descriptorValue(descriptor.value))
    }

    fileprivate func existingID(for object: AnyObject) -> GATTNodeID? {
        nodeIDs[ObjectIdentifier(object)]
    }

    fileprivate func requestCharacteristics(for service: CBService, id: GATTNodeID, on peripheral: CBPeripheral) {
        guard characteristicDiscoveryRequested.insert(id).inserted else { return }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    /// Drops every CoreBluetooth object of a peripheral (after disconnect the
    /// objects are stale and a reconnect produces new ones).
    fileprivate func forgetNodes(of identifier: UUID) {
        guard let ids = nodesByPeripheral.removeValue(forKey: identifier) else { return }
        for id in ids {
            if let service = services.removeValue(forKey: id) { nodeIDs[ObjectIdentifier(service)] = nil }
            if let characteristic = characteristics.removeValue(forKey: id) { nodeIDs[ObjectIdentifier(characteristic)] = nil }
            if let descriptor = descriptors.removeValue(forKey: id) { nodeIDs[ObjectIdentifier(descriptor)] = nil }
            characteristicDiscoveryRequested.remove(id)
            pendingReads[id] = nil
        }
    }

    fileprivate func consumePendingRead(_ id: GATTNodeID) -> Bool {
        guard let count = pendingReads[id], count > 0 else { return false }
        pendingReads[id] = count == 1 ? nil : count - 1
        return true
    }

    fileprivate func invalidate(_ invalidated: [CBService], on peripheral: CBPeripheral) -> [GATTNodeID] {
        invalidated.compactMap { service in
            guard let id = existingID(for: service) else { return nil }
            services[id] = nil
            characteristicDiscoveryRequested.remove(id)
            return id
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothClient: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = CoreBluetoothMapping.powerState(central.state)
        logger.info("Central state \(state.rawValue, privacy: .public)")
        if central.state != .poweredOn {
            // Scans and connections do not survive a power cycle.
            if isScanning {
                isScanning = false
                emit(.scanStateChanged(isScanning: false))
            }
            for identifier in peripherals.keys { forgetNodes(of: identifier) }
        }
        emit(.stateChanged(state, authorization))
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if peripherals[peripheral.identifier] == nil { track(peripheral) }
        emit(.discovered(peripheral: peripheral.identifier, name: peripheral.name,
                         advertisement: CoreBluetoothMapping.advertisement(advertisementData),
                         rssi: RSSI.intValue, at: Date()))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit(.connected(peripheral: peripheral.identifier,
                        maximumWriteLength: peripheral.maximumWriteValueLength(for: .withResponse),
                        maximumWriteWithoutResponseLength: peripheral.maximumWriteValueLength(for: .withoutResponse)))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        emit(.connectionFailed(peripheral: peripheral.identifier,
                               error: CoreBluetoothMapping.describe(error) ?? "Unknown error"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        forgetNodes(of: peripheral.identifier)
        emit(.disconnected(peripheral: peripheral.identifier, error: CoreBluetoothMapping.describe(error)))
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothClient: @preconcurrency CBPeripheralDelegate {
    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        emit(.nameUpdated(peripheral: peripheral.identifier, name: peripheral.name))
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: (any Error)?) {
        emit(.rssiRead(peripheral: peripheral.identifier, rssi: error == nil ? RSSI.intValue : nil,
                       error: CoreBluetoothMapping.describe(error), at: Date()))
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        let ids = invalidate(invalidatedServices, on: peripheral)
        emit(.servicesInvalidated(peripheral: peripheral.identifier, serviceIDs: ids))
        // Rediscover everything: replacement services may have new UUIDs.
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        let identifier = peripheral.identifier
        let found = peripheral.services ?? []
        let models = found.compactMap { model(for: $0, peripheral: identifier) }
        emit(.servicesDiscovered(peripheral: identifier, services: models, error: CoreBluetoothMapping.describe(error)))
        guard error == nil else { return }
        for service in found {
            guard let id = existingID(for: service) else { continue }
            // Secondary services are only reachable as included services.
            peripheral.discoverIncludedServices(nil, for: service)
            requestCharacteristics(for: service, id: id, on: peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: (any Error)?) {
        let identifier = peripheral.identifier
        guard let parentID = existingID(for: service) else { return }
        let included = service.includedServices ?? []
        let models = included.compactMap { model(for: $0, peripheral: identifier) }
        emit(.includedServicesDiscovered(peripheral: identifier, serviceID: parentID, included: models,
                                         error: CoreBluetoothMapping.describe(error)))
        for includedService in included {
            if let id = existingID(for: includedService) {
                requestCharacteristics(for: includedService, id: id, on: peripheral)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        let identifier = peripheral.identifier
        guard let serviceID = existingID(for: service) else { return }
        let found = service.characteristics ?? []
        let models = found.compactMap { model(for: $0, serviceID: serviceID, peripheral: identifier) }
        emit(.characteristicsDiscovered(peripheral: identifier, serviceID: serviceID, characteristics: models,
                                        error: CoreBluetoothMapping.describe(error)))
        guard error == nil else { return }
        for characteristic in found {
            peripheral.discoverDescriptors(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: (any Error)?) {
        let identifier = peripheral.identifier
        guard let characteristicID = existingID(for: characteristic) else { return }
        let models = (characteristic.descriptors ?? []).compactMap { model(for: $0, peripheral: identifier) }
        emit(.descriptorsDiscovered(peripheral: identifier, characteristicID: characteristicID, descriptors: models,
                                    error: CoreBluetoothMapping.describe(error)))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let id = existingID(for: characteristic) else { return }
        let wasRead = consumePendingRead(id)
        emit(.valueUpdated(peripheral: peripheral.identifier, characteristicID: id, value: characteristic.value,
                           isNotification: !wasRead, error: CoreBluetoothMapping.describe(error), at: Date()))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: (any Error)?) {
        guard let id = existingID(for: descriptor), let characteristic = descriptor.characteristic,
              let characteristicID = existingID(for: characteristic) else { return }
        emit(.descriptorValueUpdated(peripheral: peripheral.identifier, characteristicID: characteristicID, descriptorID: id,
                                     value: CoreBluetoothMapping.descriptorValue(descriptor.value),
                                     error: CoreBluetoothMapping.describe(error)))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let id = existingID(for: characteristic) else { return }
        emit(.writeCompleted(peripheral: peripheral.identifier, characteristicID: id, error: CoreBluetoothMapping.describe(error)))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let id = existingID(for: characteristic) else { return }
        emit(.notificationStateChanged(peripheral: peripheral.identifier, characteristicID: id,
                                       isNotifying: characteristic.isNotifying, error: CoreBluetoothMapping.describe(error)))
    }
}
