import Foundation

extension BluetoothWorkspace {
    /// Applies one event from the BLE client. Public so recorded or scripted
    /// events can be replayed (tests, future capture replay).
    public func handle(_ event: BLEEvent) {
        switch event {
        case .stateChanged(let state, let authorization):
            setPowerState(state, authorization: authorization)

        case .scanStateChanged(let scanning):
            setScanning(scanning)

        case .discovered(let uuid, let name, let advertisement, let rssi, let date):
            handleDiscovery(uuid, name: name, advertisement: advertisement, rssi: rssi, at: date)

        case .retrievedConnected(let uuid, let name):
            let id = DeviceID.lowEnergy(uuid)
            let isNew = device(id) == nil
            let device = ensureDevice(id, at: now())
            device.systemName = name ?? device.systemName
            if !device.isSystemConnected || isNew {
                device.isSystemConnected = true
                log.append(.connection, "System-connected peripheral found", deviceID: id, deviceName: device.name)
            }
            device.lastSeen = device.lastSeen ?? now()
            markListDirty()

        case .connecting(let uuid):
            device(.lowEnergy(uuid))?.connectionState = .connecting
            markListDirty()

        case .connected(let uuid, let maxWrite, let maxWriteWithoutResponse):
            handleConnected(uuid, maxWrite: maxWrite, maxWriteWithoutResponse: maxWriteWithoutResponse)

        case .connectionFailed(let uuid, let error):
            cancelConnectionTimeout(uuid)
            let id = DeviceID.lowEnergy(uuid)
            let device = ensureDevice(id, at: now())
            device.connectionState = .disconnected
            device.lastError = "Failed to connect: \(error)"
            log.append(.error, device.lastError ?? error, deviceID: id, deviceName: device.name)
            markListDirty()

        case .disconnected(let uuid, let error):
            handleDisconnected(uuid, error: error)

        case .nameUpdated(let uuid, let name):
            guard let device = device(.lowEnergy(uuid)) else { return }
            device.systemName = name
            log.append(.connection, "GAP name is now “\(name ?? "none")”", deviceID: device.id, deviceName: device.name)
            markListDirty()

        case .rssiRead(let uuid, let rssi, let error, let date):
            guard let device = device(.lowEnergy(uuid)) else { return }
            if let error {
                log.append(.error, "RSSI read failed: \(error)", deviceID: device.id, deviceName: device.name)
            } else if let rssi, device.rssiHistory.record(rssi, at: date) {
                device.rssi = rssi
                device.lastSeen = date
                if settings.logRSSIReadings {
                    log.append(.rssi, "\(rssi) dBm", deviceID: device.id, deviceName: device.name, at: date)
                }
                markListDirty()
            }

        case .servicesDiscovered(let uuid, let services, let error):
            handleServicesDiscovered(uuid, services: services, error: error)

        case .servicesInvalidated(let uuid, let serviceIDs):
            guard let device = device(.lowEnergy(uuid)) else { return }
            device.gatt.remove(serviceIDs: Set(serviceIDs))
            log.append(.service, "Peripheral changed its services (\(serviceIDs.count) invalidated); rediscovering",
                       deviceID: device.id, deviceName: device.name)

        case .includedServicesDiscovered(let uuid, let serviceID, let included, let error):
            guard let device = device(.lowEnergy(uuid)) else { return }
            if let error {
                log.append(.error, "Included service discovery failed: \(error)", deviceID: device.id, deviceName: device.name)
                return
            }
            device.gatt.upsert(services: included)
            device.gatt.setIncludedServices(included.map(\.id), for: serviceID)
            for service in included {
                log.append(.service, "\(service.isPrimary ? "Included" : "Secondary") service \(service.uuid.displayName)",
                           deviceID: device.id, deviceName: device.name, uuid: service.uuid)
            }

        case .characteristicsDiscovered(let uuid, let serviceID, let characteristics, let error):
            handleCharacteristicsDiscovered(uuid, serviceID: serviceID, characteristics: characteristics, error: error)

        case .descriptorsDiscovered(let uuid, let characteristicID, let descriptors, let error):
            guard let device = device(.lowEnergy(uuid)) else { return }
            if let error {
                device.gatt.setError("Descriptor discovery failed: \(error)", for: characteristicID)
                log.append(.error, "Descriptor discovery failed: \(error)", deviceID: device.id, deviceName: device.name)
                return
            }
            device.gatt.setDescriptors(descriptors, for: characteristicID)
            if settings.autoReadDescriptors {
                for descriptor in descriptors { ble.read(descriptor: descriptor.id, of: characteristicID, on: uuid) }
            }

        case .valueUpdated(let uuid, let characteristicID, let value, let isNotification, let error, let date):
            handleValue(uuid, characteristicID: characteristicID, value: value, isNotification: isNotification, error: error, at: date)

        case .descriptorValueUpdated(let uuid, let characteristicID, let descriptorID, let value, let error):
            guard let device = device(.lowEnergy(uuid)) else { return }
            device.gatt.setDescriptorValue(value, error: error, descriptorID: descriptorID, characteristicID: characteristicID)
            if let error, let (_, descriptor) = device.gatt.descriptor(descriptorID) {
                log.append(.error, "Descriptor \(descriptor.uuid.shortString) read failed: \(error)", deviceID: device.id,
                           deviceName: device.name, uuid: descriptor.uuid)
            }

        case .writeCompleted(let uuid, let characteristicID, let error):
            guard let device = device(.lowEnergy(uuid)) else { return }
            let characteristicUUID = device.gatt.characteristic(characteristicID)?.uuid
            if let error {
                device.gatt.setError("Write failed: \(error)", for: characteristicID)
                log.append(.error, "Write to \(characteristicUUID?.shortString ?? "characteristic") failed: \(error)",
                           deviceID: device.id, deviceName: device.name, uuid: characteristicUUID)
            } else {
                device.gatt.setError(nil, for: characteristicID)
                log.append(.write, "Write acknowledged by \(characteristicUUID?.shortString ?? "characteristic")",
                           deviceID: device.id, deviceName: device.name, uuid: characteristicUUID)
            }

        case .writeWithoutResponseSent(let uuid, let characteristicID):
            guard let device = device(.lowEnergy(uuid)) else { return }
            let characteristicUUID = device.gatt.characteristic(characteristicID)?.uuid
            log.append(.write, "Write without response sent to \(characteristicUUID?.shortString ?? "characteristic") (no acknowledgement exists for this write type)",
                       deviceID: device.id, deviceName: device.name, uuid: characteristicUUID)

        case .notificationStateChanged(let uuid, let characteristicID, let isNotifying, let error):
            guard let device = device(.lowEnergy(uuid)) else { return }
            let characteristicUUID = device.gatt.characteristic(characteristicID)?.uuid
            if let error {
                device.gatt.setError("Subscription change failed: \(error)", for: characteristicID)
                log.append(.error, "Notification state change for \(characteristicUUID?.shortString ?? "characteristic") failed: \(error)",
                           deviceID: device.id, deviceName: device.name, uuid: characteristicUUID)
            } else {
                log.append(.notify, "\(isNotifying ? "Subscribed to" : "Unsubscribed from") \(characteristicUUID?.displayName ?? "characteristic")",
                           deviceID: device.id, deviceName: device.name, uuid: characteristicUUID)
            }
            device.gatt.setNotifying(isNotifying, for: characteristicID)

        case .operationFailed(let uuid, let operation, let error):
            let id = uuid.map(DeviceID.lowEnergy)
            if let id { device(id)?.lastError = "\(operation) failed: \(error)" }
            log.append(.error, "\(operation) failed: \(error)", deviceID: id, deviceName: id.flatMap { device($0)?.name })
        }
    }

