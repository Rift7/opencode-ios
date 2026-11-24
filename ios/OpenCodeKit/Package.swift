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
    .library(name: "OpenCodeTranscript", targets: ["OpenCodeTranscript"]),
    .library(name: "OpenCodeMedia", targets: ["OpenCodeMedia"]),
    .library(name: "OpenCodeComposer", targets: ["OpenCodeComposer"]),
    .library(name: "OpenCodeSession", targets: ["OpenCodeSession"]),
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
      name: "OpenCodeTranscript",
      dependencies: ["OpenCodeCore", "OpenCodeServer"]
    ),
    .target(
      name: "OpenCodeMedia",
      dependencies: [
        "OpenCodeCore",
        "OpenCodeServer",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .target(
      name: "OpenCodeComposer",
      dependencies: [
        "OpenCodeCore",
        "OpenCodeServer",
        "OpenCodeMedia",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .target(
      name: "OpenCodeSession",
      dependencies: [
        "OpenCodeCore",
        "OpenCodeServer",
        "OpenCodeTranscript",
        "OpenCodeMedia",
        "OpenCodeComposer",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .target(
      name: "OpenCodeApp",
      dependencies: [
        "OpenCodeCore",
        "OpenCodeServer",
        "OpenCodeDrawer",
        "OpenCodeMedia",
        "OpenCodeSession",
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
      name: "OpenCodeComposerTests",
      dependencies: ["OpenCodeComposer", "OpenCodeMedia", "OpenCodeCore", "OpenCodeServer", "OpenCodeTestSupport"]
    ),
    .testTarget(
      name: "OpenCodeMediaTests",
      dependencies: ["OpenCodeMedia", "OpenCodeCore", "OpenCodeServer", "OpenCodeTestSupport"]
    ),
    .testTarget(
      name: "OpenCodeSessionTests",
      dependencies: [
        "OpenCodeSession", "OpenCodeComposer", "OpenCodeCore", "OpenCodeServer",
        "OpenCodeTestSupport",
      ]
    ),
    .testTarget(
      name: "OpenCodeTranscriptTests",
      dependencies: ["OpenCodeTranscript", "OpenCodeCore", "OpenCodeServer", "OpenCodeTestSupport"]
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
