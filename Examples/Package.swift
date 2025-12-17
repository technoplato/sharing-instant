// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "Examples",
  platforms: [
    .iOS(.v17),
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "CaseStudies",
      targets: ["CaseStudies"]
    ),
  ],
  dependencies: [
    .package(path: ".."),
  ],
  targets: [
    .target(
      name: "CaseStudies",
      dependencies: [
        .product(name: "SharingInstant", package: "sharing-instant"),
      ],
      path: "CaseStudies"
    ),
  ]
)

