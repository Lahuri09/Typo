// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Typo",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Typo", targets: ["Typo"])],
    targets: [
        .target(name: "TypoCore", resources: [.copy("Lexicons")]),
        .executableTarget(name: "Typo", dependencies: ["TypoCore"],
                          swiftSettings: [.defaultIsolation(MainActor.self)]),
        .executableTarget(name: "TypoCoreTests", dependencies: ["TypoCore"], path: "Tests/TypoCoreTests")
    ]
)
