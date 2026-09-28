// swift-tools-version: 6.0
// NeuralLoopCore: the pure, tested logic shared by the Mac and iPad apps (the app targets live in the Xcode project).
import PackageDescription

let package = Package(
    name: "NeuralLoop",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "NeuralLoopCore", targets: ["NeuralLoopCore"])],
    targets: [
        .target(name: "NeuralLoopCore"),
        .testTarget(name: "NeuralLoopCoreTests", dependencies: ["NeuralLoopCore"]),
    ]
)
