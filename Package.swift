// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExerciseAnalyserCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ExerciseAnalyserCore", targets: ["ExerciseAnalyserCore"])],
    targets: [
        .target(name: "ExerciseAnalyserCore", path: "ExerciseAnalyser Watch App/Core"),
        .testTarget(name: "ExerciseAnalyserCoreTests", dependencies: ["ExerciseAnalyserCore"], path: "Tests")
    ]
)
