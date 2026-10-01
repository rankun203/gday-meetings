// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "DiarizationBenchmark",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "NemotronBenchmark", targets: ["Benchmark"]),
    .executable(name: "Community1Benchmark", targets: ["Community1Benchmark"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/FluidInference/FluidAudio.git",
      revision: "21493f8dac5a97e65742e6ff26f42f164c2fda0f",
      traits: []
    )
  ],
  targets: [
    .target(name: "BenchmarkSupport"),
    .executableTarget(
      name: "Benchmark",
      dependencies: [
        "BenchmarkSupport",
        .product(name: "FluidAudio", package: "FluidAudio"),
      ]),
    .executableTarget(
      name: "Community1Benchmark",
      dependencies: [
        "BenchmarkSupport",
        .product(name: "FluidAudio", package: "FluidAudio"),
      ]),
  ]
)
