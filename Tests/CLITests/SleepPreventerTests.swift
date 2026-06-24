import Foundation
import Testing

@testable import CLI

@Suite("Keep-awake")
struct SleepPreventerTests {
    @Test func modeResolution() {
        #expect(SleepPreventionMode.resolve(keepAwake: false, interactive: false) == .off)
        #expect(SleepPreventionMode.resolve(keepAwake: false, interactive: true) == .off)
        #expect(SleepPreventionMode.resolve(keepAwake: true, interactive: false) == .system)
        #expect(SleepPreventionMode.resolve(keepAwake: true, interactive: true) == .systemAndDisplay)
    }

    @Test func activityOptionsPerMode() {
        #expect(SleepPreventionMode.off.activityOptions.isEmpty)
        #expect(SleepPreventionMode.system.activityOptions == [.idleSystemSleepDisabled])
        #expect(SleepPreventionMode.system.activityOptions.contains(.idleDisplaySleepDisabled) == false)
        let both = SleepPreventionMode.systemAndDisplay.activityOptions
        #expect(both.contains(.idleSystemSleepDisabled))
        #expect(both.contains(.idleDisplaySleepDisabled))
    }

    @Test func statusDescription() {
        #expect(SleepPreventionMode.off.statusDescription == nil)
        #expect(SleepPreventionMode.system.statusDescription == "system")
        #expect(SleepPreventionMode.systemAndDisplay.statusDescription == "system+display")
    }

    @Test func assertionLifecycle() {
        let preventer = SleepPreventer()
        #expect(preventer.isActive == false)
        preventer.begin(.off)
        #expect(preventer.isActive == false)  // off is a no-op
        preventer.begin(.system)
        #expect(preventer.isActive == true)
        preventer.begin(.system)  // idempotent
        #expect(preventer.isActive == true)
        preventer.end()
        #expect(preventer.isActive == false)
        preventer.end()  // idempotent
        #expect(preventer.isActive == false)
    }
}
