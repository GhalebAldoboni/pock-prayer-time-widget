// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "PrayerTimeWidget",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "PrayerTimeWidget",
            type: .dynamic,
            targets: ["PrayerTimeWidget"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/pock/pockkit.git", branch: "master")
    ],
    targets: [
        .target(
            name: "PrayerTimeWidget",
            dependencies: [
                .product(name: "PockKit", package: "pockkit")
            ],
            path: "Sources"
        )
    ]
)
