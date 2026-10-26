/// The heading and icon above the menu's job list, chosen from what the jobs
/// are doing: still working, waiting on the user, all finished, or none of those
/// (a failed job among finished ones). Pure, like `BadgeKind.compute`, so the
/// precedence lives in one place and not in two parallel `if` chains.
struct QueueHeader: Equatable {
    let title: String
    let systemImage: String

    static let processing = Self(title: "Processing", systemImage: "gearshape.2.fill")
    static let needsAttention = Self(title: "Needs Attention", systemImage: "person.2.fill")
    static let completed = Self(title: "Completed", systemImage: "checkmark.circle")
    static let queue = Self(title: "Queue", systemImage: "tray.full.fill")
    static let all = [processing, needsAttention, completed, queue]

    /// Work in flight wins over a job waiting for names, which wins over
    /// "Completed", so a list is only called completed when every job is done.
    static func compute(jobStates: [JobState], isProcessing: Bool) -> Self {
        let working: [JobState] = [.waiting, .transcribing, .diarizing, .generatingProtocol]
        if isProcessing || jobStates.contains(where: working.contains) {
            return .processing
        }
        if jobStates.contains(.speakerNamingPending) {
            return .needsAttention
        }
        if !jobStates.isEmpty, jobStates.allSatisfy({ $0 == .done }) {
            return .completed
        }
        return .queue
    }
}
