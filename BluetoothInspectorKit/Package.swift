// swift-tools-version: 6.0
//
// BluetoothInspectorKit holds everything in Bluetooth Inspector that does not
// need Bluetooth hardware: models, byte handling, Bluetooth SIG metadata,
// payload decoders, the activity log, export, persistence, and the observable
// workspace that turns raw client events into UI state.
//
// It deliberately depends only on Foundation and Observation so it builds and
// tests on any Swift toolchain (including Linux CI); the CoreBluetooth and
// IOBluetooth adapters live in the macOS app target and talk to this package
// through the protocols in `Clients/`.
import PackageDescription

let package = Package(
    name: "BluetoothInspectorKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BluetoothInspectorKit", targets: ["BluetoothInspectorKit"]),
    ],
    targets: [
        .target(name: "BluetoothInspectorKit"),
        .testTarget(
            name: "BluetoothInspectorKitTests",
            dependencies: ["BluetoothInspectorKit"]
        ),
    ]
)
