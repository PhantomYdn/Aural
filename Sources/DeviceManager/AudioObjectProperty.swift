import CoreAudio
import Foundation

/// Errors raised while talking to the CoreAudio HAL.
public enum DeviceManagerError: Error, CustomStringConvertible {
    case osStatus(OSStatus, operation: String)

    public var description: String {
        switch self {
        case let .osStatus(status, operation):
            return "CoreAudio error \(status) during \(operation)"
        }
    }
}

/// Minimal typed helpers over `AudioObjectGetPropertyData`.
enum AudioObjectProperty {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Reads a fixed-size scalar property (e.g., UInt32, pid_t, CFString ref).
    static func read<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as type: T.Type,
        operation: String
    ) throws -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, value)
        guard status == noErr else {
            throw DeviceManagerError.osStatus(status, operation: operation)
        }
        return value.pointee
    }

    /// Reads a variable-length array property.
    static func readArray<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of type: T.Type,
        operation: String
    ) throws -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
        guard status == noErr else {
            throw DeviceManagerError.osStatus(status, operation: "\(operation) (size)")
        }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](unsafeUninitializedCapacity: count) { _, initialized in
            initialized = count
        }
        status = values.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else {
            throw DeviceManagerError.osStatus(status, operation: operation)
        }
        return values
    }

    /// Reads a CFString property as a Swift String.
    static func readString(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> String {
        let cfString: CFString = try read(
            objectID, selector, as: CFString.self, operation: operation)
        return cfString as String
    }

    /// Returns whether the object exposes the given property.
    static func has(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var addr = address(selector, scope: scope)
        return AudioObjectHasProperty(objectID, &addr)
    }
}
