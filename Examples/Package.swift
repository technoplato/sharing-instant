// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "Examples",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
    .tvOS(.v17),
    .watchOS(.v10)
  ],
  products: [
    .executable(
      name: "CaseStudies",
      targets: ["CaseStudies"]
    ),
  ],
  dependencies: [
    // SharingInstant (parent directory)
    .package(path: ".."),
    // InstantDB SDK (needed for transitive dependency resolution)
    .package(path: "../../instant-ios-sdk"),
  ],
  targets: [
    .executableTarget(
      name: "CaseStudies",
      dependencies: [
        .product(name: "SharingInstant", package: "sharing-instant"),
        .product(name: "InstantDB", package: "instant-ios-sdk"),
      ],
      path: "CaseStudies",
      exclude: ["Info.plist", "instant.schema.ts", "instant.perms.ts"]
    ),
  ]
)

