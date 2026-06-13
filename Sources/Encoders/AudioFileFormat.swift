import Foundation

/// Output container/codec formats Aural knows about.
public enum AudioFileFormat: String, CaseIterable, Sendable {
    case wav
    case m4a
    case flac
    case mp3
    case opus

    /// Formats that can currently be written. MP3 (LAME) and Ogg/Opus
    /// (Ogg muxer) are planned — see PLAN.md Phase 3 deferred items.
    public var isWritable: Bool {
        switch self {
        case .wav, .m4a, .flac: return true
        case .mp3, .opus: return false
        }
    }

    /// Detects the format from a file path's extension.
    public static func detect(fromPath path: String) -> AudioFileFormat? {
        AudioFileFormat(rawValue: (path as NSString).pathExtension.lowercased())
    }
}
