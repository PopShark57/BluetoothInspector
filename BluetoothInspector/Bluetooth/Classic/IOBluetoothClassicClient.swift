import BluetoothInspectorKit
import Foundation
import IOBluetooth
import OSLog

/// `ClassicClient` backed by IOBluetooth.
///
/// What IOBluetooth lets an app do on current macOS, and therefore what this
/// client implements:
/// - list paired devices and the system's recent-device list;
/// - run an inquiry (find discoverable BR/EDR devices) with name resolution;
/// - read cached device information (Class of Device, connection and pairing
///   state, last inquiry/name/services update);
/// - run an SDP query and read every service record and attribute;
/// - observe connect/disconnect of Classic devices.
///
/// Deliberately *not* implemented: initiating pairing, opening RFCOMM/L2CAP
/// channels or baseband connections, and anything in private frameworks.
/// Those either change device state (this is an inspector) or are not
/// available to sandboxed apps.
///
/// Threading: IOBluetooth does *not* reliably call back on the thread that
/// started an operation. Connect/disconnect notifications in particular are
/// posted on IOBluetooth's own coordination queue (and, at registration,
/// immediately for every device that is already connected). A main-actor
/// `@objc` method called there fails Swift's runtime isolation check
/// (`_dispatch_assert_queue_fail`). So every IOBluetooth entry point is
/// `nonisolated`, takes only the device address off the callback queue, and
/// hops to the main actor, where the device is re-resolved by address
/// (IOBluetooth keeps a single `IOBluetoothDevice` instance per address) and
/// read. `IOBluetoothDevice` itself is not thread-safe and never crosses threads.
@MainActor
final class IOBluetoothClassicClient: NSObject, ClassicClient {
    var eventHandler: (@MainActor (ClassicEvent) -> Void)?
    private(set) var isInquiryRunning = false

    private let logger = Logger(subsystem: AppLogger.subsystem, category: "IOBluetooth")
    private var inquiry: IOBluetoothDeviceInquiry?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var knownSources: [String: Set<ClassicDeviceInfo.Source>] = [:]

