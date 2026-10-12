// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        // Core library with types and protocols
        .target(
            name: "MurmurCore",
            dependencies: []
        ),

        // llama.cpp (b11564), arm64 macOS slice, vendored.
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),

        // Engines library with implementations
        .target(
            name: "MurmurEngines",
            dependencies: [
                "MurmurCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                "llama",
            ]
        ),

        // Main executable
        .executableTarget(
            name: "Murmur",
            dependencies: [
                "MurmurCore",
                "MurmurEngines",
            ],
            linkerSettings: [
                // llama.framework ships in Murmur.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),

        // Benchmark executable
        .executableTarget(
            name: "murmur-bench",
            dependencies: ["MurmurCore", "MurmurEngines"]
        ),

        // Core tests
        .testTarget(
            name: "MurmurCoreTests",
            dependencies: ["MurmurCore"]
        ),

        // Engines tests
        .testTarget(
            name: "MurmurEnginesTests",
            dependencies: ["MurmurEngines", "MurmurCore"]
        ),
    ]
)
