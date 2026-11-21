import AppKit

/// `copia-render [--output DIR] [--only SUBSTRING]`: captures every strip state to PNG for design review.
@main
enum Main {
	@MainActor static func main() {
		let args = CommandLine.arguments
		func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
		let output = URL(fileURLWithPath: value("--output") ?? "renders", isDirectory: true)
		let only = value("--only")

		let app = NSApplication.shared
		app.setActivationPolicy(.accessory)
		Task { @MainActor in
			do {
				try await RenderRunner.run(output: output, only: only)
				exit(0)
			} catch {
				FileHandle.standardError.write(Data("copia-render failed: \(error)\n".utf8))
				exit(1)
			}
		}
		app.run()
	}
}
