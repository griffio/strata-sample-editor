// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Strata",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "Strata", targets: ["Strata"])
    ],
    targets: [
        .target(
            name: "StrataAtomics",
            path: "Sources/StrataAtomics"
        ),
        .executableTarget(
            name: "Strata",
            dependencies: ["StrataAtomics"],
            path: "Sources/Strata"
        ),
        .testTarget(
            name: "StrataTests",
            dependencies: ["Strata"],
            path: "Tests/StrataTests"
        )
    ]
)
