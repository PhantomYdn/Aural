import ArgumentParser
import Foundation
import Testing

@testable import CLI

@Suite("Record argument parsing")
struct RecordParsingTests {
    @Test func defaults() throws {
        let record = try Record.parse(["-o", "out.wav"])
        #expect(record.rate == 44100)
        #expect(record.bits == 16)
        #expect(record.channels == nil)
        #expect(record.duration == nil)
        #expect(record.device == nil)
        #expect(!record.wavToStdout)
        #expect(!record.noOutput)
    }

    @Test func parsesAllOptions() throws {
        let record = try Record.parse([
            "-d", "SomeUID", "-o", "x.wav", "-r", "48000", "-b", "24", "-c", "2", "-t", "30.5",
        ])
        #expect(record.device == "SomeUID")
        #expect(record.output == "x.wav")
        #expect(record.rate == 48000)
        #expect(record.bits == 24)
        #expect(record.channels == 2)
        #expect(record.duration == 30.5)
    }

    @Test(arguments: [
        ["-o", "x.wav", "-b", "12"],          // bad bit depth
        ["-o", "x.wav", "-c", "3"],           // bad channel count
        ["-o", "x.wav", "-t", "0"],           // non-positive duration
        ["-o", "x.wav", "-r", "0"],           // bad rate
        ["-o", "x.wav", "--stdout"],          // -o conflicts with --stdout
        ["-o", "x.wav", "--no-output"],       // -o conflicts with --no-output
        ["--stdout", "--no-output"],          // stream conflicts with dry run
    ])
    func rejectsInvalidCombinations(_ arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try Record.parse(arguments)
        }
    }
}

@Suite("Devices argument parsing")
struct DevicesParsingTests {
    @Test func defaultsToAllDevices() throws {
        let devices = try Devices.parse([])
        #expect(!devices.listInputs)
        #expect(!devices.listOutputs)
        #expect(!devices.json)
    }

    @Test func rejectsInputsAndOutputsTogether() {
        #expect(throws: (any Error).self) {
            _ = try Devices.parse(["--list-inputs", "--list-outputs"])
        }
    }
}

@Suite("Exit codes")
struct ExitCodeTests {
    @Test func sysexitsValues() {
        #expect(AuralExitCode.ok.rawValue == 0)
        #expect(AuralExitCode.usage.rawValue == 64)
        #expect(AuralExitCode.noInput.rawValue == 66)
        #expect(AuralExitCode.unavailable.rawValue == 69)
        #expect(AuralExitCode.software.rawValue == 70)
        #expect(AuralExitCode.ioError.rawValue == 74)
        #expect(AuralExitCode.noPermission.rawValue == 77)
    }

    @Test func errorFactoriesCarryCodes() {
        #expect(AuralError.noInput("x").code == .noInput)
        #expect(AuralError.unavailable("x").code == .unavailable)
        #expect(AuralError.ioError("x").code == .ioError)
        #expect(AuralError.noPermission("x").code == .noPermission)
    }
}

@Suite("Byte budget")
struct ByteBudgetTests {
    @Test func trimsFinalChunkToExactBudget() {
        let budget = ByteBudget(bytes: 10, frameSize: 2)
        let first = budget.consume(Data(count: 6))
        #expect(first.chunk.count == 6)
        #expect(!first.exhausted)
        let second = budget.consume(Data(count: 6))
        #expect(second.chunk.count == 4)
        #expect(second.exhausted)
        let third = budget.consume(Data(count: 6))
        #expect(third.chunk.isEmpty)
        #expect(third.exhausted)
    }

    @Test func roundsBudgetDownToFrameBoundary() {
        let budget = ByteBudget(bytes: 7, frameSize: 4)
        let result = budget.consume(Data(count: 8))
        #expect(result.chunk.count == 4)  // 7 rounded down to one 4-byte frame
        #expect(result.exhausted)
    }
}
