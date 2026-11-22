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
		var actions = StripActions.fixtures
		actions.write = { [unowned self] id, plain in entries.append("write \(id) plain=\(plain)") }
		actions.delete = { [unowned self] ids in entries += ids.map { "delete \($0)" }; return UUID() }
		return actions
	}
}

extension WindowTests {
	/// The strip as VoiceOver sees it: SwiftUI's accessibility tree, read in-process.
	@MainActor @Suite struct AccessibilityTests {}
}

extension WindowTests.AccessibilityTests {
	/// Wide enough that the lazy row realizes all nine cards.
	static let allCards = PanelLayout.contentWidth(count: Fixtures.mixed.count) + 40

	@Test func eachCardIsOneElementWithItsLabelAndMatchingNamedActions() async throws {
		let host = StripHost(width: Self.allCards)
		defer { host.close() }
		await host.settle()
		let cards = host.cards
		#expect(cards.count == Fixtures.mixed.count)
		for clip in Fixtures.mixed {
			let label = CardAccessibility(clip: clip, now: Fixtures.now).label
			let matches = cards.filter { $0.label == label }
			#expect(matches.count == 1, "\(label)")
			#expect(Set(matches.first?.actions.map(\.name) ?? []) == ["Copy and Close", "Copy as Plain Text and Close", "Copy", "Pin", "Delete"])
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
		#expect(log.entries == ["write \(clip.id) plain=false"])
		#expect(host.model.selectedID == clip.id)
	}
}

extension WindowTests.AccessibilityTests {
	@Test func groupSelectionIsSpokenAndGearOpensSettingsFromTheTopRight() async throws {
		let host = StripHost(width: Self.allCards); defer { host.close() }
		var opens = 0; host.model.actions.openSettings = { opens += 1 }
		host.model.selectAllResults(); await host.settle()
		#expect(host.cards.count == 9 && host.cards.allSatisfy(\.isSelected))
		#expect(host.root.all.contains { $0.value == "9 selected" || $0.label == "9 selected" })
		let gear = try #require(host.root.all.first { $0.role == "AXButton" && $0.label == "Settings" })
		#expect(gear.frame.maxX > host.window.frame.maxX - 40 && gear.frame.midY > host.window.frame.maxY - Theme.topBarHeight)
		let press = NSSelectorFromString("accessibilityPerformPress")
		try #require(gear.object.responds(to: press))
		_ = gear.object.perform(press); await host.settle()
		#expect(opens == 1)
		host.model.move(1); await host.settle()
		#expect(host.cards.filter(\.isSelected).count == 1)
	}
}
