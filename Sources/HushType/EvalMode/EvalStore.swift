import Foundation
import os

private let evalStoreLog = Logger(subsystem: "com.felix.hushtype", category: "eval-store")

@MainActor
final class EvalStore {
    static let maximumEntries = 500
    static let shared = EvalStore(directory: AppSupportPaths.evalDirectoryURL)

    private let directory: URL
    private let entriesDirectory: URL
    private let ioQueue = DispatchQueue(label: "com.felix.hushtype.eval-store")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var lifecycleGeneration: UInt64 = 0
    private(set) var acceptsWrites = true

    private(set) var entries: [EvalEntry] = []
    private(set) var bytesOnDisk: Int64 = 0
    private var diskBytesByID: [String: Int64] = [:]
    var count: Int { entries.count }
    var isFull: Bool { count >= Self.maximumEntries }

    init(directory: URL) {
        self.directory = directory
        entriesDirectory = directory.appendingPathComponent("entries", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        acceptsWrites = prepareDirectories()
    }

    @discardableResult
    func append(_ entry: EvalEntry) -> Bool {
        guard validateBoundaryOrFailClosed(), !isFull else { return false }
        let normalized = normalizedEntry(entry)
        guard let data = try? encoder.encode(normalized) else {
            evalStoreLog.error("Could not encode Eval Mode entry")
            return false
        }
        entries.append(normalized)
        entries.sort { $0.capturedAt > $1.capturedAt }
        let encodedBytes = Int64(data.count)
        diskBytesByID[normalized.id] = encodedBytes
        bytesOnDisk += encodedBytes
        notifyChange()
        write(data, id: normalized.id)
        return true
    }

    func reload() async {
        guard validateBoundaryOrFailClosed() else {
            clearMemoryAndNotify()
            return
        }
        let generation = lifecycleGeneration
        let directory = directory
        let entriesDirectory = entriesDirectory
        let decoder = decoder
        let loaded: (entries: [(EvalEntry, Int64)], corrupt: Int, safe: Bool) =
            await withCheckedContinuation { continuation in
            ioQueue.async {
                guard Self.hasSafeManagedBoundary(
                    directory: directory,
                    entriesDirectory: entriesDirectory
                ) else {
                    continuation.resume(returning: ([], 0, false))
                    return
                }
                var decoded: [(EvalEntry, Int64)] = []
                var corrupt = 0
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: entriesDirectory,
                    includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for url in urls where url.pathExtension == "json" {
                    do {
                        let data = try Data(contentsOf: url)
                        var entry = try decoder.decode(EvalEntry.self, from: data)
                        entry = Self.normalizedEntryStatic(entry)
                        let allocated = try url.resourceValues(
                            forKeys: [.totalFileAllocatedSizeKey]
                        ).totalFileAllocatedSize
                        decoded.append((entry, Int64(allocated ?? data.count)))
                    } catch {
                        corrupt += 1
                    }
                }
                continuation.resume(returning: (decoded, corrupt, true))
            }
        }
        guard loaded.2 else {
            failClosedForUnsafeBoundary()
            return
        }
        guard acceptsWrites, generation == lifecycleGeneration else {
            return
        }
        entries = loaded.0.map(\.0).sorted { $0.capturedAt > $1.capturedAt }
        diskBytesByID = Dictionary(
            loaded.0.map { ($0.0.id, $0.1) },
            uniquingKeysWith: { _, newest in newest }
        )
        bytesOnDisk = diskBytesByID.values.reduce(0, +)
        if loaded.1 > 0 {
            evalStoreLog.notice("Skipped \(loaded.1, privacy: .public) corrupt Eval Mode files")
        }
        notifyChange()
    }

    @discardableResult
    func update(_ entry: EvalEntry) -> Bool {
        guard validateBoundaryOrFailClosed(),
              let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        let normalized = normalizedEntry(entry)
        guard let data = try? encoder.encode(normalized) else { return false }
        let previousSize = diskBytesByID[normalized.id] ?? encodedSize(entries[index])
        let encodedBytes = Int64(data.count)
        entries[index] = normalized
        diskBytesByID[normalized.id] = encodedBytes
        bytesOnDisk = max(0, bytesOnDisk - previousSize + encodedBytes)
        notifyChange()
        write(data, id: normalized.id)
        return true
    }

    @discardableResult
    func delete(id: String) -> EvalEntry? {
        guard validateBoundaryOrFailClosed(),
              let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = entries.remove(at: index)
        let removedBytes = diskBytesByID.removeValue(forKey: id) ?? encodedSize(removed)
        bytesOnDisk = max(0, bytesOnDisk - removedBytes)
        notifyChange()
        let url = fileURL(id: id)
        let directory = directory
        let entriesDirectory = entriesDirectory
        ioQueue.async {
            guard Self.hasSafeManagedBoundary(
                directory: directory,
                entriesDirectory: entriesDirectory
            ) else { return }
            try? FileManager.default.removeItem(at: url)
        }
        return removed
    }

    @discardableResult
    func deleteOldest(_ n: Int) -> [EvalEntry] {
        guard validateBoundaryOrFailClosed(), n > 0 else { return [] }
        let removed = Array(entries.sorted { $0.capturedAt < $1.capturedAt }.prefix(n))
        let ids = Set(removed.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        let removedBytes = removed.reduce(Int64(0)) { total, entry in
            total + (diskBytesByID.removeValue(forKey: entry.id) ?? encodedSize(entry))
        }
        bytesOnDisk = max(0, bytesOnDisk - removedBytes)
        notifyChange()
        let urls = removed.map { fileURL(id: $0.id) }
        let directory = directory
        let entriesDirectory = entriesDirectory
        ioQueue.async {
            guard Self.hasSafeManagedBoundary(
                directory: directory,
                entriesDirectory: entriesDirectory
            ) else { return }
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        return removed
    }

    func deleteAll() {
        guard validateBoundaryOrFailClosed() else { return }
        clearMemoryAndNotify()
        let directory = directory
        let entriesDirectory = entriesDirectory
        ioQueue.async {
            guard Self.hasSafeManagedBoundary(
                directory: directory,
                entriesDirectory: entriesDirectory
            ) else { return }
            try? FileManager.default.removeItem(at: entriesDirectory)
            try? FileManager.default.createDirectory(
                at: entriesDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: entriesDirectory.path
            )
        }
    }

    func ensureDirectories() {
        guard validateBoundaryOrFailClosed() else { return }
        if !prepareDirectories() {
            acceptsWrites = false
            lifecycleGeneration &+= 1
            clearMemoryAndNotify()
        }
    }

    /// Starts a fresh process session. This removes entries left by a crash or
    /// SIGKILL before any reload/capture can expose them. Failure leaves the
    /// store empty and disabled for the process.
    @discardableResult
    func beginNewSessionClearingOrphans() -> Bool {
        acceptsWrites = false
        lifecycleGeneration &+= 1
        clearMemoryAndNotify()
        let directory = directory
        let entriesDirectory = entriesDirectory
        let succeeded = ioQueue.sync {
            Self.replaceManagedEntries(
                directory: directory,
                entriesDirectory: entriesDirectory,
                recreate: true
            )
        }
        acceptsWrites = succeeded
        if !succeeded {
            evalStoreLog.error("Could not clear orphaned Eval Mode session data")
        }
        return succeeded
    }

    /// Called only from applicationWillTerminate, after termination can no
    /// longer be canceled by an unsaved-draft window prompt.
    @discardableResult
    func endSessionAndClear() -> Bool {
        acceptsWrites = false
        lifecycleGeneration &+= 1
        clearMemoryAndNotify()
        let directory = directory
        let entriesDirectory = entriesDirectory
        let succeeded = ioQueue.sync {
            Self.replaceManagedEntries(
                directory: directory,
                entriesDirectory: entriesDirectory,
                recreate: false
            )
        }
        if !succeeded {
            evalStoreLog.error("Could not clear Eval Mode data at termination")
        }
        return succeeded
    }

    private func prepareDirectories() -> Bool {
        guard Self.hasSafeManagedBoundary(
            directory: directory,
            entriesDirectory: entriesDirectory
        ) else {
            evalStoreLog.error("Refusing symlinked Eval Mode storage boundary")
            return false
        }
        for url in [directory, entriesDirectory] {
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: url.path
                )
            } catch {
                evalStoreLog.error("Could not prepare Eval Mode directory: \(error.localizedDescription, privacy: .private)")
                return false
            }
        }
        return true
    }

    func waitForPendingIO() async {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume() }
        }
    }

    private func write(_ data: Data, id: String) {
        let destination = fileURL(id: id)
        let generation = lifecycleGeneration
        let directory = directory
        let entriesDirectory = entriesDirectory
        ioQueue.async {
            guard Self.hasSafeManagedBoundary(
                directory: directory,
                entriesDirectory: entriesDirectory
            ) else {
                Task { @MainActor [weak self] in
                    self?.failClosedForUnsafeBoundary()
                }
                return
            }
            do {
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
                let allocated = try destination.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey]
                ).totalFileAllocatedSize
                Task { @MainActor [weak self] in
                    self?.applyWrittenSize(
                        Int64(allocated ?? data.count),
                        id: id,
                        generation: generation
                    )
                }
            } catch {
                evalStoreLog.error("Could not write Eval Mode entry: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func applyWrittenSize(_ size: Int64, id: String, generation: UInt64) {
        guard acceptsWrites,
              generation == lifecycleGeneration,
              entries.contains(where: { $0.id == id }),
              let previous = diskBytesByID[id] else {
            return
        }
        diskBytesByID[id] = size
        bytesOnDisk = max(0, bytesOnDisk - previous + size)
        notifyChange()
    }

    private func fileURL(id: String) -> URL {
        entriesDirectory.appendingPathComponent(id).appendingPathExtension("json")
    }

    private func encodedSize(_ entry: EvalEntry) -> Int64 {
        Int64((try? encoder.encode(entry).count) ?? 0)
    }

    private func normalizedEntry(_ entry: EvalEntry) -> EvalEntry {
        Self.normalizedEntryStatic(entry)
    }

    nonisolated private static func normalizedEntryStatic(_ entry: EvalEntry) -> EvalEntry {
        // Reconstruct through EvalEntry.init so decoded or caller-provided reruns are capped at ten.
        EvalEntry(
            schema: entry.schema,
            id: entry.id,
            capturedAt: entry.capturedAt,
            source: entry.source,
            appBundleID: entry.appBundleID,
            original: entry.original,
            output: entry.output,
            outcome: entry.outcome,
            reason: entry.reason,
            elapsedMS: entry.elapsedMS,
            abandoned: entry.abandoned,
            label: entry.label,
            reruns: entry.reruns
        )
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .evalStoreDidChange, object: self)
    }

    private func clearMemoryAndNotify() {
        entries.removeAll()
        diskBytesByID.removeAll()
        bytesOnDisk = 0
        notifyChange()
    }

    private func validateBoundaryOrFailClosed() -> Bool {
        guard acceptsWrites else { return false }
        guard Self.hasSafeManagedBoundary(
            directory: directory,
            entriesDirectory: entriesDirectory
        ) else {
            failClosedForUnsafeBoundary()
            return false
        }
        return true
    }

    private func failClosedForUnsafeBoundary() {
        if acceptsWrites {
            acceptsWrites = false
            lifecycleGeneration &+= 1
        }
        clearMemoryAndNotify()
        evalStoreLog.error("Disabled Eval Mode storage because a managed boundary is a symlink")
    }

    nonisolated private static func replaceManagedEntries(
        directory: URL,
        entriesDirectory: URL,
        recreate: Bool
    ) -> Bool {
        let fm = FileManager.default
        do {
            guard hasSafeManagedBoundary(
                directory: directory,
                entriesDirectory: entriesDirectory
            ) else { return false }
            var rootIsDirectory: ObjCBool = false
            if fm.fileExists(atPath: directory.path, isDirectory: &rootIsDirectory),
               !rootIsDirectory.boolValue {
                // A malformed root file cannot contain user exports. Replace
                // it so the known entries directory can be prepared.
                try fm.removeItem(at: directory)
            } else if fm.fileExists(atPath: entriesDirectory.path) {
                // Only this child is managed session data. Preserve exports or
                // any other unexpected files saved in the Eval root itself.
                try fm.removeItem(at: entriesDirectory)
            }
            if recreate {
                try fm.createDirectory(
                    at: entriesDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try fm.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
                try fm.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: entriesDirectory.path
                )
            }
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func hasSafeManagedBoundary(
        directory: URL,
        entriesDirectory: URL
    ) -> Bool {
        !isSymbolicLink(directory) && !isSymbolicLink(entriesDirectory)
    }

    nonisolated private static func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }
}
