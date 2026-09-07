import Foundation

enum EvalSource: String, Codable, CaseIterable, Sendable {
    case dictation
    case dictationLocalOnce = "dictation_local_once"
    case polishHotkey = "polish_hotkey"
    case polishService = "polish_service"

    var rerunBudget: TextPolisher.RerunBudget {
        switch self {
        case .dictation, .dictationLocalOnce: return .dictation
        case .polishHotkey, .polishService: return .polish
        }
    }
}

enum EvalOutcome: String, Codable, CaseIterable, Sendable {
    case polished
    case unchanged
    case keptOriginal = "kept_original"
    case notPolished = "not_polished"
}

enum EvalLabel: String, Codable, CaseIterable, Sendable {
    case correct
    case overEdited = "over_edited"
    case wrongOrMissed = "wrong_or_missed"
}

struct EvalRerun: Codable, Equatable, Sendable {
    let at: Date
    let instructions: String?
    let output: String
    let outcome: EvalOutcome
    let reason: String?
    let elapsedMS: Int

    enum CodingKeys: String, CodingKey {
        case at, instructions, output, outcome, reason
        case elapsedMS = "elapsed_ms"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(at, forKey: .at)
        if let instructions {
            try container.encode(instructions, forKey: .instructions)
        } else {
            try container.encodeNil(forKey: .instructions)
        }
        try container.encode(output, forKey: .output)
        try container.encode(outcome, forKey: .outcome)
        if let reason {
            try container.encode(reason, forKey: .reason)
        } else {
            try container.encodeNil(forKey: .reason)
        }
        try container.encode(elapsedMS, forKey: .elapsedMS)
    }
}

struct EvalEntry: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    static let maximumReruns = 10

    let schema: Int
    let id: String
    let capturedAt: Date
    let source: EvalSource
    let appBundleID: String
    let original: String
    var output: String
    var outcome: EvalOutcome
    var reason: String?
    var elapsedMS: Int?
    var abandoned: Bool
    var label: EvalLabel?
    var reruns: [EvalRerun]

    init(
        schema: Int = schemaVersion,
        id: String = EvalEntry.makeID(),
        capturedAt: Date = Date(),
        source: EvalSource,
        appBundleID: String,
        original: String,
        output: String,
        outcome: EvalOutcome,
        reason: String?,
        elapsedMS: Int?,
        abandoned: Bool,
        label: EvalLabel? = nil,
        reruns: [EvalRerun] = []
    ) {
        self.schema = schema
        self.id = id
        self.capturedAt = capturedAt
        self.source = source
        self.appBundleID = appBundleID
        self.original = original
        self.output = output
        self.outcome = outcome
        self.reason = reason
        self.elapsedMS = elapsedMS
        self.abandoned = abandoned
        self.label = label
        self.reruns = Array(reruns.suffix(Self.maximumReruns))
    }

    mutating func appendRerun(_ rerun: EvalRerun) {
        reruns.append(rerun)
        if reruns.count > Self.maximumReruns {
            reruns.removeFirst(reruns.count - Self.maximumReruns)
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema, id, source, original, output, outcome, reason, abandoned, label, reruns
        case capturedAt = "captured_at"
        case appBundleID = "app_bundle_id"
        case elapsedMS = "elapsed_ms"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(id, forKey: .id)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(source, forKey: .source)
        try container.encode(appBundleID, forKey: .appBundleID)
        try container.encode(original, forKey: .original)
        try container.encode(output, forKey: .output)
        try container.encode(outcome, forKey: .outcome)
        if let reason {
            try container.encode(reason, forKey: .reason)
        } else {
            try container.encodeNil(forKey: .reason)
        }
        if let elapsedMS {
            try container.encode(elapsedMS, forKey: .elapsedMS)
        } else {
            try container.encodeNil(forKey: .elapsedMS)
        }
        try container.encode(abandoned, forKey: .abandoned)
        if let label {
            try container.encode(label, forKey: .label)
        } else {
            try container.encodeNil(forKey: .label)
        }
        try container.encode(reruns, forKey: .reruns)
    }

    private static func makeID(now: Date = Date(), uuid: UUID = UUID()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let prefix = formatter.string(from: now)
        let suffix = uuid.uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(8).lowercased()
        return "\(prefix)-\(suffix)"
    }
}
