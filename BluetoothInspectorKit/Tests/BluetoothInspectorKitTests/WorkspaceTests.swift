import Foundation
import Testing
@testable import BluetoothInspectorKit

@MainActor
@Suite("Workspace")
struct WorkspaceTests {
    let ble = MockBLEClient()
    let classic = MockClassicClient()
    let clock = TestClock()
    let store = InMemoryDeviceHistoryStore()
    let peripheral = UUID()
    var id: DeviceID { .lowEnergy(peripheral) }

    func makeWorkspace(settings: InspectorSettings = InspectorSettings()) -> BluetoothWorkspace {
        let clock = clock
        return BluetoothWorkspace(ble: ble, classic: classic, historyStore: store, settings: settings, now: { clock.date })
    }

    func discover(_ workspace: BluetoothWorkspace, rssi: Int = -60, advertisement: AdvertisementData = Fixture.advertisement) {
        ble.send(.discovered(peripheral: peripheral, name: nil, advertisement: advertisement, rssi: rssi, at: clock.date))
    }

    func connectAndDiscover(_ workspace: BluetoothWorkspace) {
        discover(workspace)
        workspace.connect(id)
        ble.send(.connected(peripheral: peripheral, maximumWriteLength: 512, maximumWriteWithoutResponseLength: 20))
        ble.send(.servicesDiscovered(peripheral: peripheral, services: Fixture.services, error: nil))
        ble.send(.characteristicsDiscovered(peripheral: peripheral, serviceID: Fixture.serviceID, characteristics: Fixture.heartRateCharacteristics, error: nil))
        ble.send(.characteristicsDiscovered(peripheral: peripheral, serviceID: Fixture.batteryServiceID, characteristics: Fixture.batteryCharacteristics, error: nil))
    }

    // MARK: Scanning

    @Test func scanningStartsAndStops() {
        let workspace = makeWorkspace()
        workspace.toggleScan()
        #expect(workspace.isScanning)
        #expect(ble.commands.first == .startScan(ScanOptions(allowDuplicates: true)))
        workspace.toggleScan()
        #expect(!workspace.isScanning)
        #expect(ble.commands.last == .stopScan)
    }

    @Test func scanWaitsForPowerOn() {
        ble.powerState = .unknown
        let workspace = makeWorkspace()
        workspace.startScan()
        #expect(ble.commands.isEmpty)
        ble.send(.stateChanged(.poweredOn, .allowedAlways))
        #expect(workspace.isScanning)
    }

    @Test func scanRefusedWhenPoweredOffWithExplanation() {
        ble.powerState = .poweredOff
        let workspace = makeWorkspace()
        workspace.startScan()
        #expect(ble.commands.isEmpty)
        #expect(workspace.log.allEvents.last?.category == .error)
        #expect(workspace.log.allEvents.last?.message.contains("turned off") == true)
    }

    @Test func discoveryDeduplicatesAndTracksChanges() {
        let workspace = makeWorkspace()
        discover(workspace, rssi: -70)
        discover(workspace, rssi: -65)
        var changed = Fixture.advertisement
        changed.manufacturerData = Data([0x59, 0x00, 0x01])
        clock.advance(2)
        discover(workspace, rssi: 127, advertisement: changed)
        #expect(workspace.devices.count == 1)
        let device = workspace.device(id)
        #expect(device?.advertisementPacketCount == 3)
        #expect(device?.advertisementChangeCount == 1)
        #expect(device?.rssi == -65) // 127 = unavailable, ignored
        #expect(device?.rssiHistory.count == 2)
        #expect(device?.manufacturer == "Nordic Semiconductor ASA")
        #expect(workspace.log.allEvents.filter { $0.message.hasPrefix("Found") }.count == 1)
    }

