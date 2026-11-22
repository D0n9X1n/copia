// swift-tools-version: 6.4
import PackageDescription

let package = Package(
	name: "Copia",
	platforms: [.macOS(.v27)],
	products: [
		.executable(name: "Copia", targets: ["Copia"]),
		.executable(name: "copia-render", targets: ["CopiaRender"]),
		.executable(name: "copia-bench", targets: ["CopiaBench"]),
	],
	dependencies: [
		.package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0"),
	],
	targets: [
		.target(name: "CopiaCore"),
		.target(
			name: "CopiaUI",
			dependencies: ["CopiaCore", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")]
		),
		.target(name: "CopiaFixtures", dependencies: ["CopiaCore"]),
		.target(name: "CopiaStore", dependencies: ["CopiaCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
		.target(
			name: "CopiaSystem",
			dependencies: ["CopiaCore", "CopiaStore", "CopiaUI"]
		),
		.target(
			name: "CopiaApp",
			dependencies: ["CopiaCore", "CopiaStore", "CopiaSystem", "CopiaUI",
				.product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")]
		),
		.executableTarget(name: "Copia", dependencies: ["CopiaApp"]),
		.executableTarget(name: "CopiaBench", dependencies: ["CopiaApp", "CopiaCore", "CopiaStore", "CopiaFixtures", "CopiaUI"]),
		.executableTarget(name: "CopiaRender", dependencies: ["CopiaUI", "CopiaFixtures"]),
		.testTarget(name: "CopiaTests", dependencies: ["CopiaCore", "CopiaUI", "CopiaFixtures", "CopiaStore", "CopiaSystem", "CopiaApp", "CopiaBench"]),
	]
)
