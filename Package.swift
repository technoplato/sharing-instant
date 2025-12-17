// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "sharing-instant",
  platforms: [
    .iOS(.v15),
    .macCatalyst(.v15),
    .macOS(.v12),
    .tvOS(.v15),
    .watchOS(.v8)
  ],
  products: [
    .library(
      name: "SharingInstant",
      targets: ["SharingInstant"]
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
    .testTarget(
      name: "SharingInstantTests",
      dependencies: [
        "SharingInstant",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
