import Testing

@testable import DeviceManager

// Enumeration tests are tolerant of machines without audio hardware
// (e.g., CI runners): they assert invariants, not specific devices.

@Suite("Device enumeration")
struct DeviceEnumerationTests {
    @Test func listAllDoesNotThrow() throws {
        let devices = try DeviceManager.listDevices(scope: .all)
        for device in devices {
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
            #expect(device.inputChannels >= 0)
            #expect(device.outputChannels >= 0)
        }
    }

    @Test func inputScopeOnlyReturnsInputs() throws {
        let inputs = try DeviceManager.listDevices(scope: .input)
        for device in inputs {
            #expect(device.inputChannels > 0)
        }
    }

    @Test func outputScopeOnlyReturnsOutputs() throws {
        let outputs = try DeviceManager.listDevices(scope: .output)
        for device in outputs {
            #expect(device.outputChannels > 0)
        }
    }

    @Test func scopesPartitionAllDevices() throws {
        let all = try DeviceManager.listDevices(scope: .all)
        let inputs = try DeviceManager.listDevices(scope: .input)
        let outputs = try DeviceManager.listDevices(scope: .output)
        #expect(inputs.count <= all.count)
        #expect(outputs.count <= all.count)
    }

    @Test func unknownUIDResolvesToNil() throws {
        let id = try DeviceManager.deviceID(forUID: "aural-test-no-such-uid")
        #expect(id == nil)
    }
}

@Suite("App enumeration")
struct AppEnumerationTests {
    @Test func listAppsDoesNotThrow() throws {
        let apps = try DeviceManager.listCapturableApps()
        for app in apps {
            #expect(!app.name.isEmpty)
            #expect(app.pid > 0)
        }
    }

    @Test func appsAreSortedByName() throws {
        let apps = try DeviceManager.listCapturableApps()
        let names = apps.map(\.name)
        let sorted = names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        #expect(names == sorted)
    }
}
