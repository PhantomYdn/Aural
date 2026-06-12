import AppKit
import CoreAudio
import Darwin
import Foundation

/// A running process registered with the audio HAL, capturable via a
/// Core Audio process tap (macOS 14.4+).
public struct CapturableApp: Codable, Equatable, Sendable {
    /// Display name (app name when available, process name otherwise).
    public let name: String
    /// Bundle identifier; may be empty for non-bundled processes.
    public let bundleID: String
    /// Unix process identifier.
    public let pid: Int32
    /// True if the process is currently producing or consuming audio.
    public let audioActive: Bool

    /// Transient HAL identifier of the process object; excluded from JSON.
    public let objectID: UInt32

    enum CodingKeys: String, CodingKey {
        case name, bundleID, pid, audioActive
    }

    public init(name: String, bundleID: String, pid: Int32, audioActive: Bool, objectID: UInt32) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
        self.audioActive = audioActive
        self.objectID = objectID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        pid = try container.decode(Int32.self, forKey: .pid)
        audioActive = try container.decode(Bool.self, forKey: .audioActive)
        objectID = 0
    }
}

extension DeviceManager {
    /// Lists processes registered with the audio HAL (tap targets).
    public static func listCapturableApps() throws -> [CapturableApp] {
        let processIDs = try AudioObjectProperty.readArray(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList,
            of: AudioObjectID.self,
            operation: "listing audio process objects"
        )

        var apps: [CapturableApp] = []
        for objectID in processIDs {
            guard
                let pid = try? AudioObjectProperty.read(
                    objectID, kAudioProcessPropertyPID, as: pid_t.self,
                    operation: "reading process PID")
            else { continue }

            let bundleID =
                (try? AudioObjectProperty.readString(
                    objectID, kAudioProcessPropertyBundleID,
                    operation: "reading process bundle ID")) ?? ""

            let isRunning =
                (try? AudioObjectProperty.read(
                    objectID, kAudioProcessPropertyIsRunning, as: UInt32.self,
                    operation: "reading process is-running")) ?? 0

            apps.append(
                CapturableApp(
                    name: displayName(pid: pid, bundleID: bundleID),
                    bundleID: bundleID,
                    pid: pid,
                    audioActive: isRunning != 0,
                    objectID: objectID
                ))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Best-effort display name: running app name, then proc name, then PID.
    private static func displayName(pid: pid_t, bundleID: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
            let name = app.localizedName, !name.isEmpty {
            return name
        }
        var buffer = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        if proc_name(numericCast(pid), &buffer, numericCast(buffer.count)) > 0 {
            let name = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            if !name.isEmpty { return name }
        }
        if !bundleID.isEmpty { return bundleID }
        return "pid \(pid)"
    }
}
