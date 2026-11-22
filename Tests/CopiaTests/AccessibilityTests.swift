import Testing
import AppKit
import SwiftUI
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

/// Records what the strip asked for.
@MainActor
final class ActionLog {
	var entries: [String] = []

	func actions() -> StripActions {
		StripActions(
			paste: { [unowned self] id, plain, beginClose in
				entries.append("paste \(id) plain=\(plain)")
				beginClose()
				return .pasted
			},
			copy: { [unowned self] id in entries.append("copy \(id)") },
			delete: { [unowned self] id in entries.append("delete \(id)") },
			restore: { _, _ in },
			openAccessibilitySettings: {})
	}
}

/// The strip as VoiceOver sees it: SwiftUI's accessibility tree, read in-process.
@MainActor
@Suite(.serialized) struct AccessibilityTests {
	/// Wide enough that the lazy row realizes all nine cards.
	static let allCards = PanelLayout.contentWidth(count: Fixtures.mixed.count) + 40

	@Test func eachCardIsOneElementWithItsLabelAndFourNamedActions() async throws {
		let host = StripHost(width: Self.allCards)
		defer { host.close() }
		await host.settle()
		let cards = host.cards
		#expect(cards.count == Fixtures.mixed.count)
		for clip in Fixtures.mixed {
			let label = CardAccessibility(clip: clip, now: Fixtures.now).label
			let matches = cards.filter { $0.label == label }
			#expect(matches.count == 1, "\(label)")
			#expect(Set(matches.first?.actions.map(\.name) ?? []) == ["Paste", "Paste as Plain Text", "Copy", "Delete"])
		}
		// One element per card: nothing inside a card is exposed on its own.
		for card in cards { #expect(card.children.isEmpty) }
		#expect(host.strip?.label == "Clipboard history, 9 items")
	}

	@Test func labelsReadNaturallyForEveryAge() {
		func label(_ clip: Clip) -> String { CardAccessibility(clip: clip, now: Fixtures.now).label }
		#expect(label(Fixtures.mixed[0]).hasPrefix("Text from Notes, just now: "))
		#expect(label(Fixtures.mixed[3]).hasPrefix("Image from Preview, 15m ago: "))
		#expect(label(Fixtures.mixed[7]).hasPrefix("Text from Mail, yesterday: "))
		#expect(label(Fixtures.mixed[8]).hasPrefix("Files from Finder, 2d ago: "))
	}

	@Test func aCardsNamedActionReachesTheStrip() async throws {
		let host = StripHost(width: Self.allCards)
		defer { host.close() }
		let log = ActionLog()
		host.model.actions = log.actions()
		await host.settle()
		let clip = Fixtures.mixed[5]
		let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: clip, now: Fixtures.now).label })
		let copy = try #require(card.actions.first { $0.name == "Copy" })
		if let handler = copy.handler {
			_ = handler()
		} else if let target = copy.target as? NSObject, let selector = copy.selector {
			_ = target.perform(selector, with: copy)
		}
		await host.settle()
		#expect(log.entries == ["copy \(clip.id)"])
		#expect(host.model.selectedID == clip.id)
	}
}
