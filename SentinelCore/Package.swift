// swift-tools-version:5.7
import PackageDescription

// SentinelCore holds every piece of HCG Sentinel logic that does not need UIKit,
// SwiftUI, CoreBluetooth or Network.framework, so it can be unit-tested on
// macOS and Linux without a simulator.
//
// HCGDeviceLink (../HCGDeviceLink) is the HCG Device Link client vendored
// unchanged from HCG-Server: report sharing with paired devices. On Apple
// platforms it needs nothing beyond the SDK; on Linux it builds with
// swift-crypto for the tests.
let package = Package(
    name: "SentinelCore",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(name: "SentinelCore", targets: ["SentinelCore"])
    ],
    dependencies: [
        .package(path: "../HCGDeviceLink")
    ],
    targets: [
        .target(name: "SentinelCore", dependencies: [.product(name: "HCGDeviceLink", package: "HCGDeviceLink")]),
        .testTarget(name: "SentinelCoreTests", dependencies: ["SentinelCore"])
    ]
)
