// swift-tools-version:5.7
import PackageDescription

// DJ network protocols KDM reads track keys from:
//   StageLinQ   Denon DJ / Engine DJ (SC6000, X1800, Prime …)
//   ProDJLink   Pioneer DJ Pro DJ Link (CDJ-3000, DJM-A9 …)
//
//   swift run stagelinq-monitor     # Mac test tool: what Denon decks report
//   swift run prodjlink-monitor     # Mac test tool: what Pioneer players report
//   swift run kdm-bridge            # Mac helper: Serato DJ Pro decks -> KDM
//   swift test                      # protocol + key parsing tests
let package = Package(
    name: "StageLinQ",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "StageLinQ", targets: ["StageLinQ"]),
        .executable(name: "stagelinq-monitor", targets: ["stagelinq-monitor"]),
        .library(name: "ProDJLink", targets: ["ProDJLink"]),
        .executable(name: "prodjlink-monitor", targets: ["prodjlink-monitor"]),
        .executable(name: "kdm-bridge", targets: ["kdm-bridge"]),
    ],
    targets: [
        .target(name: "StageLinQ"),
        .executableTarget(name: "stagelinq-monitor", dependencies: ["StageLinQ"]),
        .testTarget(name: "StageLinQTests", dependencies: ["StageLinQ"]),
        .target(name: "ProDJLink"),
        .executableTarget(name: "prodjlink-monitor", dependencies: ["ProDJLink"]),
        .testTarget(name: "ProDJLinkTests", dependencies: ["ProDJLink"]),
        // Mac helper: sends Serato DJ Pro's decks (key, BPM, track) to KDM.
        .executableTarget(name: "kdm-bridge"),
    ]
)
