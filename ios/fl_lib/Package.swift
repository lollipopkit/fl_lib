// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "fl_lib",
  platforms: [.iOS("13.0")],
  products: [.library(name: "fl-lib", targets: ["fl_lib"])],
  dependencies: [],
  targets: [.target(name: "fl_lib", dependencies: [])]
)
