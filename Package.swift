// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "sharing-instant",
  platforms: [
    .iOS(.v15),
    .macCatalyst(.v15),
    .macOS(.v14),  // Raised to v14 for Testing framework compatibility
    .tvOS(.v15),
    .watchOS(.v8)
  ],
  products: [
    .library(
      name: "SharingInstant",
      targets: ["SharingInstant"]
    ),
    .library(
      name: "InstantSchemaCodegen",
      targets: ["InstantSchemaCodegen"]
    ),
    .executable(
      name: "instant-schema",
      targets: ["instant-schema"]
    ),
    .plugin(
      name: "InstantSchemaPlugin",
      targets: ["InstantSchemaPlugin"]
    ),
  ],
  dependencies: [
    // The upstream InstantDB iOS SDK (local path for development)
    .package(path: "../instant-ios-sdk"),
    // Swift Sharing library from Point-Free
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.3.0"),
    // Swift Dependencies for DI
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.6.4"),
    // Identified collections for type-safe arrays
    .package(url: "https://github.com/pointfreeco/swift-identified-collections", from: "1.1.1"),
    // Swift Parsing for bidirectional schema parsing/printing
    .package(url: "https://github.com/pointfreeco/swift-parsing", from: "0.14.1"),
    // Swift Snapshot Testing for verifying generated code
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.0"),
    // Swift Argument Parser for CLI
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
  ],
  targets: [
    .target(
      name: "SharingInstant",
      dependencies: [
        .product(name: "InstantDB", package: "instant-ios-sdk"),
        .product(name: "Sharing", package: "swift-sharing"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
      ]
    ),
    // Schema codegen library
    .target(
      name: "InstantSchemaCodegen",
      dependencies: [
        .product(name: "Parsing", package: "swift-parsing"),
      ]
    ),
    // Schema codegen CLI
    .executableTarget(
      name: "instant-schema",
      dependencies: [
        "InstantSchemaCodegen",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "IntegrationRunner",
      dependencies: [
        "SharingInstant",
      ],
      path: "Sources/IntegrationRunner",
      swiftSettings: [
        .unsafeFlags(["-parse-as-library"])
      ]
    ),
    .testTarget(
      name: "SharingInstantTests",
      dependencies: [
        "SharingInstant",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "InstantSchemaCodegenTests",
      dependencies: [
        "InstantSchemaCodegen",
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
      ],
      // Snapshot files are managed by SnapshotTesting library, not SPM resources
      exclude: [
        "__Snapshots__"
      ],
      resources: [
        .copy("Fixtures")
      ]
    ),
    // SPM Build Plugin for automatic schema codegen
    .plugin(
      name: "InstantSchemaPlugin",
      capability: .buildTool(),
      dependencies: [
        .target(name: "instant-schema")
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
