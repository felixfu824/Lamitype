import Foundation

enum EvalExport {
    enum ExportError: LocalizedError {
        case sameOutputURL

        var errorDescription: String? {
            switch self {
            case .sameOutputURL:
                return L10n.string(
                    "eval.error.same_export_path",
                    fallback: "The cases and results files cannot use the same path."
                )
            }
        }
    }

    struct CaseRecord: Codable, Equatable {
        let id: String
        let category: String
        let input: String
        let expect: String
        let expectedOutput: String?
        let rationale: String

        enum CodingKeys: String, CodingKey {
            case id, category, input, expect, rationale
            case expectedOutput = "expected_output"
        }
    }

    struct ResultRecord: Codable, Equatable {
        let id: String
        let output: String
        let outcome: EvalOutcome
        let reason: String?
        let elapsedMS: Int?
        let label: EvalLabel?
        let reruns: [EvalRerun]

        enum CodingKeys: String, CodingKey {
            case id, output, outcome, reason, label, reruns
            case elapsedMS = "elapsed_ms"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
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
            if let label {
                try container.encode(label, forKey: .label)
            } else {
                try container.encodeNil(forKey: .label)
            }
            try container.encode(reruns, forKey: .reruns)
        }
    }

    struct ResultsFile: Codable, Equatable {
        let schema: String
        let exportedAt: Date
        let appVersion: String
        let results: [ResultRecord]

        enum CodingKeys: String, CodingKey {
            case schema, results
            case exportedAt = "exported_at"
            case appVersion = "app_version"
        }
    }

    struct Files {
        let cases: Data
        let results: Data
    }

    static func makeFiles(
        entries: [EvalEntry],
        exportedAt: Date = Date(),
        appVersion: String
    ) throws -> Files {
        var seen = Set<String>()
        let unique = entries.filter { seen.insert($0.id).inserted }
        let cases = unique.map(makeCase)
        let results = ResultsFile(
            schema: "lamitype-eval-results/1",
            exportedAt: exportedAt,
            appVersion: appVersion,
            results: unique.map {
                ResultRecord(
                    id: $0.id,
                    output: $0.output,
                    outcome: $0.outcome,
                    reason: $0.reason,
                    elapsedMS: $0.elapsedMS,
                    label: $0.label,
                    reruns: $0.reruns
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return Files(cases: try encoder.encode(cases), results: try encoder.encode(results))
    }

    static func resultsURL(for casesURL: URL) -> URL {
        let stem = casesURL.deletingPathExtension().lastPathComponent
        return casesURL.deletingLastPathComponent()
            .appendingPathComponent(stem + "-results")
            .appendingPathExtension("json")
    }

    @discardableResult
    static func writeFiles(_ files: Files, casesURL: URL) throws -> URL {
        let resultsURL = resultsURL(for: casesURL)
        try writeFiles(files, casesURL: casesURL, resultsURL: resultsURL)
        return resultsURL
    }

    static func writeFiles(_ files: Files, casesURL: URL, resultsURL: URL) throws {
        guard casesURL.standardizedFileURL != resultsURL.standardizedFileURL else {
            throw ExportError.sameOutputURL
        }
        try files.cases.write(to: casesURL, options: .atomic)
        try files.results.write(to: resultsURL, options: .atomic)
    }

    private static func makeCase(_ entry: EvalEntry) -> CaseRecord {
        switch entry.label {
        case .correct where entry.outcome == .polished:
            return CaseRecord(
                id: entry.id,
                category: entry.source.rawValue,
                input: entry.original,
                expect: "must_change",
                expectedOutput: entry.output,
                rationale: "labelled correct"
            )
        case .correct:
            return CaseRecord(
                id: entry.id,
                category: entry.source.rawValue,
                input: entry.original,
                expect: "must_keep_verbatim",
                expectedOutput: nil,
                rationale: "labelled correct"
            )
        case .overEdited:
            return CaseRecord(
                id: entry.id,
                category: entry.source.rawValue,
                input: entry.original,
                expect: "must_keep_verbatim",
                expectedOutput: nil,
                rationale: "labelled over-edited; output was \(entry.output)"
            )
        case .wrongOrMissed:
            return CaseRecord(
                id: entry.id,
                category: entry.source.rawValue,
                input: entry.original,
                expect: "judge",
                expectedOutput: nil,
                rationale: "labelled wrong or missed; output was \(entry.output)"
            )
        case nil:
            return CaseRecord(
                id: entry.id,
                category: entry.source.rawValue,
                input: entry.original,
                expect: "judge",
                expectedOutput: nil,
                rationale: "unlabelled"
            )
        }
    }
}
