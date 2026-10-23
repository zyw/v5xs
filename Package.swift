// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "v5xs",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "v5xs", targets: ["OrbitMonitor"])
    ],
    targets: [
        .target(
            name: "MonitorCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "OrbitMonitor",
            dependencies: ["MonitorCore"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreBluetooth")]
        ),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"])
    ]
)
