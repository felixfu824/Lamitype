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
        ensureDirectories()
    }

    @discardableResult
    func append(_ entry: EvalEntry) -> Bool {
        guard !isFull else { return false }
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
        let entriesDirectory = entriesDirectory
        let decoder = decoder
        let loaded = await withCheckedContinuation { continuation in
            ioQueue.async {
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
                continuation.resume(returning: (decoded, corrupt))
            }
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
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
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
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = entries.remove(at: index)
        let removedBytes = diskBytesByID.removeValue(forKey: id) ?? encodedSize(removed)
        bytesOnDisk = max(0, bytesOnDisk - removedBytes)
        notifyChange()
        let url = fileURL(id: id)
        ioQueue.async { try? FileManager.default.removeItem(at: url) }
        return removed
    }

    @discardableResult
    func deleteOldest(_ n: Int) -> [EvalEntry] {
        guard n > 0 else { return [] }
        let removed = Array(entries.sorted { $0.capturedAt < $1.capturedAt }.prefix(n))
        let ids = Set(removed.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        let removedBytes = removed.reduce(Int64(0)) { total, entry in
            total + (diskBytesByID.removeValue(forKey: entry.id) ?? encodedSize(entry))
        }
        bytesOnDisk = max(0, bytesOnDisk - removedBytes)
        notifyChange()
        let urls = removed.map { fileURL(id: $0.id) }
        ioQueue.async { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        return removed
    }

    func deleteAll() {
        entries.removeAll()
        diskBytesByID.removeAll()
        bytesOnDisk = 0
        notifyChange()
        let entriesDirectory = entriesDirectory
        ioQueue.async {
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
            }
        }
    }

    func waitForPendingIO() async {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume() }
        }
    }

    private func write(_ data: Data, id: String) {
        let destination = fileURL(id: id)
        ioQueue.async {
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
                    self?.applyWrittenSize(Int64(allocated ?? data.count), id: id)
                }
            } catch {
                evalStoreLog.error("Could not write Eval Mode entry: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func applyWrittenSize(_ size: Int64, id: String) {
        guard entries.contains(where: { $0.id == id }), let previous = diskBytesByID[id] else {
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
}
