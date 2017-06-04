// swift-tools-version:3.1

import PackageDescription

let package = Package(
    name: "LittleCMS",
    targets: [
        Target(name: "LittleCMS")
    ],
    dependencies: [
        .Package(url: "https://github.com/PureSwift/CLCMS.git", majorVersion: 1)
    ]
)
