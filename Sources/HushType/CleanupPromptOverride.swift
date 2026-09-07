import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "cleanup-prompt-override")

enum CleanupPromptOverride {
    private struct CacheEntry {
        var mtime: Date?
        var result: String?
        var fileExists: Bool
    }

    /// Alternating between cleanup and polish must retain independent stat-only
    /// fast paths and never reuse one feature's parsed prompt for the other.
    private static var cacheByFilename: [String: CacheEntry] = [:]

    /// Returns the override prompt (with full-line `#` comments stripped and
    /// globally trimmed) if the file exists and is non-empty after stripping.
    /// Returns nil otherwise, so callers fall back to the baked-in prompt.
    ///
    /// Internally cached by mtime. First call (or after mtime change or
    /// appearance/disappearance) re-reads and re-parses; subsequent calls with
    /// unchanged mtime are stat-only.
    ///
    /// Concurrency: not thread-safe by design. Current callers reach this via
    /// the cleanup and polish FoundationModels wrappers on the main actor. If
    /// a non-main-actor caller is ever added, this cache state needs explicit
    /// synchronization.
    static func currentPrompt(filename: String) -> String? {
        let fileURL = AppConfig.promptOverrideURL(filename: filename)
        var cache = cacheByFilename[filename]
            ?? CacheEntry(mtime: nil, result: nil, fileExists: false)
        let previousResult = cache.result
        let previousFileExists = cache.fileExists

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch {
            if previousFileExists {
                cache = CacheEntry(mtime: nil, result: nil, fileExists: false)
                cacheByFilename[filename] = cache
                log.debug("Override file disappeared: \(filename, privacy: .public)")
            }
            return nil
        }

        let mtime = attributes[.modificationDate] as? Date
        if let mtime, previousFileExists, cache.mtime == mtime {
            return cache.result
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            cacheByFilename[filename] = CacheEntry(mtime: nil, result: nil, fileExists: false)
            log.warning("Failed to read override file at \(fileURL.path, privacy: .public)")
            return nil
        }

        guard let contents = String(data: data, encoding: .utf8) else {
            cacheByFilename[filename] = CacheEntry(mtime: nil, result: nil, fileExists: false)
            log.warning("Override file is not valid UTF-8: \(fileURL.path, privacy: .public)")
            return nil
        }

        let parsed = parse(contents: contents)
        cacheByFilename[filename] = CacheEntry(mtime: mtime, result: parsed, fileExists: true)

        if !previousFileExists {
            log.debug("Override file appeared: \(filename, privacy: .public)")
        } else if parsed != previousResult {
            log.debug("Override file changed: \(filename, privacy: .public)")
        }

        return parsed
    }

    static func parse(contents: String) -> String? {
        let kept = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmedForCheck = line.drop { $0 == " " || $0 == "\t" }
                return !trimmedForCheck.hasPrefix("#")
            }

        let joined = kept
            .map(String.init)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return joined.isEmpty ? nil : joined
    }

    /// Full prompts are opaque text. Markdown headings are instructions too,
    /// so only whitespace-only documents are rejected.
    static func parseFullPrompt(contents: String) -> String? {
        contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : contents
    }

    static func invalidate(filename: String) {
        cacheByFilename.removeValue(forKey: filename)
    }

    #if DEBUG
    static func resetForTesting() {
        cacheByFilename.removeAll()
    }
    #endif
}
