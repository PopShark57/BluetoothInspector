import Foundation

extension BluetoothWorkspace {
    public func handle(_ event: ClassicEvent) {
        switch event {
        case .hostControllerUpdated(let info):
            setHostController(info)

        case .inquiryStarted:
            setInquiryRunning(true)
            log.append(.classic, "Classic inquiry started")

        case .inquiryDeviceFound(let info):
            let alreadyInquired = device(.classic(address: info.address))?.classic?.sources.contains(.inquiry) ?? false
            let device = apply(info)
            if !alreadyInquired {
                log.append(.classic, "Inquiry found \(device.displayName) \(info.classOfDevice.map { "(\($0.majorName))" } ?? "")",
                           deviceID: device.id, deviceName: device.name)
            }

        case .inquiryDeviceUpdated(let info):
            apply(info)

        case .inquiryFinished(let error, let aborted):
            setInquiryRunning(false)
            if let error {
                log.append(.error, "Classic inquiry failed: \(error)")
            } else {
                log.append(.classic, aborted ? "Classic inquiry stopped" : "Classic inquiry complete")
            }

        case .knownDevicesLoaded(let infos):
            for info in infos { apply(info) }
            let paired = infos.filter(\.isPaired).count
            log.append(.classic, "Loaded \(infos.count) known Classic devices (\(paired) paired)")

        case .deviceConnected(let info):
            let device = apply(info)
            log.append(.connection, "Classic device connected", deviceID: device.id, deviceName: device.name)

        case .deviceDisconnected(let address):
            guard let device = device(.classic(address: ClassicDeviceInfo.normalize(address: address))) else { return }
            device.classic?.isConnected = false
            device.classic?.rssi = nil
            markListDirty()
            log.append(.connection, "Classic device disconnected", deviceID: device.id, deviceName: device.name)

        case .sdpQueryStarted(let address):
            device(.classic(address: ClassicDeviceInfo.normalize(address: address)))?.isSDPQueryRunning = true
            log.append(.classic, "SDP query started", deviceID: .classic(address: ClassicDeviceInfo.normalize(address: address)))

        case .sdpQueryCompleted(let info, let error):
            let device = apply(info)
            device.isSDPQueryRunning = false
            if let error {
                device.lastError = "SDP query failed: \(error)"
                log.append(.error, device.lastError ?? error, deviceID: device.id, deviceName: device.name)
            } else {
                log.append(.classic, "SDP query found \(info.serviceRecords.count) service records", deviceID: device.id, deviceName: device.name)
                for record in info.serviceRecords {
                    log.append(.service, "\(record.title)\(record.summary.isEmpty ? "" : "  \(record.summary)")",
                               deviceID: device.id, deviceName: device.name, uuid: record.serviceClassIDs.first)
                }
                remember(device, reason: .connectedAndFavorites)
            }

        case .operationFailed(let address, let operation, let error):
            let id = address.map { DeviceID.classic(address: ClassicDeviceInfo.normalize(address: $0)) }
            if let id {
                device(id)?.isSDPQueryRunning = false
                device(id)?.lastError = "\(operation) failed: \(error)"
            }
            log.append(.error, "\(operation) failed: \(error)", deviceID: id, deviceName: id.flatMap { device($0)?.name })
        }
    }

    @discardableResult
    private func apply(_ info: ClassicDeviceInfo) -> InspectedDevice {
        let id = DeviceID.classic(address: info.address)
        let date = info.lastInquiryUpdate ?? info.lastNameUpdate ?? now()
        let device = ensureDevice(id, at: date)
        device.classic = device.classic.map { $0.merging(info) } ?? info
        device.systemName = device.classic?.name
        if let rssi = info.rssi { device.recordRSSI(rssi, at: now()) }
        if info.sources.contains(.inquiry) || info.isConnected {
            device.lastSeen = now()
        } else if device.lastSeen == nil {
            device.lastSeen = info.lastInquiryUpdate ?? info.lastServicesUpdate ?? info.lastNameUpdate
        }
        // Paired devices are "yours", so they are remembered like connected ones.
        remember(device, reason: info.isPaired || info.isConnected ? .connectedAndFavorites : .everything)
        markListDirty()
        return device
    }
}
