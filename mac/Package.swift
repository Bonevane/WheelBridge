// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WheelBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WheelBridge", targets: ["WheelBridge"]),
        .executable(name: "wheelbridged", targets: ["wheelbridged"]),
    ],
    targets: [
        // The contract shared with the Windows proxy.
        .target(name: "CWheelBridge"),
        // Everything that can be tested without a wheel or a window.
        .target(name: "WheelCore", dependencies: ["CWheelBridge"]),
        // The helper: owns the wheel and the motor. No UI.
        .executableTarget(name: "wheelbridged", dependencies: ["WheelCore"]),
        // The app: settings and diagnostics only. It never touches the motor.
        .executableTarget(name: "WheelBridge", dependencies: ["WheelCore"]),
        // Command Line Tools ship no XCTest, so the checks are a plain program.
        .executableTarget(name: "wheelcore-check", dependencies: ["WheelCore"]),
    ]
)
