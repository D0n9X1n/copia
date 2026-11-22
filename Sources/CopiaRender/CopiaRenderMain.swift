import AppKit

/// `copia-render [--output DIR] [--only SUBSTRING]`: captures every strip state to PNG for design review.
/// `copia-render --check-contrast DIR`: measures the glass text and lens probes recorded in DIR/manifest.json;
/// exits nonzero below 4.5:1 (text) or 3:1 (lens).
/// `copia-render --readme --output DIR`: the README's product shots (see scripts/readme-media.sh).
@main
enum Main {
	@MainActor static func main() {
		let args = CommandLine.arguments
		func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
		if let directory = value("--check-contrast") {
			exit(RenderRunner.checkContrast(URL(fileURLWithPath: directory, isDirectory: true)))
		}
		let output = URL(fileURLWithPath: value("--output") ?? "renders", isDirectory: true)
		let only = value("--only")

		let app = RenderApplication.shared
		app.setActivationPolicy(.accessory)
		Task { @MainActor in
			do {
				if args.contains("--readme") {
					try await ReadmeRunner.run(output: output)
				} else {
					try await RenderRunner.run(output: output, only: only)
				}
				exit(0)
			} catch {
				FileHandle.standardError.write(Data("copia-render failed: \(error)\n".utf8))
				exit(1)
			}
		}
		app.run()
	}
}

/// Reports itself active so windows and controls draw as users see them; a terminal-launched process is often refused focus.
final class RenderApplication: NSApplication {
	override var isActive: Bool { true }
}
