import Foundation

/// Decodes the 24-bit Bluetooth Classic Class of Device (CoD) field
/// (Assigned Numbers §2.8): bits 0–1 format type, bits 2–7 minor device
/// class, bits 8–12 major device class, bits 13–23 major service classes.
public struct ClassOfDevice: Hashable, Codable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue & 0x00FF_FFFF
    }

    public var formatType: UInt8 { UInt8(rawValue & 0x3) }
    public var minorDeviceClass: UInt8 { UInt8((rawValue >> 2) & 0x3F) }
    public var majorDeviceClass: UInt8 { UInt8((rawValue >> 8) & 0x1F) }
    public var serviceClassBits: UInt16 { UInt16((rawValue >> 13) & 0x7FF) }

    public var hexString: String { String(format: "0x%06X", rawValue) }

    public var majorName: String {
        Self.majorNames[majorDeviceClass] ?? "Reserved (\(majorDeviceClass))"
    }

    public var minorName: String {
        let minor = minorDeviceClass
        switch majorDeviceClass {
        case 3:
            // LAN/Network: upper 3 bits of the minor field are a utilization load factor.
            let load = Int(minor >> 3)
            return Self.lanLoad[safe: load] ?? "Unknown load"
        case 5:
            // Peripheral: bits 6–7 keyboard/pointing, bits 2–5 device type.
            let kind = Self.peripheralKind[safe: Int(minor >> 4)] ?? "Unknown"
            let type = Self.peripheralType[safe: Int(minor & 0x0F)] ?? "Reserved"
            return minor & 0x0F == 0 ? kind : "\(kind), \(type)"
        case 6:
            // Imaging: independent flag bits (CoD bits 4–7 → minor bits 2–5).
            let flags = [(2, "Display"), (3, "Camera"), (4, "Scanner"), (5, "Printer")]
                .filter { minor & (1 << $0.0) != 0 }
                .map(\.1)
            return flags.isEmpty ? "Uncategorized" : flags.joined(separator: ", ")
        default:
            return Self.minorNames[majorDeviceClass]?[minor] ?? (minor == 0 ? "Uncategorized" : "Reserved (\(minor))")
        }
    }

    /// Names of every major service class bit that is set.
    public var serviceClasses: [String] {
        Self.serviceClassNames.compactMap { bit, name in
            rawValue & (1 << bit) != 0 ? name : nil
        }
    }

    public var summary: String {
        let services = serviceClasses
        let base = "\(majorName) – \(minorName)"
        return services.isEmpty ? base : "\(base) [\(services.joined(separator: ", "))]"
    }

    /// SF Symbol that best represents the major/minor class.
    public var symbolName: String {
        switch majorDeviceClass {
        case 1: minorDeviceClass == 3 ? "laptopcomputer" : (minorDeviceClass == 7 ? "ipad" : "desktopcomputer")
        case 2: "iphone"
        case 3: "network"
        case 4: [1, 6].contains(minorDeviceClass) ? "headphones" : (minorDeviceClass == 5 ? "hifispeaker" : "speaker.wave.2")
        case 5:
            switch minorDeviceClass >> 4 {
            case 1: "keyboard"
            case 2: "computermouse"
            default: minorDeviceClass & 0x0F == 2 ? "gamecontroller" : "keyboard"
            }
        case 6: "printer"
        case 7: "applewatch"
        case 8: "gamecontroller"
        case 9: "heart"
        default: "questionmark.circle"
        }
    }

    static let majorNames: [UInt8: String] = [
        0: "Miscellaneous",
        1: "Computer",
        2: "Phone",
        3: "LAN/Network Access Point",
        4: "Audio/Video",
        5: "Peripheral",
        6: "Imaging",
        7: "Wearable",
        8: "Toy",
        9: "Health",
        31: "Uncategorized",
    ]

    static let serviceClassNames: [(UInt32, String)] = [
        (13, "Limited Discoverable Mode"),
        (14, "LE Audio"),
        (16, "Positioning"),
        (17, "Networking"),
        (18, "Rendering"),
        (19, "Capturing"),
        (20, "Object Transfer"),
        (21, "Audio"),
        (22, "Telephony"),
        (23, "Information"),
    ]

    static let lanLoad = [
        "Fully available", "1–17% utilized", "17–33% utilized", "33–50% utilized",
        "50–67% utilized", "67–83% utilized", "83–99% utilized", "No service available",
    ]
    static let peripheralKind = ["Uncategorized", "Keyboard", "Pointing Device", "Combo Keyboard/Pointing Device"]
    static let peripheralType = [
        "Uncategorized", "Joystick", "Gamepad", "Remote Control", "Sensing Device", "Digitizer Tablet",
        "Card Reader", "Digital Pen", "Handheld Scanner", "Handheld Gestural Input Device",
    ]

    static let minorNames: [UInt8: [UInt8: String]] = [
        1: [0: "Uncategorized", 1: "Desktop Workstation", 2: "Server-class Computer", 3: "Laptop",
            4: "Handheld PC/PDA", 5: "Palm-size PC/PDA", 6: "Wearable Computer", 7: "Tablet"],
        2: [0: "Uncategorized", 1: "Cellular", 2: "Cordless", 3: "Smartphone",
            4: "Wired Modem or Voice Gateway", 5: "Common ISDN Access"],
        4: [0: "Uncategorized", 1: "Wearable Headset", 2: "Hands-free Device", 4: "Microphone",
            5: "Loudspeaker", 6: "Headphones", 7: "Portable Audio", 8: "Car Audio", 9: "Set-top Box",
            10: "HiFi Audio Device", 11: "VCR", 12: "Video Camera", 13: "Camcorder", 14: "Video Monitor",
            15: "Video Display and Loudspeaker", 16: "Video Conferencing", 18: "Gaming/Toy",
            19: "Hearing Aid", 20: "Glasses"],
        7: [1: "Wristwatch", 2: "Pager", 3: "Jacket", 4: "Helmet", 5: "Glasses", 6: "Pin"],
        8: [1: "Robot", 2: "Vehicle", 3: "Doll/Action Figure", 4: "Controller", 5: "Game"],
        9: [0: "Undefined", 1: "Blood Pressure Monitor", 2: "Thermometer", 3: "Weighing Scale",
            4: "Glucose Meter", 5: "Pulse Oximeter", 6: "Heart/Pulse Rate Monitor", 7: "Health Data Display",
            8: "Step Counter", 9: "Body Composition Analyzer", 10: "Peak Flow Monitor",
            11: "Medication Monitor", 12: "Knee Prosthesis", 13: "Ankle Prosthesis",
            14: "Generic Health Manager", 15: "Personal Mobility Device"],
    ]
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
