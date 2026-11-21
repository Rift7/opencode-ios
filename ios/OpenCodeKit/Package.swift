// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "OpenCodeKit",
  platforms: [.iOS(.v27), .macOS(.v15)],
  products: [
    .library(name: "OpenCodeCore", targets: ["OpenCodeCore"]),
    .library(name: "OpenCodeServer", targets: ["OpenCodeServer"]),
    .library(name: "OpenCodeApp", targets: ["OpenCodeApp"]),
    .library(name: "OpenCodeTestSupport", targets: ["OpenCodeTestSupport"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture",
      exact: "1.26.2"
    )
  ],
  targets: [
    .target(
      name: "OpenCodeCore",
      dependencies: [
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture")
      ]
    ),
    .target(
      name: "OpenCodeServer",
      dependencies: ["OpenCodeCore"]
    ),
    .target(
      name: "OpenCodeApp",
      dependencies: [
        "OpenCodeCore",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .target(
      name: "OpenCodeTestSupport",
      dependencies: ["OpenCodeCore"]
    ),
    .testTarget(
      name: "OpenCodeAppTests",
      dependencies: ["OpenCodeApp", "OpenCodeCore"]
    ),
    .testTarget(
      name: "OpenCodeCoreTests",
      dependencies: ["OpenCodeCore", "OpenCodeServer", "OpenCodeTestSupport"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
