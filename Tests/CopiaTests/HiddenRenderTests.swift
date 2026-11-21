import Testing
@testable import CopiaBench

@Suite struct HiddenRenderTests {
	static let quiet = HiddenRender.Counters(bodies: 0, layerDisplays: 0, displayLinkTicks: 0)
	static let rose = HiddenRender.Counters(bodies: 3, layerDisplays: 1, displayLinkTicks: 0)

	@Test func aQuietHiddenStripWithAWorkingControlPasses() {
		let result = HiddenRender.evaluate(idle: Self.quiet, windowsOnScreen: 0, control: Self.rose)
		#expect(result.failures.isEmpty)
		#expect(result.passes)
	}

	@Test func anyIdleRenderingFails() {
		for idle in [HiddenRender.Counters(bodies: 1, layerDisplays: 0, displayLinkTicks: 0),
			HiddenRender.Counters(bodies: 0, layerDisplays: 2, displayLinkTicks: 0),
			HiddenRender.Counters(bodies: 0, layerDisplays: 0, displayLinkTicks: 1)] {
			#expect(!HiddenRender.evaluate(idle: idle, windowsOnScreen: 0, control: Self.rose).passes)
		}
	}

	@Test func aCopiaWindowOnScreenFails() {
		let result = HiddenRender.evaluate(idle: Self.quiet, windowsOnScreen: 1, control: Self.rose)
		#expect(result.failures == ["hiddenWindowsOnScreen"])
	}

	@Test func aControlThatDoesNotRiseFailsTheBench() {
		let noBodies = HiddenRender.Counters(bodies: 0, layerDisplays: 1, displayLinkTicks: 0)
		let noLayers = HiddenRender.Counters(bodies: 2, layerDisplays: 0, displayLinkTicks: 0)
		#expect(HiddenRender.evaluate(idle: Self.quiet, windowsOnScreen: 0, control: noBodies).failures == ["hiddenControlRises"])
		#expect(HiddenRender.evaluate(idle: Self.quiet, windowsOnScreen: 0, control: noLayers).failures == ["hiddenControlRises"])
		#expect(!HiddenRender.evaluate(idle: Self.quiet, windowsOnScreen: 0, control: Self.quiet).passes)
	}
}
