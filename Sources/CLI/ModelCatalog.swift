import Foundation

/// A model that can be downloaded, tagged by engine. `name` is the user-facing
/// download identifier (`base.en`, `whisperkit:tiny`, `parakeet:v3`); `modelId`
/// is the engine-specific id passed to that engine (ggml short name, WhisperKit
/// variant, or Parakeet version).
struct DownloadableModel: Codable, Equatable {
    let engine: String
    let name: String
    let modelId: String

    /// English-only vs multilingual, for display.
    var isEnglishOnly: Bool {
        switch engine {
        case "parakeet": return modelId.lowercased() == "v2"
        default: return modelId.lowercased().contains(".en")
        }
    }
}

/// Maps download names to engines and lists what each engine can fetch.
/// Engine-tagged names (`whisperkit:`/`parakeet:` prefixes) disambiguate the
/// CoreML engines; a bare name is a whisper ggml model (backward compatible).
enum ModelCatalog {
    /// Parses a download name into engine + engine-specific id.
    /// `parakeet:v3` / `parakeet-v3` → parakeet/v3; `whisperkit:tiny` →
    /// whisperkit/tiny; otherwise → whisper/<name>.
    static func parse(_ name: String) -> DownloadableModel {
        if let id = tagged(name, engine: "parakeet") {
            // Normalize bare versions: `parakeet:v3`, `parakeet` → v3.
            let version = id.isEmpty ? "v3" : id
            return DownloadableModel(engine: "parakeet", name: name, modelId: version)
        }
        if let id = tagged(name, engine: "whisperkit") {
            return DownloadableModel(engine: "whisperkit", name: name, modelId: id)
        }
        return DownloadableModel(engine: "whisper", name: name, modelId: name)
    }

    /// Returns the id after an `<engine>:` or `<engine>-` prefix, or nil.
    private static func tagged(_ name: String, engine: String) -> String? {
        for separator in [":", "-"] {
            let prefix = engine + separator
            if name.lowercased().hasPrefix(prefix) {
                return String(name.dropFirst(prefix.count))
            }
        }
        return name.lowercased() == engine ? "" : nil
    }

    /// The full downloadable catalog across engines, for `models list --available`.
    static func available() -> [DownloadableModel] {
        let whisper = ModelRegistry.downloadable.map {
            DownloadableModel(engine: "whisper", name: $0, modelId: $0)
        }
        let whisperkit = WhisperKitBackend.downloadableVariants.map {
            DownloadableModel(engine: "whisperkit", name: "whisperkit:\($0)", modelId: $0)
        }
        let parakeet = ParakeetBackend.downloadableVersions.map {
            DownloadableModel(engine: "parakeet", name: "parakeet:\($0)", modelId: $0)
        }
        return whisper + whisperkit + parakeet
    }
}
