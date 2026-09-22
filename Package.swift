// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "imbusy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "imbusy", targets: ["imbusy"]),
        .library(name: "ImBusyCore", targets: ["ImBusyCore"]),
    ],
    targets: [
        // Pure reconciliation logic. No EventKit import, so it is unit-testable with fakes.
        .target(name: "ImBusyCore"),
        // EventKit adapter implementing the CalendarStore protocol.
        .target(name: "ImBusyEventKit", dependencies: ["ImBusyCore"]),
        // Command-line entry point.
        .executableTarget(
            name: "imbusy",
            dependencies: ["ImBusyCore", "ImBusyEventKit"],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist in the binary so TCC can read the calendar usage description.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/imbusy/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "ImBusyCoreTests", dependencies: ["ImBusyCore"]),
    ]
)
