import Foundation
@testable import BluetoothInspectorKit

/// Records every command and lets tests inject events.
@MainActor
final class MockBLEClient: BLEClient {
    enum Command: Equatable {
        case startScan(ScanOptions)
        case stopScan
        case retrieve([BluetoothUUID])
        case connect(UUID)
        case disconnect(UUID)
        case readRSSI(UUID)
        case discoverServices(UUID)
        case read(GATTNodeID)
        case write(Data, GATTNodeID, WriteType)
        case setNotify(Bool, GATTNodeID)
        case readDescriptor(GATTNodeID)
    }

    var eventHandler: (@MainActor (BLEEvent) -> Void)?
    var powerState: BluetoothPowerState = .poweredOn
    var authorization: BluetoothAuthorization = .allowedAlways
    var isScanning = false
    private(set) var commands: [Command] = []

    func send(_ event: BLEEvent) { eventHandler?(event) }

    func startScan(options: ScanOptions) {
        commands.append(.startScan(options))
        isScanning = true
        send(.scanStateChanged(isScanning: true))
    }

    func stopScan() {
        commands.append(.stopScan)
        isScanning = false
        send(.scanStateChanged(isScanning: false))
    }

    func retrieveConnectedPeripherals(withServices services: [BluetoothUUID]) { commands.append(.retrieve(services)) }
    func connect(_ peripheral: UUID) { commands.append(.connect(peripheral)) }
    func disconnect(_ peripheral: UUID) { commands.append(.disconnect(peripheral)) }
    func readRSSI(_ peripheral: UUID) { commands.append(.readRSSI(peripheral)) }
    func discoverServices(_ peripheral: UUID) { commands.append(.discoverServices(peripheral)) }
    func read(characteristic: GATTNodeID, on peripheral: UUID) { commands.append(.read(characteristic)) }
    func write(_ data: Data, to characteristic: GATTNodeID, on peripheral: UUID, type: WriteType) {
        commands.append(.write(data, characteristic, type))
    }
    func setNotify(_ enabled: Bool, for characteristic: GATTNodeID, on peripheral: UUID) { commands.append(.setNotify(enabled, characteristic)) }
    func read(descriptor: GATTNodeID, of characteristic: GATTNodeID, on peripheral: UUID) { commands.append(.readDescriptor(descriptor)) }

    var writes: [Command] { commands.filter { if case .write = $0 { return true } else { return false } } }
}

@MainActor
final class MockClassicClient: ClassicClient {
    var eventHandler: (@MainActor (ClassicEvent) -> Void)?
    var isInquiryRunning = false
    private(set) var sdpQueries: [String] = []
    private(set) var loadCount = 0

    func send(_ event: ClassicEvent) { eventHandler?(event) }
    func loadKnownDevices() { loadCount += 1 }
    func startInquiry(duration: TimeInterval) { isInquiryRunning = true; send(.inquiryStarted) }
    func stopInquiry() { isInquiryRunning = false; send(.inquiryFinished(error: nil, aborted: true)) }
    func performSDPQuery(address: String) { sdpQueries.append(address) }
    func refresh(address: String) {}
    func refreshHostController() {}
}

/// A controllable clock for workspace tests.
@MainActor
final class TestClock {
    var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

/// Builds a heart-rate-monitor-like GATT layout.
enum Fixture {
    static let serviceID = GATTNodeID()
    static let heartRateID = GATTNodeID()
    static let controlPointID = GATTNodeID()
    static let cccdID = GATTNodeID()
    static let batteryServiceID = GATTNodeID()
    static let batteryLevelID = GATTNodeID()

    static var services: [GATTService] {
        [GATTService(id: serviceID, uuid: BluetoothUUID(uint16: 0x180D), isPrimary: true),
         GATTService(id: batteryServiceID, uuid: BluetoothUUID(uint16: 0x180F), isPrimary: true)]
    }

    static var heartRateCharacteristics: [GATTCharacteristic] {
        [GATTCharacteristic(id: heartRateID, serviceID: serviceID, uuid: BluetoothUUID(uint16: 0x2A37), properties: [.notify]),
         GATTCharacteristic(id: controlPointID, serviceID: serviceID, uuid: BluetoothUUID(uint16: 0x2A39), properties: [.write])]
    }

    static var batteryCharacteristics: [GATTCharacteristic] {
        [GATTCharacteristic(id: batteryLevelID, serviceID: batteryServiceID, uuid: BluetoothUUID(uint16: 0x2A19), properties: [.read, .notify])]
    }

    static var advertisement: AdvertisementData {
        AdvertisementData(localName: "R11M", serviceUUIDs: [BluetoothUUID(uint16: 0x180D)], isConnectable: true)
    }
}