    private func handleDiscovery(_ uuid: UUID, name: String?, advertisement: AdvertisementData, rssi: Int?, at date: Date) {
        let id = DeviceID.lowEnergy(uuid)
        let isNew = device(id) == nil
        let device = ensureDevice(id, at: date)
        if let name { device.systemName = name }
        let merged = device.advertisement.merging(advertisement)
        let changed = !isNew && merged != device.advertisement
        device.advertisement = merged
        device.appendPacket(AdvertisementPacket(timestamp: date, rssi: rssi, advertisement: advertisement))
        device.advertisementPacketCount += 1
        device.lastSeen = date
        if let rssi, device.rssiHistory.record(rssi, at: date) {
            device.rssi = rssi
        }
        if isNew {
            log.append(.scan, "Found \(device.displayName)" + (merged.isConnectable == false ? " (non-connectable)" : ""),
                       deviceID: id, deviceName: device.name, at: date)
            if let rssi, RSSISample.isValid(rssi) {
                log.append(.rssi, "\(rssi) dBm", deviceID: id, deviceName: device.name, at: date)
            }
        } else if changed {
            device.advertisementChangeCount += 1
            device.lastAdvertisementChange = date
            if shouldLogAdvertisementChange(for: id, at: date) {
                log.append(.scan, "Advertisement changed", deviceID: id, deviceName: device.name,
                           data: advertisement.manufacturerData, at: date)
            }
        }
        if isNew || changed { remember(device, reason: .everything) }
        markListDirty()
    }

    private func handleConnected(_ uuid: UUID, maxWrite: Int, maxWriteWithoutResponse: Int) {
        cancelConnectionTimeout(uuid)
        let id = DeviceID.lowEnergy(uuid)
        let device = ensureDevice(id, at: now())
        device.connectionState = .connected
        device.connectedAt = now()
        device.lastError = nil
        device.maximumWriteLength = maxWrite
        device.maximumWriteWithoutResponseLength = maxWriteWithoutResponse
        log.append(.connection, "Connected (max write \(maxWrite) B with response, \(maxWriteWithoutResponse) B without)",
                   deviceID: id, deviceName: device.name)
        remember(device, reason: .connectedAndFavorites)
        markListDirty()
        discoverServices(id)
    }

