import ArgumentParser

/// How `--speakers` assigns labels (PRD §6.7).
enum SpeakerMode: String, CaseIterable, ExpressibleByArgument {
    /// Source attribution for the mic side + acoustic diarization elsewhere.
    case auto
    /// Label strictly by capture source (mic = "You", system = "Others").
    case source
    /// Acoustic diarization only ("Speaker 1/2…").
    case acoustic
}

/// Which acoustic diarizer to use. Batch `-i` uses the offline pipeline;
/// live streaming diarization is planned (PLAN Phase 8.4).
enum DiarizeEngine: String, CaseIterable, ExpressibleByArgument {
    case auto
    case streaming
    case offline
}

/// The two source-attribution labels (mic vs system). Defaults to You/Others;
/// overridden by `--speaker-labels "You,Others"` (validated as a pair).
struct SpeakerLabels {
    let you: String
    let others: String

    static let `default` = SpeakerLabels(you: "You", others: "Others")

    static func parse(_ raw: String?) -> SpeakerLabels {
        guard let raw else { return .default }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return .default }
        return SpeakerLabels(you: parts[0], others: parts[1])
    }
}

/// Whether acoustic diarization runs in real time or as an end-of-capture pass.
enum DiarizeMode { case streaming, offline }

/// The resolved live speaker-labeling plan for a capture invocation (PRD §6.7).
enum LivePlan {
    /// No labeling.
    case none
    /// Deterministic source attribution only (mic = `you`, system = `others`).
    case sourceOnly(SpeakerLabels)
    /// Source attribution + acoustic diarization of the system side
    /// (`you` + `Speaker 1..N`).
    case sourceDiarized(SpeakerLabels, DiarizeMode)
    /// Acoustic diarization of a single capture stream (`Speaker 1..N`).
    case singleDiarized(DiarizeMode)
}
