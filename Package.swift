// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TouchOTP",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TouchOTP", targets: ["TouchOTP"])],
    targets: [
        .target(name: "TouchOTPCore"),
        .executableTarget(name: "TouchOTP", dependencies: ["TouchOTPCore"]),
        .testTarget(name: "TouchOTPCoreTests", dependencies: ["TouchOTPCore"]),
        .testTarget(name: "TouchOTPTests", dependencies: ["TouchOTP"])
    ]
)
