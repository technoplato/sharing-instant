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
    // SharingInstant (parent directory) - includes InstantDB transitively
    .package(path: ".."),
  ],
  targets: [
    .executableTarget(
      name: "CaseStudies",
      dependencies: [
        .product(name: "SharingInstant", package: "sharing-instant"),
      ],
      path: "CaseStudies",
      exclude: [
        "Info.plist",
        "instant.schema.ts",
        "instant.perms.ts",
        // Node modules are used for instant-cli schema push, not needed in app bundle
        "node_modules",
        "package.json",
        "package-lock.json",
      ]
    ),
  ]
)

