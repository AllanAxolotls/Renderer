// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Renderer",

    platforms: [
        .macOS(.v10_15),
    ],  
    targets: [
        .executableTarget(
            name: "Renderer",
            resources: [.process("Render/Shaders")],
        ),
    ],

    
)
