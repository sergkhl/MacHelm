// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacHelm",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "fan-control-probe", targets: ["FanControlProbe"]),
        .executable(name: "fan-control-acceptance", targets: ["FanControlAcceptance"]),
        .executable(name: "MacHelmServiceRunner", targets: ["MacHelmServiceRunner"])
    ],
    targets: [
        .target(name: "FanControlCore"),
        .target(name: "FanControlHardware", dependencies: ["FanControlCore"]),
        .target(name: "FanControlRuntime", dependencies: ["FanControlCore"]),
        .executableTarget(name: "FanControlProbe", dependencies: ["FanControlCore", "FanControlHardware"]),
        .executableTarget(name: "FanControlAcceptance", dependencies: ["FanControlCore", "FanControlHardware"],
                          exclude: ["Tests", "README.md"]),
        .testTarget(name: "FanControlAcceptanceTests", dependencies: ["FanControlAcceptance", "FanControlCore"],
                    path: "Sources/FanControlAcceptance/Tests"),
        .testTarget(name: "FanControlTests", dependencies: ["FanControlCore", "FanControlHardware", "FanControlRuntime"],
                    resources: [.copy("Fixtures")]),
        .target(name: "StartupServicesCore"),
        .executableTarget(name: "MacHelmServiceRunner", dependencies: ["StartupServicesCore"]),
        .testTarget(name: "StartupServicesTests", dependencies: ["StartupServicesCore", "MacHelmServiceRunner"]),
        .target(name: "ToolkitCore"),
        .testTarget(name: "ToolkitTests", dependencies: ["ToolkitCore"]),
        .target(name: "ActivityCore"),
        .testTarget(name: "ActivityTests", dependencies: ["ActivityCore"]),
        .target(name: "PowerCore"),
        .testTarget(name: "PowerTests", dependencies: ["PowerCore"]),
        .target(name: "StorageCore"),
        .testTarget(name: "StorageTests", dependencies: ["StorageCore"])
    ]
)
