import Foundation

/// Lookup of Bluetooth SIG assigned numbers and well-known vendor UUIDs.
///
/// The built-in tables (`AssignedNumbers+Tables.swift`) are generated from the
/// official SIG YAML. They cover every GATT service, characteristic and
/// descriptor, the 16-bit member UUIDs, SDP service classes and protocols, and
/// a curated set of company identifiers. A fuller database (for example every
/// company identifier) can be merged at runtime with `loadExtension(from:)`.
public enum AssignedNumbers {
    public enum Kind: String, Sendable, Codable {
        case service
        case characteristic
        case descriptor
        case serviceClass
        case `protocol`
        case memberService
        case unit
        case vendor
    }

    public struct Entry: Sendable, Equatable {
        public let name: String
        public let kind: Kind
    }

    /// Vendor-defined 128-bit UUIDs that developers routinely run into.
    static let vendorUUIDNames: [String: String] = [
        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E": "Nordic UART Service",
        "6E400002-B5A3-F393-E0A9-E50E24DCCA9E": "Nordic UART RX",
        "6E400003-B5A3-F393-E0A9-E50E24DCCA9E": "Nordic UART TX",
        "8EC90001-F315-4F60-9FB8-838830DAEA50": "Nordic Buttonless DFU",
        "8EC90003-F315-4F60-9FB8-838830DAEA50": "Nordic Buttonless DFU (Without Bonds)",
        "D0611E78-BBB4-4591-A5F8-487910AE4366": "Apple Continuity Service",
        "8667556C-9A37-4C91-84ED-54EE27D90049": "Apple Continuity Characteristic",
        "7905F431-B5CE-4E99-A40F-4B1E122D00D0": "Apple Notification Center Service (ANCS)",
        "89D3502B-0F36-433A-8EF4-C502AD55F8DC": "Apple Media Service (AMS)",
        "9FA480E0-4967-4542-9390-D343DC5D04AE": "Apple Nearby Service",
        "AF0BADB1-5B99-43CD-917A-A77BC549E3CC": "Apple Nearby Characteristic",
        "0000FE2C-0000-1000-8000-00805F9B34FB": "Google Fast Pair Service",
    ]

    private static let extensionStore = ExtensionStore()

    /// Best available name for any UUID.
    public static func name(for uuid: BluetoothUUID) -> String? {
        entry(for: uuid)?.name
    }

    public static func entry(for uuid: BluetoothUUID) -> Entry? {
        if let vendor = vendorUUIDNames[uuid.uuidString] {
            return Entry(name: vendor, kind: .vendor)
        }
        guard let short = uuid.assignedNumber else { return nil }
        let tables: [(Kind, [UInt16: String])] = [
            (.service, serviceNames),
            (.characteristic, characteristicNames),
            (.descriptor, descriptorNames),
            (.serviceClass, serviceClassNames),
            (.protocol, protocolNames),
            (.memberService, memberUUIDNames),
            (.unit, unitNames),
        ]
        for (kind, table) in tables {
            if let name = table[short] { return Entry(name: name, kind: kind) }
        }
        if let name = extensionStore.uuidName(short) {
            return Entry(name: name, kind: .service)
        }
        return nil
    }

    public static func serviceName(_ uuid: BluetoothUUID) -> String? {
        uuid.assignedNumber.flatMap { serviceNames[$0] } ?? name(for: uuid)
    }

    public static func characteristicName(_ uuid: BluetoothUUID) -> String? {
        uuid.assignedNumber.flatMap { characteristicNames[$0] } ?? name(for: uuid)
    }

    public static func descriptorName(_ uuid: BluetoothUUID) -> String? {
        uuid.assignedNumber.flatMap { descriptorNames[$0] } ?? name(for: uuid)
    }

    /// Company identifier (as found in manufacturer data and PnP ID).
    public static func companyName(_ identifier: UInt16) -> String? {
        companyNames[identifier] ?? extensionStore.companyName(identifier)
    }

    public static func unitName(_ unit: UInt16) -> String? {
        unitNames[unit]
    }

    /// GAP Appearance (`0x2A01`) value: 10-bit category, 6-bit subcategory.
    public static func appearanceName(_ value: UInt16) -> String? {
        appearanceNames[value] ?? appearanceNames[value & 0xFFC0]
    }

    /// Everything known, for search and for the SIG browser.
    public static func allEntries() -> [(BluetoothUUID, Entry)] {
        var result: [(BluetoothUUID, Entry)] = []
        let tables: [(Kind, [UInt16: String])] = [
            (.service, serviceNames),
            (.characteristic, characteristicNames),
            (.descriptor, descriptorNames),
            (.serviceClass, serviceClassNames),
            (.protocol, protocolNames),
            (.memberService, memberUUIDNames),
        ]
        for (kind, table) in tables {
            for (key, name) in table {
                result.append((BluetoothUUID(uint16: key), Entry(name: name, kind: kind)))
            }
        }
        for (string, name) in vendorUUIDNames {
            if let uuid = BluetoothUUID(string: string) {
                result.append((uuid, Entry(name: name, kind: .vendor)))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    // MARK: - Runtime extension

    /// Merges an extended database (JSON: `{"companies": {"004C": "Apple"},
    /// "uuids": {"180D": "Heart Rate"}}`, as produced by
    /// `Scripts/generate_sig_tables.py --full-json`). Built-in names win.
    /// Returns the number of entries loaded.
    @discardableResult
    public static func loadExtension(from data: Data) throws -> Int {
        let database = try JSONDecoder().decode(ExtensionDatabase.self, from: data)
        func parse(_ source: [String: String]?) -> [UInt16: String] {
            var table: [UInt16: String] = [:]
            for (key, value) in source ?? [:] {
                if let number = UInt16(key.replacingOccurrences(of: "0x", with: ""), radix: 16) {
                    table[number] = value
                }
            }
            return table
        }
        let companies = parse(database.companies)
        let uuids = parse(database.uuids)
        extensionStore.replace(companies: companies, uuids: uuids)
        return companies.count + uuids.count
    }

    public static var extensionEntryCount: Int { extensionStore.count }

    private struct ExtensionDatabase: Decodable {
        let companies: [String: String]?
        let uuids: [String: String]?
    }

    private final class ExtensionStore: @unchecked Sendable {
        // Guarded by `lock`; lookups are frequent and cheap, writes are rare.
        private let lock = NSLock()
        private var companies: [UInt16: String] = [:]
        private var uuids: [UInt16: String] = [:]

        func replace(companies: [UInt16: String], uuids: [UInt16: String]) {
            lock.withLock {
                self.companies = companies
                self.uuids = uuids
            }
        }

        func companyName(_ key: UInt16) -> String? { lock.withLock { companies[key] } }
        func uuidName(_ key: UInt16) -> String? { lock.withLock { uuids[key] } }
        var count: Int { lock.withLock { companies.count + uuids.count } }
    }
}
