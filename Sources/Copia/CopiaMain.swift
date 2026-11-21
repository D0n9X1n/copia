import AppKit
import CopiaApp

@main
enum Main {
	@MainActor static func main() {
		let app = NSApplication.shared
		app.setActivationPolicy(.accessory)
		let controller: AppController
		do {
			controller = try AppController()
		} catch {
			let alert = NSAlert()
			alert.messageText = "Copia couldn't open its history"
			alert.informativeText = error.localizedDescription
			alert.runModal()
			exit(1)
		}
		Task { await controller.start() }
		withExtendedLifetime(controller) { app.run() }
	}
}
