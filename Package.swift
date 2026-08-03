// swift-tools-version:5.9
import PackageDescription

// The product (and therefore the built binary) is "my-stickies". The target keeps the
// underscored spelling because Swift module names can't contain hyphens; that name is
// internal and never appears outside this file.
let package = Package(
    name: "my-stickies",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "my-stickies", targets: ["my_stickies"])
    ],
    targets: [
        .executableTarget(name: "my_stickies", path: "Sources/my_stickies")
    ]
)
