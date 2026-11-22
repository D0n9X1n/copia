import AppKit
import CopiaApp

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
	let controller: AppController
	init(_ controller: AppController) { self.controller = controller }
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		controller.openSettings()
		return false
	}
}

@main
enum Main {
	@MainActor static func main() {
		let app = NSApplication.shared
		app.setActivationPolicy(.accessory)
		let args = CommandLine.arguments
		func value(_ flag: String) -> String? {
			guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1), !args[i + 1].hasPrefix("--") else { return nil }
			return args[i + 1]
		}
		if args.contains("--selftest") {
			guard let path = value("--selftest") else { exit(64) }
			Task {
				let suite = "copia-selftest-\(UUID())", board = NSPasteboard.withUniqueName()
				let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
				let defaults = UserDefaults(suiteName: suite)!
				let result: Int32
				do {
					let controller = try AppController.scratch(directory: dir, defaults: defaults, pasteboard: board)
					await controller.start(showOnboarding: false, menuAndHotkeys: false)
					result = await SelfTest.run(controller: controller, output: URL(fileURLWithPath: path), hold: Double(value("--hold") ?? "0") ?? 0)
				} catch {
					FileHandle.standardError.write(Data("Self-test failed: \(error)\n".utf8))
					result = 1
				}
				board.releaseGlobally()
				defaults.removePersistentDomain(forName: suite)
				try? FileManager.default.removeItem(at: dir)
				exit(result)
			}
			app.run()
			return
		}
		do {
			let controller = try AppController.live()
			let delegate = AppDelegate(controller)
			app.delegate = delegate
			Task { await controller.start() }
			withExtendedLifetime(delegate) { app.run() }
		} catch {
			let alert = NSAlert()
			alert.messageText = "Copia couldn't open its history"
			alert.informativeText = error.localizedDescription
			alert.runModal()
			exit(1)
		}
	}
}
