import Foundation
import Testing
@testable import BluetoothInspectorKit

@MainActor
@Suite("Export")
struct ExportTests {
    let ble = MockBLEClient()
    let peripheral = UUID()
    let context = DiagnosticsContext(appVersion: "1.0 (1)", operatingSystem: "macOS 27.0")

    func populatedWorkspace() -> BluetoothWorkspace {
        let workspace = BluetoothWorkspace(ble: ble, classic: nil, historyStore: nil)
        var advertisement = Fixture.advertisement
        advertisement.manufacturerData = Data([0x4C, 0x00, 0x10, 0x02, 0x0B, 0x00])
        advertisement.serviceData = [ServiceDataEntry(uuid: BluetoothUUID(uint16: 0x180F), data: Data([0x5A]))]
        ble.send(.discovered(peripheral: peripheral, name: nil, advertisement: advertisement, rssi: -55, at: Date()))
        workspace.connect(.lowEnergy(peripheral))
        ble.send(.connected(peripheral: peripheral, maximumWriteLength: 512, maximumWriteWithoutResponseLength: 182))
        ble.send(.servicesDiscovered(peripheral: peripheral, services: Fixture.services, error: nil))
        ble.send(.characteristicsDiscovered(peripheral: peripheral, serviceID: Fixture.serviceID, characteristics: Fixture.heartRateCharacteristics, error: nil))
        ble.send(.characteristicsDiscovered(peripheral: peripheral, serviceID: Fixture.batteryServiceID, characteristics: Fixture.batteryCharacteristics, error: nil))
        ble.send(.valueUpdated(peripheral: peripheral, characteristicID: Fixture.heartRateID, value: Data([0x00, 0x48]), isNotification: true, error: nil, at: Date()))
        ble.send(.valueUpdated(peripheral: peripheral, characteristicID: Fixture.batteryLevelID, value: Data([0x55]), isNotification: false, error: nil, at: Date()))
        return workspace
    }

    @Test func deviceJSONHasDocumentedStructure() throws {
        let workspace = populatedWorkspace()
        let device = try #require(workspace.device(.lowEnergy(peripheral)))
        let data = try ExportBuilder(workspace: workspace, context: context).json(ExportBuilder(workspace: workspace, context: context).deviceExport(device))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["device", "advertisement", "services", "characteristics", "events", "values", "rssi", "schemaVersion", "generator"] {
            #expect(object[key] != nil, "missing \(key)")
        }
        let characteristics = try #require(object["characteristics"] as? [[String: Any]])
        #expect(characteristics.count == 3)
        let heartRate = try #require(characteristics.first { ($0["characteristic"] as? [String: Any])?["short"] as? String == "2A37" })
        #expect(heartRate["hex"] as? String == "0048")
        #expect((heartRate["decoded"] as? [String: Any])?["summary"] as? String == "Heart Rate: 72 BPM")
        #expect((heartRate["characteristic"] as? [String: Any])?["name"] as? String == "Heart Rate Measurement")
        let advertisement = try #require(object["advertisement"] as? [String: Any])
        #expect((advertisement["manufacturerData"] as? [String: Any])?["companyName"] as? String == "Apple, Inc.")
        let events = try #require(object["events"] as? [[String: Any]])
        #expect(events.contains { ($0["message"] as? String)?.contains("Heart Rate: 72 BPM") == true })
    }

    @Test func deviceExportRoundTrips() throws {
        let workspace = populatedWorkspace()
        let device = try #require(workspace.device(.lowEnergy(peripheral)))
        let builder = ExportBuilder(workspace: workspace, context: context)
        let export = builder.deviceExport(device)
        let decoded = try ExportCoding.jsonDecoder().decode(DeviceExport.self, from: try builder.json(export))
        #expect(decoded.device.identifier == peripheral.uuidString)
        #expect(decoded.values.count == 2)
        #expect(decoded.services.count == 2)
        #expect(abs(decoded.exportedAt.timeIntervalSince(export.exportedAt)) < 0.002)
    }

    @Test func sessionExportAndDiagnostics() throws {
        let workspace = populatedWorkspace()
        let builder = ExportBuilder(workspace: workspace, context: context)
        let session = builder.sessionExport()
        #expect(session.devices.count == 1)
        #expect(session.devices.first?.events.isEmpty == true)
        #expect(!session.events.isEmpty)
        #expect(session.diagnostics["App Version"] == "1.0 (1)")
        #expect(builder.diagnosticsText().contains("Bluetooth Power State: Powered On"))
        #expect(builder.diagnosticsText().contains("Connected Peripherals: R11M"))
    }

    @Test func textReport() throws {
        let workspace = populatedWorkspace()
        let device = try #require(workspace.device(.lowEnergy(peripheral)))
        let report = ExportBuilder(workspace: workspace, context: context).textReport(for: device)
        #expect(report.contains("Primary Service 180D Heart Rate"))
        #expect(report.contains("decoded: Heart Rate: 72 BPM"))
        #expect(report.contains("not a distance measurement"))
    }

    @Test func csvEscaping() {
        #expect(CSVExporter.escape("plain") == "plain")
        #expect(CSVExporter.escape("a,b") == "\"a,b\"")
        #expect(CSVExporter.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVExporter.escape("line\nbreak") == "\"line\nbreak\"")
        let document = CSVExporter.document(header: ["a", "b"], rows: [["1", "x,y"]])
        #expect(document == "a,b\r\n1,\"x,y\"\r\n")
    }

    @Test func csvEventsAndValues() throws {
        let workspace = populatedWorkspace()
        let device = try #require(workspace.device(.lowEnergy(peripheral)))
        let values = CSVExporter.values(device.valueRecords)
        #expect(values.contains("notification,2A37,Heart Rate Measurement,2,0048,Heart Rate: 72 BPM"))
        let events = CSVExporter.events(workspace.log.allEvents)
        #expect(events.hasPrefix("sequence,timestamp,category"))
    }
}