    @Test func deviceListIsThrottledUntilRefresh() {
        let workspace = makeWorkspace()
        discover(workspace)
        #expect(workspace.deviceList.isEmpty)
        workspace.tick()
        #expect(workspace.deviceList.map(\.id) == [id])
        #expect(workspace.deviceList.first?.displayName == "R11M")
    }

    // MARK: Connection & GATT

    @Test func connectDiscoversGATTHierarchy() throws {
        let workspace = makeWorkspace()
        connectAndDiscover(workspace)
        let device = try #require(workspace.device(id))
        #expect(device.connectionState == .connected)
        #expect(ble.commands.contains(.connect(peripheral)))
        #expect(ble.commands.contains(.discoverServices(peripheral)))
        #expect(device.gatt.services.map(\.uuid.shortString) == ["180D", "180F"])
        #expect(device.gatt.characteristicCount == 3)
        #expect(device.gatt.characteristic(Fixture.controlPointID)?.maximumWriteLength == 512)
        // Connected devices are remembered by default.
        #expect(workspace.history[id] != nil)
    }

    @Test func descriptorsAreReadAutomaticallyButNeverWritten() {
        let workspace = makeWorkspace()
        connectAndDiscover(workspace)
        let descriptor = GATTDescriptor(id: Fixture.cccdID, uuid: BluetoothUUID(uint16: 0x2902))
        ble.send(.descriptorsDiscovered(peripheral: peripheral, characteristicID: Fixture.heartRateID, descriptors: [descriptor], error: nil))
        #expect(ble.commands.contains(.readDescriptor(Fixture.cccdID)))
        #expect(ble.writes.isEmpty)
        ble.send(.descriptorValueUpdated(peripheral: peripheral, characteristicID: Fixture.heartRateID, descriptorID: Fixture.cccdID,
                                         value: DescriptorValue(data: Data([1, 0]), displayText: "1"), error: nil))
        let stored = workspace.device(id)?.gatt.characteristic(Fixture.heartRateID)?.descriptors.first
        #expect(stored?.value?.data == Data([1, 0]))
    }

    @Test func noAutomaticReadsUnlessEnabled() {
        let workspace = makeWorkspace()
        connectAndDiscover(workspace)
        #expect(!ble.commands.contains(.read(Fixture.batteryLevelID)))

        var settings = InspectorSettings()
        settings.autoReadCharacteristics = true
        let eager = makeWorkspace(settings: settings)
        connectAndDiscover(eager)
        #expect(ble.commands.contains(.read(Fixture.batteryLevelID)))
    }

    @Test func connectionTimeout() {
        let workspace = makeWorkspace()
        discover(workspace)
        workspace.connect(id)
        #expect(workspace.device(id)?.connectionState == .connecting)
        workspace.connectionTimedOut(peripheral, after: 15)
        #expect(workspace.device(id)?.connectionState == .disconnected)
        #expect(workspace.device(id)?.lastError?.contains("timed out") == true)
        #expect(ble.commands.last == .disconnect(peripheral))
        // The cancellation's disconnect callback is not reported as an unexpected error.
        let errorsBefore = workspace.log.errorCount
        ble.send(.disconnected(peripheral: peripheral, error: "Cancelled"))
        #expect(workspace.log.errorCount == errorsBefore)
    }

    @Test func unexpectedDisconnectIsAnError() {
        let workspace = makeWorkspace()
        connectAndDiscover(workspace)
        ble.send(.notificationStateChanged(peripheral: peripheral, characteristicID: Fixture.heartRateID, isNotifying: true, error: nil))
        ble.send(.disconnected(peripheral: peripheral, error: "The connection has timed out unexpectedly."))
        let device = workspace.device(id)
        #expect(device?.connectionState == .disconnected)
        #expect(device?.gatt.characteristic(Fixture.heartRateID)?.isNotifying == false)
        #expect(device?.lastError?.contains("timed out unexpectedly") == true)
        #expect(workspace.log.allEvents.last?.category == .error)
    }

