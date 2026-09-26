# Bluetooth Inspector

A native macOS developer utility for exploring Bluetooth devices: Bluetooth Low Energy scanning, advertisement decoding, a full GATT explorer with read / write / notify, live RSSI charts, a raw activity console, and Bluetooth Classic (BR/EDR) inspection through IOBluetooth — including SDP service records.

Built with Swift 6, SwiftUI, Observation, Swift Charts, CoreBluetooth and IOBluetooth. There are no third-party dependencies.

- **Targets:** built with Xcode 27 against the macOS 27 SDK; the deployment target is macOS 26 (Tahoe). The app uses the Liquid Glass look (glass buttons and banners) that macOS 26+ provides.
- **Safety:** the app never writes to a device on its own. Every write needs an explicit click, and by default a confirmation that shows the exact bytes.
- **Honesty:** when macOS does not expose something (Bluetooth addresses for BLE, raw advertising PDUs, bonding state…), the UI says so instead of making it up. See [macOS Bluetooth API Limitations](#macos-bluetooth-api-limitations).

---

## Features

### Discovery
- Start and stop a BLE scan (⌘R) with a live, de-duplicated device table: name, transport, RSSI bars, connection state, manufacturer, identifier and last-seen time.
- Sort by signal strength, name, last seen or identifier by clicking a column header.
- Filter by transport (BLE / Classic / possible dual-mode), named or unnamed, an RSSI threshold, advertised service UUID (`180D` or “heart rate”) and favorites. The global search (⌘F) matches name, identifier, service and characteristic UUIDs, SIG names, manufacturer and notes.
- Advertisement tracking: each advertising and scan-response callback is recorded. The merged advertisement shows the latest value of every field, and content changes are counted and logged.
- Find peripherals the system (or another app) is already connected to.
- Classic inquiry (⇧⌘I) plus the system's paired and recent Classic devices.

### Device inspector
| Tab | What it shows |
|---|---|
| Overview | Identity, status, advertising summary, GATT summary, Classic details (address, OUI, Class of Device, paired/connected, PnP vendor/product/version, profiles) and a per-transport list of what macOS does *not* expose |
| Advertisement | Structured table (field / decoded value / raw hex) and the most recent 300 packets with RSSI |
| GATT | Service → characteristic → descriptor tree (primary, secondary and included services), property chips, and a detail pane with read, subscribe, the write editor, descriptors and per-characteristic history |
| Values | Real-time table of notifications/indications, read responses and writes: timestamp, characteristic, decoded value, hex and byte count; CSV export |
| RSSI | Swift Charts line chart with 30 s / 1 min / 5 min / 15 min windows; current, average, min, max and least-squares trend |
| Raw Data | Any payload (manufacturer data, service data, characteristic or descriptor values) as hex, ASCII, UTF-8, unsigned or signed integers (LE/BE), or binary, plus a hex dump |
| SDP Services (Classic) | Every SDP record with RFCOMM channel, L2CAP PSM and profile versions, and a browsable attribute/data-element tree |
| Notes | Local name, favorite, notes and forget |

### Read / write / notify
- Read any readable characteristic, or all of them at once (⇧⌘R).
- Write editor inputs: UTF-8 text, hex (`01 A0 FF`, `0x01,0xA0`, `01:A0`…), decimal bytes, and signed or unsigned 8/16/32/64-bit integers in either byte order. Input is validated as you type, and the exact bytes to be sent are shown.
- Write with response or without response (limited to what the characteristic supports). Sizes are checked against the ATT limits CoreBluetooth reports for the connection.
- Subscribe to notifications and indications; incoming values appear live and are decoded.
- Reads, writes and notifications have distinct colors and icons everywhere (blue, orange and purple).

### Bluetooth SIG decoding
- Name tables generated from the official Bluetooth SIG assigned-numbers YAML: every GATT service, characteristic and descriptor, 16-bit member UUIDs, SDP service classes and protocols, units, appearance values, and a curated set of about 120 company identifiers. Well-known vendor UUIDs (Nordic UART and DFU, Apple ANCS/AMS/Continuity, Google Fast Pair) are included.
- Payload decoders:
  - Heart Rate Measurement (incl. energy expended and RR intervals), Body Sensor Location, Battery Level
  - Blood Pressure Measurement, PLX Spot-Check and Continuous, Temperature Measurement / Intermediate Temperature / Temperature Type, Glucose Measurement, Weight Measurement (IEEE-11073 SFLOAT/FLOAT)
  - Environmental Sensing: temperature, humidity, pressure, UV index, dew point, elevation, irradiance
  - Cycling Speed & Cadence, Cycling Power Measurement, Running Speed & Cadence, Sensor Location
  - Fitness Machine: Indoor Bike Data, Treadmill Data (stable leading fields), Fitness Machine Feature, Training Status, supported speed/power/resistance ranges
  - GAP/GATT/Device Information: device-information strings, Appearance, Peripheral Preferred Connection Parameters, Service Changed, Tx Power, PnP ID, System ID, Current Time, Date Time, Database Hash, HID Information, Protocol Mode
  - Descriptors: Extended Properties, User Description, CCCD, SCCD, Presentation Format, Report Reference
  - Any characteristic that carries a **Presentation Format descriptor (0x2904)** is decoded generically (format × 10^exponent + unit), which covers many vendor characteristics.
  - Advertisements: Apple iBeacon (and other Apple TLV type names), Google Eddystone UID/URL/TLM/EID, battery service data.
- An **Assigned Numbers** browser lists every bundled name and marks which characteristics have a decoder.

### Activity console
- Console-style log (`18:42:04.019  NOTIFY   [R11M] 2A37  00 48`) with category filters (scan, connection, services, reads, writes, notifications, errors, plus decoded values, RSSI, Classic and system), search, a per-device scope, pause (events keep being recorded), clear (⌘K), copy, and export as text, CSV or JSON.
- Holds 10,000 events by default (configurable from 1,000 to 50,000) in a ring buffer. The UI receives throttled snapshots (at most 4 per second), so notification bursts don't stall the interface.
- Every event is mirrored to the unified log (`subsystem: io.github.popshark57.BluetoothInspector`) with names and payloads marked private.

### Saved devices, export, diagnostics
- **Saved Devices** remembers identifier, name, first/last seen, transport, known services and manufacturer. It records connected, paired and favorite devices by default, or every device seen, or nothing. You can favorite, rename locally, add notes, or forget. Data is stored as JSON in Application Support.
- **Export** (⌘E):
  - One device as JSON, a value-history CSV, or a plain-text diagnostic report.
  - The whole session as JSON, a device-list CSV, or text reports.
  - The activity log as JSON, CSV or text.
  - JSON is versioned (`schemaVersion`) and self-describing: hex *and* decoded values, UUIDs *and* SIG names. It follows `{ device, advertisement, services, characteristics, values, rssi, classic, events }`.
- **Diagnostics** shows the macOS and app versions, Bluetooth power and authorization state, scanner state, connected peripherals, the local controller's address, name, power and Class of Device, and log statistics. **Copy Diagnostics** puts all of it on the clipboard.

### Keyboard shortcuts
| Shortcut | Action |
|---|---|
| ⌘R | Start / stop BLE scan |
| ⇧⌘I | Start / stop Classic inquiry |
| ⌘↩ | Connect / disconnect the selected device (Classic: SDP query) |
| ⇧⌘R | Read all readable characteristics |
| ⇧⌘↩ | Send the write in the write editor |
| ⌘K | Clear console |
| ⇧⌘P | Pause / resume console |
| ⌘F | Search |
| ⌘E | Export… |
| ⇧⌘E | Export activity log as CSV |
| ⌘1…⌘7 | Switch sidebar section |
| ⌥⌘⌫ | Clear discovered devices |

Almost every technical value has a context menu: copy UUID, value, hex, device identifier or service information. Tables and text are selectable.

---

## macOS Bluetooth API Limitations

These are platform limits of the public APIs, not missing features. The app shows them in the Overview tab and on the Diagnostics screen.

### Bluetooth Low Energy (CoreBluetooth)
- **No Bluetooth addresses.** CoreBluetooth identifies peripherals by a UUID generated per Mac. The device's BD_ADDR, its address type (public, random static, resolvable private) and address rotation are not visible.
- **No raw advertising data.** Apps get only CoreBluetooth's parsed fields: local name, service UUIDs, overflow UUIDs, solicited UUIDs, manufacturer data, service data, TX power and connectable. The AD Flags field (and with it “BR/EDR not supported”), appearance, advertising interval, PHY, channel, extended-advertising details and the raw PDU are not exposed.
- **Scan response is merged.** Advertising and scan-response packets are delivered as callbacks that can't be told apart, so the app shows a merged view plus the individual callbacks.
- **No bonding state and no explicit pairing.** Apps can't ask whether a peripheral is bonded or start pairing. macOS pairs automatically when an encrypted or authenticated attribute is accessed; the app surfaces the ATT error and explains it.
- **System-reserved services are hidden.** HID over GATT (0x1812) and some GAP/GATT attributes are consumed by macOS and do not appear in discovery.
- **The CCCD is managed by the system.** Notifications and indications are enabled through `setNotifyValue`; writing descriptor 0x2902 directly is not allowed.
- **Read responses and notifications share one callback.** The app tells them apart by tracking outstanding reads. A notification that arrives while a read on the same characteristic is pending may be counted as the read response.
- **No connection-parameter or PHY control.** The only link details available are the maximum write lengths (ATT MTU − 3); connection interval, latency, PHY and data length are not.
- **RSSI** comes from advertisements while scanning, or from `readRSSI()` polling while connected. It is noisy and relative, and the app never presents it as distance.
- **Connection timeouts are not built in.** CoreBluetooth retries a connection indefinitely; the app cancels after a configurable timeout (15 s by default).
- **`CBCentralManager.supports(_:)` (extended scanning) and connection-event registration are iOS-only.** Channel Sounding (new in iOS 27) is not used because it is not documented for macOS.

### Bluetooth Classic (IOBluetooth)
- **Available and implemented:**
  - paired devices and the system's recent devices
  - inquiry with name resolution
  - Class of Device, pairing and connection state
  - last inquiry, name and services update times
  - SDP queries and every SDP record and attribute
  - connect/disconnect notifications
  - local controller address, name, power state and Class of Device
- **Vendor information** comes from the SDP PnP Information (Device ID) record when present. The address OUI is shown, but no IEEE OUI database is bundled.
- **RSSI** is only available while a baseband connection exists.
- **Not implemented, deliberately:** starting pairing, opening RFCOMM or L2CAP channels, and baseband connections for their own sake. These change device state (this is an inspector) or aren't usable from a sandboxed app. Link keys and HCI-level data aren't available through public APIs at all.
- **`IOBluetoothDevice.pairedDevices()` returns nothing** unless the app has the `com.apple.security.device.bluetooth` entitlement and the user granted Bluetooth access.

### Dual-mode
There is no public API that links a CoreBluetooth peripheral UUID to an IOBluetooth BD_ADDR, and the AD Flags that announce BR/EDR support are hidden. So **dual-mode can't be determined**. The app flags a *possible* dual-mode device only when a BLE peripheral and a Classic device report the same name, and labels it as a heuristic.

---

## Permissions

| Requirement | Where |
|---|---|
| `NSBluetoothAlwaysUsageDescription` (Bluetooth privacy prompt; needed by both CoreBluetooth and IOBluetooth) | generated Info.plist (`INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription`) |
| App Sandbox | `Config/BluetoothInspector.entitlements` |
| `com.apple.security.device.bluetooth` (Bluetooth access in the sandbox) | entitlements |
| `com.apple.security.files.user-selected.read-write` (export save panel, SIG database import) | entitlements |

If access was denied, the app shows a banner with a button to open **System Settings › Privacy & Security › Bluetooth**. If Bluetooth is off, the button opens **Bluetooth** settings instead.

---

## Building

Requirements: an Apple silicon Mac with Xcode 27 (macOS 27 SDK). Xcode 26 also works; CI builds with both.

```sh
git clone https://github.com/PopShark57/BluetoothInspector.git
cd BluetoothInspector
open BluetoothInspector.xcodeproj    # then Run (⌘R)
```

The project signs with “Sign to Run Locally” (ad-hoc), so it builds without a developer team. To keep the Bluetooth permission between builds, or to distribute the app, set your team under *Signing & Capabilities*.

Command line:

```sh
# Core package tests (macOS or Linux)
swift test --package-path BluetoothInspectorKit

# App build
xcodebuild -project BluetoothInspector.xcodeproj -scheme BluetoothInspector \
  -configuration Debug -destination 'platform=macOS' build
```

GitHub Actions (`.github/workflows/ci.yml`) runs the package tests on Linux, and runs the package tests plus Debug and Release app builds on the `xcode-27` and `macos-26` runners.

---

## Architecture

```
BluetoothInspector.xcodeproj         App target (synchronized folders) + local package reference
BluetoothInspector/                  macOS app (platform-specific code only)
├── App/                             @main app, AppModel (composition root), menu commands, OSLog mirror
├── Bluetooth/
│   ├── BLE/                         CoreBluetoothClient (BLEClient impl), CB ↔ Kit mapping, ATT/CB error text
│   └── Classic/                     IOBluetoothClassicClient (ClassicClient impl), SDP conversion
├── Services/                        Export documents, settings persistence, system info
├── Views/
│   ├── Discovery/                   Device table, filters, browser split view
│   ├── Device/                      Inspector tabs (overview, advertisement, values, RSSI, raw, SDP, notes)
│   ├── GATT/                        GATT tree, characteristic detail, write editor
│   ├── Console/                     Activity console
│   ├── Settings/                    Settings, diagnostics, assigned-numbers browser
│   ├── Export/                      Export sheet
│   └── Shared/                      Badges, rows, status banner, pasteboard helpers
└── Resources/                       Asset catalog (app icon, accent color)
BluetoothInspectorKit/               Swift package — hardware-independent core (Foundation + Observation only)
├── Sources/BluetoothInspectorKit/
│   ├── Bytes/                       ByteReader, ByteFormatter, HexParser, WriteValueEncoder, IEEE-11073 floats
│   ├── Models/                      DeviceID, BluetoothUUID, advertisement, GATT tree, states
│   ├── SIG/                         Assigned numbers (generated tables + runtime extension), Class of Device
│   ├── Decoders/                    PayloadDecoder protocol, DecoderRegistry, health/fitness/environment/generic/descriptor decoders
│   ├── Classic/                     ClassicDeviceInfo, SDP data elements and records, PnP info
│   ├── Clients/                     BLEClient / ClassicClient protocols and their event enums
│   ├── Workspace/                   BluetoothWorkspace (observable state machine), InspectedDevice, ActivityLog, settings
│   ├── Logging/                     RingBuffer, EventLog, ActivityEvent
│   ├── RSSI/                        RSSIHistory, statistics, trend
│   ├── Search/                      SearchMatcher, device list filtering/sorting
│   ├── Persistence/                 DeviceHistory + file/in-memory stores
│   └── Export/                      JSON export models, ExportBuilder, CSV, text reports
└── Tests/                           Swift Testing suites (116 tests) incl. scripted mock BLE/Classic clients
Scripts/generate_sig_tables.py       Regenerates SIG name tables (and an optional full JSON database)
Config/BluetoothInspector.entitlements
```

**Data flow.**
1. `CoreBluetoothClient` and `IOBluetoothClassicClient` turn delegate callbacks into value-type events (`BLEEvent`, `ClassicEvent`).
2. `BluetoothWorkspace` applies those events to observable `InspectedDevice` models, the `ActivityLog` and the `DeviceHistory`.
3. SwiftUI views observe the workspace. Commands flow back as workspace methods, which validate state and properties before calling the client.

**Concurrency.**
- The central manager runs on the main queue. IOBluetooth callbacks arrive on the main run loop.
- Clients, workspace and models are `@MainActor`, and delegate conformances use `@preconcurrency`, so isolation is checked at runtime.
- High-rate data (RSSI samples, advertisement packets, value history, console events) goes into ring buffers. The workspace publishes these at most 4 times per second from a single UI tick, so observation never fires per packet.
- The package builds in Swift 6 language mode with complete concurrency checking.

**Testability.** Everything that doesn't need a radio lives in `BluetoothInspectorKit`, and the workspace talks to hardware only through the `BLEClient` and `ClassicClient` protocols. The tests drive the full workspace with scripted mock clients and cover:
- scan lifecycle and power states
- connection timeouts and disconnects
- the GATT hierarchy
- notification logging and decoding
- write validation
- history
- dual-mode hints
- export

Production code contains no fake Bluetooth data.

**Extending decoders.** Conform to `PayloadDecoder`, or build a `ClosureDecoder`, and register it:

```swift
var registry = DecoderRegistry.standard
registry.register(characteristic: ClosureDecoder(name: "My Sensor", uuids: [0xFFF1]) { data in
    DecodedValue(summary: "…", fields: [...], decoder: "My Sensor")
})
workspace.decoders = registry
```

**Extending the SIG database.** The bundled company list is curated. To load the full SIG database at runtime (Settings › Load SIG Database JSON…), generate the JSON first:

```sh
git clone https://bitbucket.org/bluetooth-SIG/public.git /tmp/sig
python3 Scripts/generate_sig_tables.py /tmp/sig/assigned_numbers --full-json   # writes sig-database.json
```

Run the same script without `--full-json` to regenerate the built-in Swift tables.

### Designed for later
These are not built yet, but the architecture leaves room for them:
- **Capture and replay:** events are values, and `handle(_:)` is public, so recorded sessions could be replayed.
- **Custom protocol definitions and plugins:** these fit the `DecoderRegistry` extension point.
- **iPhone, iPad or Watch companions:** the Kit has no AppKit dependency.
- **Device comparison and fingerprinting:** exports are structured, versioned JSON.
- **Traffic visualization:** the value history and RSSI time series are already recorded.

---

## Bluetooth SIG data

Service, characteristic, descriptor, unit, member-UUID, SDP class, protocol, appearance and company names come from the Bluetooth SIG *Assigned Numbers* repository (<https://bitbucket.org/bluetooth-SIG/public>). They are generated into `SIG/AssignedNumbers+Tables.swift` by `Scripts/generate_sig_tables.py`. The Bluetooth® word mark is owned by Bluetooth SIG, Inc.
