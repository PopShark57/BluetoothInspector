import Foundation

/// Local Bluetooth controller details IOBluetooth exposes.
public struct HostControllerInfo: Hashable, Codable, Sendable {
    public var address: String?
    public var name: String?
    public var isPoweredOn: Bool?
    public var classOfDevice: ClassOfDevice?

    public init(address: String? = nil, name: String? = nil, isPoweredOn: Bool? = nil, classOfDevice: ClassOfDevice? = nil) {
        self.address = address
        self.name = name
        self.isPoweredOn = isPoweredOn
        self.classOfDevice = classOfDevice
    }
}

public enum ClassicEvent: Sendable {
    case hostControllerUpdated(HostControllerInfo)
    case inquiryStarted
    case inquiryDeviceFound(ClassicDeviceInfo)
    case inquiryDeviceUpdated(ClassicDeviceInfo)
    case inquiryFinished(error: String?, aborted: Bool)
    case knownDevicesLoaded([ClassicDeviceInfo])
    case deviceConnected(ClassicDeviceInfo)
    case deviceDisconnected(address: String)
    case sdpQueryStarted(address: String)
    case sdpQueryCompleted(ClassicDeviceInfo, error: String?)
    case operationFailed(address: String?, operation: String, error: String)
}

/// Bluetooth Classic operations backed by IOBluetooth in the app.
@MainActor
public protocol ClassicClient: AnyObject {
    var eventHandler: (@MainActor (ClassicEvent) -> Void)? { get set }
    var isInquiryRunning: Bool { get }

    /// Paired devices plus the system's recently used device list.
    func loadKnownDevices()
    /// A Classic inquiry (discovery of devices in discoverable mode).
    func startInquiry(duration: TimeInterval)
    func stopInquiry()
    /// SDP service discovery. May create a short baseband connection.
    func performSDPQuery(address: String)
    /// Re-reads connection state, RSSI and cached records for one device.
    func refresh(address: String)
    func refreshHostController()
}
