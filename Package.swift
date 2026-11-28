// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "tncode",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.4")
    ],
    targets: [
        .executableTarget(name: "tncode", dependencies: [
            .product(name: "SwiftTerm", package: "SwiftTerm")
        ]),
        .testTarget(name: "tncodeTests", dependencies: ["tncode"])
    ]
)
