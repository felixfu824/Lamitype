import Foundation

/// Opaque tokens never dereference expired native callback context pointers.
/// The lock protects the registry only; each owner owns its own synchronization.
final class WeakNotificationRegistry<Owner: AnyObject>: @unchecked Sendable {
    private final class Entry {
        weak var owner: Owner?
        init(_ owner: Owner) { self.owner = owner }
    }
    private let lock = NSLock()
    private var entries: [UInt: Entry] = [:]
    private var nextToken: UInt = 1

    func register(_ owner: Owner) -> UInt {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.owner != nil }
        precondition(nextToken < UInt.max, "Notification token space exhausted")
        let token = nextToken; nextToken += 1
        entries[token] = Entry(owner)
        return token
    }
    func owner(for token: UInt) -> Owner? {
        lock.lock(); defer { lock.unlock() }
        return entries[token]?.owner
    }
}

/// AX callbacks invalidate insertion synchronously, without invoking Swift's
/// actor-executor check from a foreign/native callback or accessing AppKit.
final class LiveFocusInvalidation: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    func invalidate() { lock.lock(); invalidated = true; lock.unlock() }
    var isInvalidated: Bool { lock.lock(); defer { lock.unlock() }; return invalidated }
}