    @Test func poweringOffDisconnectsEverything() {
        let workspace = makeWorkspace()
        connectAndDiscover(workspace)
        ble.send(.stateChanged(.poweredOff, .allowedAlways))
        #expect(workspace.device(id)?.connectionState == .disconnected)
        #expect(workspace.scannerState == .unavailable)
    }

    // MARK: Values, notifications, writes

    @Test func notificationsAreLoggedAndDecoded() throws {
        let workspace = makeWorkspace()
        connectAndDiscover(workspace)
        workspace.setNotify(true, for: Fixture.heartRateID, on: id)
        #expect(ble.commands.last == .setNotify(true, Fixture.heartRateID))
        ble.send(.notificationStateChanged(peripheral: peripheral, characteristicID: Fixture.heartRateID, isNotifying: true, error: nil))
        ble.send(.valueUpdated(peripheral: peripheral, characteristicID: Fixture.heartRateID, value: Data([0x00, 0x48]),
                               isNotification: true, error: nil, at: clock.date))
        let device = try #require(workspace.device(id))
        #expect(device.gatt.characteristic(Fixture.heartRateID)?.isNotifying == true)
        #expect(device.gatt.characteristic(Fixture.heartRateID)?.value == Data([0x00, 0x48]))
        let record = try #require(device.valueRecords.last)
        #expect(record.kind == .notification)
        #expect(record.decodedSummary == "Heart Rate: 72 BPM")
        let messages = workspace.log.allEvents.suffix(2).map(\.consoleLine)
        #expect(messages[0].contains("NOTIFY   [R11M] 2A37  00 48"))
        #expect(messages[1].contains("DECODE   [R11M] Heart Rate: 72 BPM"))
    }

    @Test func readErrorsAreSurfaced() {
        let workspace = makeWorkspace()
        connectAndDiscover(workspace)
        workspace.read(characteristic: Fixture.batteryLevelID, on: id)
        #expect(ble.commands.last == .read(Fixture.batteryLevelID))
        ble.send(.valueUpdated(peripheral: peripheral, characteristicID: Fixture.batteryLevelID, value: nil, isNotification: false,
                               error: "Authentication is insufficient.", at: clock.date))
        #expect(workspace.device(id)?.gatt.characteristic(Fixture.batteryLevelID)?.lastError?.contains("Authentication") == true)
        #expect(workspace.log.allEvents.last?.category == .error)
    }

    @Test func readingANonReadableCharacteristicIsRejected() {
        let workspace = makeWorkspace()
        connectAndDiscover(workspace)
        workspace.read(characteristic: Fixture.heartRateID, on: id)
        #expect(!ble.commands.contains(.read(Fixture.heartRateID)))
    }

    @Test func writeValidation() {
        let workspace = makeWorkspace()
        // Not connected → nothing sent.
        discover(workspace)
        workspace.write(Data([1]), to: Fixture.controlPointID, on: id, type: .withResponse)
        #expect(ble.writes.isEmpty)

        connectAndDiscover(workspace)
        // Property mismatch → rejected.
        workspace.write(Data([1]), to: Fixture.controlPointID, on: id, type: .withoutResponse)
        workspace.write(Data([1]), to: Fixture.heartRateID, on: id, type: .withResponse)
        #expect(ble.writes.isEmpty)
        // Over the CoreBluetooth limit → rejected.
        workspace.write(Data(repeating: 0, count: 513), to: Fixture.controlPointID, on: id, type: .withResponse)
        #expect(ble.writes.isEmpty)
        // Valid → exact bytes sent once, and recorded.
        workspace.write(Data([0x01]), to: Fixture.controlPointID, on: id, type: .withResponse)
        #expect(ble.writes == [.write(Data([0x01]), Fixture.controlPointID, .withResponse)])
        #expect(workspace.device(id)?.valueRecords.last?.kind == .write)
        ble.send(.writeCompleted(peripheral: peripheral, characteristicID: Fixture.controlPointID, error: nil))
        #expect(workspace.log.allEvents.last?.message.contains("acknowledged") == true)
    }

