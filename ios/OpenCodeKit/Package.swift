// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "OpenCodeKit",
  platforms: [.iOS(.v27), .macOS(.v15)],
  products: [
    .library(name: "OpenCodeCore", targets: ["OpenCodeCore"]),
    .library(name: "OpenCodeServer", targets: ["OpenCodeServer"]),
    .library(name: "OpenCodeApp", targets: ["OpenCodeApp"]),
    .library(name: "OpenCodeDrawer", targets: ["OpenCodeDrawer"]),
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
      name: "OpenCodeDrawer",
      dependencies: [
        "OpenCodeCore",
        "OpenCodeServer",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .target(
      name: "OpenCodeApp",
      dependencies: [
        "OpenCodeCore",
        "OpenCodeServer",
        "OpenCodeDrawer",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .target(
      name: "OpenCodeTestSupport",
      dependencies: ["OpenCodeCore"]
    ),
    .testTarget(
      name: "OpenCodeAppTests",
      dependencies: ["OpenCodeApp", "OpenCodeDrawer", "OpenCodeCore", "OpenCodeServer", "OpenCodeTestSupport"]
    ),
    .testTarget(
      name: "OpenCodeDrawerTests",
      dependencies: ["OpenCodeDrawer", "OpenCodeCore", "OpenCodeServer", "OpenCodeTestSupport"]
    ),
    .testTarget(
      name: "OpenCodeCoreTests",
      dependencies: ["OpenCodeCore", "OpenCodeServer", "OpenCodeTestSupport"]
    ),
    .testTarget(
      name: "OpenCodeServerTests",
      dependencies: ["OpenCodeServer", "OpenCodeCore", "OpenCodeTestSupport"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
