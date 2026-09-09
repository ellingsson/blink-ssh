// swift-tools-version:5.9

import PackageDescription

let package = Package(
  name: "SwiftTerm",
  platforms: [
    .iOS(.v13),
    .macOS(.v13),
  ],
  products: [
    .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
  ],
  targets: [
    .target(
      name: "SwiftTerm",
      path: "Sources/SwiftTerm",
      exclude: ["Mac/README.md"]
    ),
    .testTarget(
      name: "SwiftTermTests",
      dependencies: ["SwiftTerm"]
    ),
  ]
)
