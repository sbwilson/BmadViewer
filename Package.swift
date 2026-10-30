// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BmadViewer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BmadViewer", targets: ["BmadViewer"]),
        .library(name: "BmadKit", targets: ["BmadKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", from: "0.4.0"),
    ],
    targets: [
        // Pure model + loaders: no AppKit, so it is testable headless.
        .target(
            name: "BmadKit",
            dependencies: ["Yams", "TOMLDecoder"]
        ),
        // The app: SwiftUI shell, AppKit document view, file actions.
        .executableTarget(
            name: "BmadViewer",
            dependencies: [
                "BmadKit",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            // The icon source: scripts/make-app.sh turns it into the bundle's .icns.
            exclude: ["icon.png"]
        ),
        .testTarget(
            name: "BmadKitTests",
            dependencies: ["BmadKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
