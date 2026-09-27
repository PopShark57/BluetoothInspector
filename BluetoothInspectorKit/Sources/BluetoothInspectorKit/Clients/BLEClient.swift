import Foundation

/// Scan configuration passed to the BLE client.
public struct ScanOptions: Hashable, Codable, Sendable {
    /// Report every advertisement instead of one per device. Needed for live
    /// RSSI and advertisement-change tracking, at the cost of more CPU.
    public var allowDuplicates: Bool
    /// Hardware-level service filter. Empty = scan for everything. Note that
    /// macOS only matches UUIDs that appear in the advertisement itself.
    public var serviceUUIDs: [BluetoothUUID]
    /// Also match peripherals soliciting these services.
    public var solicitedServiceUUIDs: [BluetoothUUID]

    public init(allowDuplicates: Bool = true, serviceUUIDs: [BluetoothUUID] = [], solicitedServiceUUIDs: [BluetoothUUID] = []) {
        self.allowDuplicates = allowDuplicates
        self.serviceUUIDs = serviceUUIDs
        self.solicitedServiceUUIDs = solicitedServiceUUIDs
    }
}

/// Everything the BLE adapter reports. Events are value types so they can be
/// logged, replayed in tests, or recorded in the future.
public enum BLEEvent: Sendable {
    case stateChanged(BluetoothPowerState, BluetoothAuthorization)
    case scanStateChanged(isScanning: Bool)
    case discovered(peripheral: UUID, name: String?, advertisement: AdvertisementData, rssi: Int?, at: Date)
    /// Peripherals already connected to the Mac by the system or other apps.
    case retrievedConnected(peripheral: UUID, name: String?)
    case connecting(peripheral: UUID)
    case connected(peripheral: UUID, maximumWriteLength: Int, maximumWriteWithoutResponseLength: Int)
    case connectionFailed(peripheral: UUID, error: String)
    case disconnected(peripheral: UUID, error: String?)
    case nameUpdated(peripheral: UUID, name: String?)
    case rssiRead(peripheral: UUID, rssi: Int?, error: String?, at: Date)
    case servicesDiscovered(peripheral: UUID, services: [GATTService], error: String?)
    case servicesInvalidated(peripheral: UUID, serviceIDs: [GATTNodeID])
    case includedServicesDiscovered(peripheral: UUID, serviceID: GATTNodeID, included: [GATTService], error: String?)
    case characteristicsDiscovered(peripheral: UUID, serviceID: GATTNodeID, characteristics: [GATTCharacteristic], error: String?)
    case descriptorsDiscovered(peripheral: UUID, characteristicID: GATTNodeID, descriptors: [GATTDescriptor], error: String?)
    /// A characteristic value arrived. CoreBluetooth uses one callback for read
    /// responses *and* notifications; the adapter tags it using its record of
    /// outstanding reads (`isNotification == false` means it answered a read).
    case valueUpdated(peripheral: UUID, characteristicID: GATTNodeID, value: Data?, isNotification: Bool, error: String?, at: Date)
    case descriptorValueUpdated(peripheral: UUID, characteristicID: GATTNodeID, descriptorID: GATTNodeID, value: DescriptorValue?, error: String?)
    case writeCompleted(peripheral: UUID, characteristicID: GATTNodeID, error: String?)
    /// A write-without-response was handed to the controller. No acknowledgement exists at the ATT layer.
    case writeWithoutResponseSent(peripheral: UUID, characteristicID: GATTNodeID)
    case notificationStateChanged(peripheral: UUID, characteristicID: GATTNodeID, isNotifying: Bool, error: String?)
    case operationFailed(peripheral: UUID?, operation: String, error: String)
}

/// The operations the app performs on BLE hardware. `CoreBluetoothClient` in
/// the app target implements this; tests use a scripted mock.
@MainActor
public protocol BLEClient: AnyObject {
    var eventHandler: (@MainActor (BLEEvent) -> Void)? { get set }
    var powerState: BluetoothPowerState { get }
    var authorization: BluetoothAuthorization { get }
    var isScanning: Bool { get }

    func startScan(options: ScanOptions)
    func stopScan()
    /// Asks the system for peripherals it already holds connections to that
    /// expose any of `services` (CoreBluetooth requires a service list).
    func retrieveConnectedPeripherals(withServices services: [BluetoothUUID])
    /// CoreBluetooth connection attempts never time out on their own; the
    /// workspace enforces a timeout and calls `disconnect` to cancel.
    func connect(_ peripheral: UUID)
    func disconnect(_ peripheral: UUID)
    func readRSSI(_ peripheral: UUID)
    func discoverServices(_ peripheral: UUID)
    func read(characteristic: GATTNodeID, on peripheral: UUID)
    func write(_ data: Data, to characteristic: GATTNodeID, on peripheral: UUID, type: WriteType)
    func setNotify(_ enabled: Bool, for characteristic: GATTNodeID, on peripheral: UUID)
    func read(descriptor: GATTNodeID, of characteristic: GATTNodeID, on peripheral: UUID)
}