    override init() {
        super.init()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceDidConnect(_:device:)))
    }

    private func emit(_ event: ClassicEvent) {
        eventHandler?(event)
    }

    /// Runs `body` on the main actor: inline when the callback already arrived
    /// on the main thread, otherwise asynchronously (preserving callback order).
    private nonisolated func deliver(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }

    /// The only property read on an IOBluetooth callback queue.
    private nonisolated static func address(of device: IOBluetoothDevice?) -> String? {
        guard let address = device?.addressString, !address.isEmpty else { return nil }
        return address
    }

    // MARK: Host controller

    func refreshHostController() {
        guard let controller = IOBluetoothHostController.default() else {
            emit(.hostControllerUpdated(HostControllerInfo()))
            return
        }
        emit(.hostControllerUpdated(HostControllerInfo(
            address: controller.addressAsString().map(ClassicDeviceInfo.normalize(address:)),
            name: controller.nameAsString(),
            // kBluetoothHCIPowerStateON == 1
            isPoweredOn: controller.powerState.rawValue == 1,
            classOfDevice: ClassOfDevice(rawValue: controller.classOfDevice())
        )))
    }

    // MARK: Known devices

    func loadKnownDevices() {
        // pairedDevices() returns an empty list unless the app has the
        // com.apple.security.device.bluetooth entitlement and Bluetooth permission.
        let paired = (IOBluetoothDevice.pairedDevices() ?? []).compactMap { $0 as? IOBluetoothDevice }
        let recent = (IOBluetoothDevice.recentDevices(50) ?? []).compactMap { $0 as? IOBluetoothDevice }
        var byAddress: [String: (IOBluetoothDevice, Set<ClassicDeviceInfo.Source>)] = [:]
        for device in paired { add(device, source: .paired, to: &byAddress) }
        for device in recent { add(device, source: .recent, to: &byAddress) }
        let infos = byAddress.values.map { device, sources in info(for: device, sources: sources) }
        for (device, _) in byAddress.values where device.isConnected() {
            watchDisconnect(of: device)
        }
        logger.info("Loaded \(paired.count) paired and \(recent.count) recent Classic devices")
        emit(.knownDevicesLoaded(infos.sorted { $0.address < $1.address }))
    }

    private func add(_ device: IOBluetoothDevice, source: ClassicDeviceInfo.Source,
                     to table: inout [String: (IOBluetoothDevice, Set<ClassicDeviceInfo.Source>)]) {
        guard let address = device.addressString else { return }
        let key = ClassicDeviceInfo.normalize(address: address)
        var sources = table[key]?.1 ?? []
        sources.insert(source)
        table[key] = (device, sources)
        knownSources[key, default: []].insert(source)
    }

    func refresh(address: String) {
        guard let device = IOBluetoothDevice(addressString: address) else { return }
        emit(.inquiryDeviceUpdated(info(for: device, sources: [])))
    }

    // MARK: Inquiry

    func startInquiry(duration: TimeInterval) {
        guard !isInquiryRunning else { return }
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: self) else {
            emit(.operationFailed(address: nil, operation: "Classic inquiry", error: "IOBluetooth could not create an inquiry"))
            return
        }
        // Inquiry length is in seconds (1.28 s units rounded by IOBluetooth), max 255.
        inquiry.inquiryLength = UInt8(clamping: Int(duration.rounded()))
        inquiry.updateNewDeviceNames = true
        let result = inquiry.start()
        guard result == kIOReturnSuccess else {
            emit(.operationFailed(address: nil, operation: "Classic inquiry", error: Self.describe(result)))
            return
        }
        self.inquiry = inquiry
        isInquiryRunning = true
    }

    func stopInquiry() {
        guard let inquiry else { return }
        inquiry.stop()
    }

    // MARK: SDP

    func performSDPQuery(address: String) {
        guard let device = IOBluetoothDevice(addressString: address) else {
            emit(.operationFailed(address: address, operation: "SDP query", error: "Invalid Bluetooth address"))
            return
        }
        emit(.sdpQueryStarted(address: address))
        // May open a temporary baseband connection; the result arrives in sdpQueryComplete.
        let result = device.performSDPQuery(self)
        if result != kIOReturnSuccess {
            emit(.operationFailed(address: address, operation: "SDP query", error: Self.describe(result)))
        }
    }

    /// IOBluetooth's informal SDP completion callback (may arrive off the main thread).
    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        guard let address = Self.address(of: device) else { return }
        deliver { [weak self] in
            guard let self, let device = IOBluetoothDevice(addressString: address) else { return }
            emit(.sdpQueryCompleted(info(for: device, sources: []),
                                    error: status == kIOReturnSuccess ? nil : Self.describe(status)))
        }
    }

    // MARK: Connection notifications

    // Posted on IOBluetooth's coordination queue, not the main thread.
    @objc private nonisolated func deviceDidConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = Self.address(of: device) else { return }
        deliver { [weak self] in
            guard let self, let device = IOBluetoothDevice(addressString: address) else { return }
            watchDisconnect(of: device)
            var info = info(for: device, sources: [.connected])
            info.isConnected = true
            emit(.deviceConnected(info))
        }
    }

    @objc private nonisolated func deviceDidDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = Self.address(of: device) else { return }
        deliver { [weak self] in
            guard let self else { return }
            // Unregister through our stored reference so the notification object stays on the main thread.
            disconnectNotifications.removeValue(forKey: ClassicDeviceInfo.normalize(address: address))?.unregister()
            emit(.deviceDisconnected(address: address))
        }
    }

    private func watchDisconnect(of device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        let key = ClassicDeviceInfo.normalize(address: address)
        guard disconnectNotifications[key] == nil else { return }
        disconnectNotifications[key] = device.register(forDisconnectNotification: self, selector: #selector(deviceDidDisconnect(_:device:)))
    }

    // MARK: Conversion

    private func info(for device: IOBluetoothDevice, sources: Set<ClassicDeviceInfo.Source>) -> ClassicDeviceInfo {
        let address = ClassicDeviceInfo.normalize(address: device.addressString ?? "")
        let connected = device.isConnected()
        // rawRSSI() is only meaningful with a live baseband connection; 127 means unavailable.
        let rawRSSI = connected ? Int(device.rawRSSI()) : 127
        let records = (device.services ?? []).compactMap { $0 as? IOBluetoothSDPServiceRecord }.map(SDPConversion.record)
        return ClassicDeviceInfo(
            address: address,
            name: device.name,
            classOfDevice: ClassOfDevice(rawValue: device.classOfDevice),
            isPaired: device.isPaired(),
            isConnected: connected,
            rssi: RSSISample.isValid(rawRSSI) && rawRSSI != 0 ? rawRSSI : nil,
            lastInquiryUpdate: device.getLastInquiryUpdate(),
            // getLastNameUpdate() is deprecated and unavailable in Swift.
            lastServicesUpdate: device.getLastServicesUpdate(),
            serviceRecords: records,
            sources: sources.union(knownSources[address] ?? [])
        )
    }

    static func describe(_ result: IOReturn) -> String {
        // IOKit's error macros (iokit_common_err(...)) are not importable into
        // Swift, so the common values are spelled out: sys_iokit | sub_iokit_common | code.
        func iokit(_ code: UInt32) -> IOReturn { IOReturn(bitPattern: 0xE000_0000 | code) }
        let known: [IOReturn: String] = [
            iokit(0x2E2): "Not permitted. Check Bluetooth permission for Bluetooth Inspector in System Settings › Privacy & Security",
            iokit(0x2C1): "Not privileged",
            iokit(0x2D5): "The Bluetooth controller is busy (another inquiry or connection may be running)",
            iokit(0x2D6): "The device did not respond in time (it may be out of range or not discoverable)",
            iokit(0x2C0): "No Bluetooth controller is available",
            iokit(0x2CD): "The device connection is not open",
            iokit(0x2EB): "The operation was aborted",
            // HCI error codes are returned unchanged by IOBluetooth for link-level failures.
            0x04: "Page timeout: the device did not answer (out of range, powered off, or not connectable)",
            0x05: "Authentication failure",
            0x08: "Connection timeout",
            0x16: "Connection terminated by the local host",
        ]
        let code = String(format: "0x%08X", UInt32(bitPattern: result))
        return known[result].map { "\($0) (IOReturn \(code))" } ?? "IOReturn \(code)"
    }
}