@Suite("Device history")
struct HistoryTests {
    let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let id = DeviceID.lowEnergy(UUID())

    @Test func recordAccumulatesAndPreservesUserFields() {
        var history = DeviceHistory()
        history.record(id: id, name: "A", transport: .lowEnergy, services: [BluetoothUUID(uint16: 0x180D)], at: date)
        history.rename(id, to: "  My Sensor  ")
        history.setFavorite(id, true)
        history.setNotes(id, "note")
        history.record(id: id, name: "B", transport: .lowEnergy, services: [BluetoothUUID(uint16: 0x180F)],
                       manufacturer: "Acme", at: date.addingTimeInterval(60))
        let saved = history[id]
        #expect(saved?.name == "B")
        #expect(saved?.customName == "My Sensor")
        #expect(saved?.displayName == "My Sensor")
        #expect(saved?.isFavorite == true)
        #expect(saved?.notes == "note")
        #expect(saved?.firstSeen == date)
        #expect(saved?.lastSeen == date.addingTimeInterval(60))
        #expect(saved?.knownServices.map(\.shortString) == ["180D", "180F"])
        history.rename(id, to: "   ")
        #expect(history[id]?.customName == nil)
        history.forget(id)
        #expect(history[id] == nil)
    }

    @Test func fileStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("DeviceHistory.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileDeviceHistoryStore(url: url)
        #expect(try store.load().devices.isEmpty)
        var history = DeviceHistory()
        history.record(id: id, name: "A", transport: .lowEnergy, at: date)
        history.record(id: .classic(address: "00:11:22:33:44:55"), name: "B", transport: .classic, at: date)
        try store.save(history)
        let loaded = try store.load()
        #expect(loaded == history)
        #expect(loaded.all.count == 2)
    }

    @Test func deviceIDCoding() throws {
        let ids: [DeviceID] = [id, .classic(address: "AA:BB:CC:DD:EE:FF")]
        let data = try JSONEncoder().encode(ids)
        #expect(try JSONDecoder().decode([DeviceID].self, from: data) == ids)
        #expect(DeviceID(rawValue: "bogus") == nil)
    }

    @Test func settingsDecodeLeniently() throws {
        let settings = try JSONDecoder().decode(InspectorSettings.self, from: Data(#"{"allowDuplicates": false}"#.utf8))
        #expect(settings.allowDuplicates == false)
        #expect(settings.connectionTimeout == 15)
        #expect(InspectorSettings.parseUUIDList("180D, 2a37 bad") == [BluetoothUUID(uint16: 0x180D), BluetoothUUID(uint16: 0x2A37)])
    }
}

@Suite("GATT tree")
struct GATTTreeTests {
    @Test func upsertPreservesChildrenAndIndexesValues() {
        var tree = GATTTree()
        tree.upsert(services: Fixture.services)
        tree.setCharacteristics(Fixture.heartRateCharacteristics, for: Fixture.serviceID)
        tree.updateValue(Data([1]), at: Date(), for: Fixture.heartRateID)
        // CoreBluetooth re-reports services after didModifyServices.
        tree.upsert(services: Fixture.services)
        #expect(tree.services.count == 2)
        #expect(tree.characteristic(Fixture.heartRateID)?.value == Data([1]))
        // Rediscovery of characteristics keeps values.
        tree.setCharacteristics(Fixture.heartRateCharacteristics, for: Fixture.serviceID)
        #expect(tree.characteristic(Fixture.heartRateID)?.value == Data([1]))
        #expect(tree.service(Fixture.serviceID)?.characteristicDiscovery == .complete)
    }

    @Test func secondaryAndIncludedServices() {
        var tree = GATTTree()
        tree.upsert(services: Fixture.services)
        let secondaryID = GATTNodeID()
        tree.upsert(services: [GATTService(id: secondaryID, uuid: BluetoothUUID(uint16: 0x1801), isPrimary: false)])
        tree.setIncludedServices([secondaryID], for: Fixture.serviceID)
        #expect(tree.primaryServices.count == 2)
        #expect(tree.secondaryServices.map(\.id) == [secondaryID])
        #expect(tree.service(Fixture.serviceID)?.includedServiceIDs == [secondaryID])
    }

    @Test func descriptorsAndPresentationFormat() {
        var tree = GATTTree()
        tree.upsert(services: Fixture.services)
        tree.setCharacteristics(Fixture.batteryCharacteristics, for: Fixture.batteryServiceID)
        let formatID = GATTNodeID()
        tree.setDescriptors([GATTDescriptor(id: formatID, uuid: BluetoothUUID(uint16: 0x2904))], for: Fixture.batteryLevelID)
        tree.setDescriptorValue(DescriptorValue(data: Data([0x04, 0x00, 0xAD, 0x27, 0x01, 0x00, 0x00]), displayText: ""),
                                error: nil, descriptorID: formatID, characteristicID: Fixture.batteryLevelID)
        let characteristic = tree.characteristic(Fixture.batteryLevelID)
        #expect(characteristic?.presentationFormat?.unitSymbol == "%")
        #expect(tree.descriptor(formatID)?.1.uuid == BluetoothUUID(uint16: 0x2904))
    }

    @Test func properties() {
        let properties: GATTProperties = [.read, .write, .notify]
        #expect(properties.titles == ["Read", "Write", "Notify"])
        #expect(properties.isReadable && properties.isWritable && properties.canSubscribe)
        #expect(GATTProperties(rawValue: 0x04).titles == ["Write Without Response"])
    }
}