    @Test func servicesInvalidatedAreRemoved() {
        let workspace = makeWorkspace()
        connectAndDiscover(workspace)
        ble.send(.servicesInvalidated(peripheral: peripheral, serviceIDs: [Fixture.batteryServiceID]))
        #expect(workspace.device(id)?.gatt.services.map(\.uuid.shortString) == ["180D"])
        #expect(workspace.device(id)?.gatt.characteristic(Fixture.batteryLevelID) == nil)
    }

    @Test func rssiPollingOnlyForConnectedDevices() {
        let workspace = makeWorkspace()
        connectAndDiscover(workspace)
        clock.advance(5)
        workspace.tick()
        #expect(ble.commands.contains(.readRSSI(peripheral)))
        ble.send(.rssiRead(peripheral: peripheral, rssi: -48, error: nil, at: clock.date))
        #expect(workspace.device(id)?.rssi == -48)
    }

    // MARK: Classic & dual-mode

    @Test func classicDevicesAndDualModeHint() {
        let workspace = makeWorkspace()
        workspace.start()
        defer { workspace.stop() }
        #expect(classic.loadCount == 1)
        classic.send(.knownDevicesLoaded([ClassicDeviceInfo(address: "00-11-22-33-44-55", name: "R11M", isPaired: true, sources: [.paired])]))
        discover(workspace)
        workspace.refreshDeviceListIfNeeded(force: true)
        let classicID = DeviceID.classic(address: "00:11:22:33:44:55")
        #expect(workspace.device(classicID)?.isPaired == true)
        #expect(workspace.device(classicID)?.dualModeHint == .matchingName)
        #expect(workspace.device(id)?.dualModeHint == .matchingName)
        // Paired Classic devices are remembered.
        #expect(workspace.history[classicID] != nil)

        workspace.performSDPQuery(classicID)
        #expect(classic.sdpQueries == ["00:11:22:33:44:55"])
        #expect(workspace.device(classicID)?.isSDPQueryRunning == true)
        let info = ClassicDeviceInfo(address: "00:11:22:33:44:55", isPaired: true, serviceRecords: [ClassicTests.serialPortRecord])
        classic.send(.sdpQueryCompleted(info, error: nil))
        #expect(workspace.device(classicID)?.isSDPQueryRunning == false)
        #expect(workspace.device(classicID)?.classic?.serviceRecords.first?.rfcommChannel == 3)
        #expect(workspace.device(classicID)?.classic?.name == "R11M")
    }

    @Test func classicConnectIsExplainedNotFaked() {
        let workspace = makeWorkspace()
        workspace.connect(.classic(address: "00:11:22:33:44:55"))
        #expect(ble.commands.isEmpty)
        #expect(workspace.log.allEvents.last?.category == .error)
    }

    // MARK: History & filtering

    @Test func historyEditsPersist() {
        let workspace = makeWorkspace()
        discover(workspace)
        workspace.setFavorite(id, true)
        workspace.rename(id, to: "Chest strap")
        workspace.setNotes(id, "Battery weak")
        #expect(store.saveCount >= 3)
        let reloaded = try? store.load()
        #expect(reloaded?[id]?.customName == "Chest strap")
        #expect(reloaded?[id]?.isFavorite == true)
        #expect(workspace.deviceList.first { $0.id == id }?.displayName == "Chest strap")
        workspace.forget(id)
        #expect((try? store.load())?[id] == nil)
    }

    @Test func historyOffStillSavesExplicitFavorites() {
        var settings = InspectorSettings()
        settings.historyMode = .off
        let workspace = makeWorkspace(settings: settings)
        connectAndDiscover(workspace)
        #expect(workspace.history[id] == nil)
        workspace.setFavorite(id, true)
        #expect(workspace.history[id]?.isFavorite == true)
    }