    private func handleDisconnected(_ uuid: UUID, error: String?) {
        cancelConnectionTimeout(uuid)
        let requested = consumeRequestedDisconnect(uuid)
        let id = DeviceID.lowEnergy(uuid)
        guard let device = device(id) else { return }
        let wasConnected = device.connectionState == .connected || device.connectionState == .disconnecting
        device.connectionState = .disconnected
        device.connectedAt = nil
        device.isSystemConnected = false
        device.gatt.clearNotifications()
        if let error, !requested {
            device.lastError = "Disconnected: \(error)"
            log.append(.error, "Disconnected unexpectedly: \(error)", deviceID: id, deviceName: device.name)
        } else if wasConnected || requested {
            log.append(.connection, "Disconnected", deviceID: id, deviceName: device.name)
        }
        markListDirty()
    }

    private func handleServicesDiscovered(_ uuid: UUID, services: [GATTService], error: String?) {
        guard let device = device(.lowEnergy(uuid)) else { return }
        if let error {
            device.gatt.serviceDiscovery = .failed
            device.gatt.lastError = error
            log.append(.error, "Service discovery failed: \(error)", deviceID: device.id, deviceName: device.name)
            return
        }
        device.gatt.upsert(services: services)
        device.gatt.serviceDiscovery = .complete
        device.gatt.lastError = nil
        if services.isEmpty {
            log.append(.service, "No services visible (macOS hides some system services, e.g. HID 1812)", deviceID: device.id, deviceName: device.name)
        }
        for service in services {
            log.append(.service, service.uuid.displayName, deviceID: device.id, deviceName: device.name, uuid: service.uuid)
        }
        remember(device, reason: .connectedAndFavorites)
        markListDirty()
    }

    private func handleCharacteristicsDiscovered(_ uuid: UUID, serviceID: GATTNodeID, characteristics: [GATTCharacteristic], error: String?) {
        guard let device = device(.lowEnergy(uuid)) else { return }
        let serviceUUID = device.gatt.service(serviceID)?.uuid
        if let error {
            device.gatt.setServiceState(.failed, error: error, for: serviceID)
            log.append(.error, "Characteristic discovery for \(serviceUUID?.shortString ?? "service") failed: \(error)",
                       deviceID: device.id, deviceName: device.name, uuid: serviceUUID)
            return
        }
        device.gatt.setCharacteristics(characteristics, for: serviceID)
        if let maximum = device.maximumWriteLength, let withoutResponse = device.maximumWriteWithoutResponseLength {
            device.gatt.setWriteLimits(withResponse: maximum, withoutResponse: withoutResponse)
        }
        for characteristic in characteristics {
            let properties = characteristic.properties.descriptors.map(\.shortTitle).joined(separator: " ")
            log.append(.service, "  \(characteristic.uuid.displayName) [\(properties)]", deviceID: device.id,
                       deviceName: device.name, uuid: characteristic.uuid)
            if settings.autoReadCharacteristics, characteristic.properties.isReadable {
                ble.read(characteristic: characteristic.id, on: uuid)
            }
        }
        markListDirty()
    }

    private func handleValue(_ uuid: UUID, characteristicID: GATTNodeID, value: Data?, isNotification: Bool, error: String?, at date: Date) {
        guard let device = device(.lowEnergy(uuid)), let characteristic = device.gatt.characteristic(characteristicID) else { return }
        if let error {
            device.gatt.setError("\(isNotification ? "Update" : "Read") failed: \(error)", for: characteristicID)
            log.append(.error, "Read \(characteristic.uuid.shortString) failed: \(error)", deviceID: device.id,
                       deviceName: device.name, uuid: characteristic.uuid)
            return
        }
        let data = value ?? Data()
        device.gatt.updateValue(data, at: date, for: characteristicID)
        recordValue(isNotification ? .notification : .read, data: data, characteristic: characteristic, on: device, at: date)
        let category: EventCategory = isNotification ? .notify : .read
        log.append(category, "\(characteristic.uuid.shortString)  \(data.isEmpty ? "(empty)" : data.hexString)",
                   deviceID: device.id, deviceName: device.name, uuid: characteristic.uuid, data: data, at: date)
        let updated = device.gatt.characteristic(characteristicID) ?? characteristic
        if let decoded = decoders.decode(characteristic: updated.uuid, data: data, presentationFormat: updated.presentationFormat) {
            log.append(.decode, decoded.summary, deviceID: device.id, deviceName: device.name, uuid: characteristic.uuid, at: date)
        }
        if characteristic.uuid == BluetoothUUID(uint16: 0x2A29) || characteristic.uuid == BluetoothUUID(uint16: 0x2A50) {
            // Manufacturer information changed; refresh the table and history.
            remember(device, reason: .connectedAndFavorites)
            markListDirty()
        }
    }
}
