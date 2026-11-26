// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PiWorkspace",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.4")
    ],
    targets: [
        .executableTarget(name: "PiWorkspace", dependencies: [
            .product(name: "SwiftTerm", package: "SwiftTerm")
        ])
    ]
)
