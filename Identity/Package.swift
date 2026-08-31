// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProductIdentity",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ProductIdentity", targets: ["ProductIdentity"]),
    ],
    targets: [
        .target(
            name: "ProductIdentity",
            resources: [.copy("Resources/product-identity.json")]
        ),
        .testTarget(
            name: "ProductIdentityTests",
            dependencies: ["ProductIdentity"]
        ),
    ]
)
