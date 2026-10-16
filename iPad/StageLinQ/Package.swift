// swift-tools-version:5.7
import PackageDescription

// StageLinQ: reads track, key, BPM and fader data from Denon DJ / Engine DJ
// gear (SC6000, X1800, Prime …) on the local network.
//
//   swift run stagelinq-monitor     # Mac test tool: shows what the decks report
//   swift test                      # codec + key parsing tests
let package = Package(
    name: "StageLinQ",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "StageLinQ", targets: ["StageLinQ"]),
        .executable(name: "stagelinq-monitor", targets: ["stagelinq-monitor"]),
    ],
    targets: [
        .target(name: "StageLinQ"),
        .executableTarget(name: "stagelinq-monitor", dependencies: ["StageLinQ"]),
        .testTarget(name: "StageLinQTests", dependencies: ["StageLinQ"]),
    ]
)