    @Test func savedButAbsentDevicesAppearInList() {
        let savedID = DeviceID.lowEnergy(UUID())
        let history = DeviceHistory(devices: [SavedDevice(id: savedID, name: "Old Sensor", firstSeen: clock.date, lastSeen: clock.date, transport: .lowEnergy)])
        let store = InMemoryDeviceHistoryStore(history)
        let workspace = BluetoothWorkspace(ble: ble, classic: nil, historyStore: store)
        workspace.refreshDeviceListIfNeeded(force: true)
        #expect(workspace.deviceList.first?.displayName == "Old Sensor")
        #expect(workspace.deviceList.first?.isSaved == true)
        #expect(!workspace.classicAvailable)
    }
}

@Suite("Device list filtering and sorting")
struct DeviceListingTests {
    let now = Date(timeIntervalSinceReferenceDate: 0)

    var items: [DeviceListItem] {
        [
            DeviceListItem(id: .lowEnergy(UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()), name: "Heart", transport: .lowEnergy,
                           rssi: -50, lastSeen: now, serviceUUIDs: [BluetoothUUID(uint16: 0x180D)]),
            DeviceListItem(id: .lowEnergy(UUID(uuidString: "00000000-0000-0000-0000-000000000002") ?? UUID()), name: nil, transport: .lowEnergy,
                           rssi: -90, lastSeen: now.addingTimeInterval(10)),
            DeviceListItem(id: .classic(address: "00:11:22:33:44:55"), name: "Speaker", transport: .classic, rssi: nil,
                           manufacturer: "Bose Corporation", lastSeen: now.addingTimeInterval(-10), isFavorite: true),
        ]
    }

    @Test func sortByRSSIStrongestFirstWithMissingLast() {
        let sorted = DeviceSort(key: .rssi, ascending: false).apply(items)
        #expect(sorted.map(\.displayName) == ["Heart", "Unnamed", "Speaker"])
    }

    @Test func sortByNameAndLastSeen() {
        #expect(DeviceSort(key: .name, ascending: true).apply(items).map(\.displayName) == ["Heart", "Speaker", "Unnamed"])
        #expect(DeviceSort(key: .lastSeen, ascending: false).apply(items).map(\.displayName) == ["Unnamed", "Heart", "Speaker"])
        #expect(DeviceSort(key: .identifier, ascending: true).apply(items).first?.displayName == "Heart")
    }

    @Test func filters() {
        #expect(DeviceFilter(transport: .classic).apply(items, sort: DeviceSort()).map(\.displayName) == ["Speaker"])
        #expect(DeviceFilter(name: .unnamed).apply(items, sort: DeviceSort()).count == 1)
        #expect(DeviceFilter(name: .named).apply(items, sort: DeviceSort()).count == 2)
        // RSSI threshold keeps devices without RSSI.
        #expect(DeviceFilter(minimumRSSI: -70).apply(items, sort: DeviceSort()).map(\.displayName) == ["Heart", "Speaker"])
        #expect(DeviceFilter(serviceUUID: "180d").apply(items, sort: DeviceSort()).map(\.displayName) == ["Heart"])
        #expect(DeviceFilter(serviceUUID: "heart rate").apply(items, sort: DeviceSort()).count == 1)
        #expect(DeviceFilter(favoritesOnly: true).apply(items, sort: DeviceSort()).count == 1)
    }

    @Test func search() {
        #expect(DeviceFilter(searchText: "bose").apply(items, sort: DeviceSort()).map(\.displayName) == ["Speaker"])
        #expect(DeviceFilter(searchText: "00:11:22").apply(items, sort: DeviceSort()).count == 1)
        #expect(DeviceFilter(searchText: "heart 180D").apply(items, sort: DeviceSort()).count == 1)
        #expect(DeviceFilter(searchText: "nothing-matches").apply(items, sort: DeviceSort()).isEmpty)
    }
}
