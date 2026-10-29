// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Kaddo", platforms: [.macOS(.v14)], products: [.executable(name: "Kaddo", targets: ["Kaddo"])], targets: [.executableTarget(name: "Kaddo", resources: [.copy("Resources/Verification")], swiftSettings: [.swiftLanguageMode(.v5)]), .testTarget(name: "KaddoTests", dependencies: ["Kaddo"], swiftSettings: [.swiftLanguageMode(.v5)])])
