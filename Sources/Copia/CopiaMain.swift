import AppKit
import CopiaApp

@main
enum Main {
	@MainActor static func main() {
		let app = NSApplication.shared
		app.setActivationPolicy(.accessory)
		let args = CommandLine.arguments
		func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
		let selftest = value("--selftest")
		let controller: AppController
		do {
			if selftest != nil {
				// The self-test never reads the user's history or clipboard: a temporary store, capture paused, a private defaults suite.
				let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-selftest-\(UUID().uuidString)")
				let defaults = UserDefaults(suiteName: "copia-selftest")!
				defaults.set(true, forKey: "paused")
				defaults.set(true, forKey: "onboarded")
				controller = try AppController(directory: dir, defaults: defaults)
			} else {
				controller = try AppController()
			}
		} catch {
			let alert = NSAlert()
			alert.messageText = "Copia couldn't open its history"
			alert.informativeText = error.localizedDescription
			alert.runModal()
			exit(1)
		}
		if let output = selftest {
			Task {
				await controller.start(showOnboarding: false, menuAndHotkeys: false)
				let code = await SelfTest.run(controller: controller, output: URL(fileURLWithPath: output),
					hold: Double(value("--hold") ?? "0") ?? 0)
				exit(code)
			}
		} else {
			Task { await controller.start() }
		}
		withExtendedLifetime(controller) { app.run() }
	}
}