// MARK: - IOBluetoothDeviceInquiryDelegate

// Like the other IOBluetooth callbacks, these are not guaranteed to arrive on
// the main thread, so they are nonisolated and hop to the main actor.
extension IOBluetoothClassicClient: IOBluetoothDeviceInquiryDelegate {
    nonisolated func deviceInquiryStarted(_ sender: IOBluetoothDeviceInquiry!) {
        deliver { [weak self] in self?.emit(.inquiryStarted) }
    }

    nonisolated func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        guard let address = Self.address(of: device) else { return }
        deliver { [weak self] in
            guard let self, let device = IOBluetoothDevice(addressString: address) else { return }
            emit(.inquiryDeviceFound(info(for: device, sources: [.inquiry])))
        }
    }

    nonisolated func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        guard let address = Self.address(of: device) else { return }
        deliver { [weak self] in
            guard let self, let device = IOBluetoothDevice(addressString: address) else { return }
            emit(.inquiryDeviceUpdated(info(for: device, sources: [.inquiry])))
        }
    }

    nonisolated func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        deliver { [weak self] in
            guard let self else { return }
            isInquiryRunning = false
            inquiry = nil
            emit(.inquiryFinished(error: error == kIOReturnSuccess ? nil : Self.describe(error), aborted: aborted))
        }
    }
}
