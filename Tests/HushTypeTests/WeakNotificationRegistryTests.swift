import XCTest
@testable import HushType

final class WeakNotificationRegistryTests: XCTestCase {
    @MainActor func testLiveNotificationFindsItsOwner() {
        let registry = WeakNotificationRegistry<NSObject>()
        let owner = NSObject(), token = registry.register(NSObject())
        let live = registry.register(owner)
        XCTAssertTrue(registry.owner(for: live) === owner)
        XCTAssertNil(registry.owner(for: token))
    }
    @MainActor func testQueuedNotificationAfterOwnerReleaseIsIgnored() {
        let registry = WeakNotificationRegistry<NSObject>()
        var owner: NSObject? = NSObject()
        weak var observed = owner
        let token = registry.register(owner!)
        owner = nil
        XCTAssertNil(observed, "Registry must not extend the insertion target lifetime")
        XCTAssertNil(registry.owner(for: token), "Late native callback must be a no-op")
    }
    @MainActor func testExpiredTokenCannotAddressNewOwner() {
        let registry = WeakNotificationRegistry<NSObject>()
        var first: NSObject? = NSObject()
        let old = registry.register(first!)
        first = nil
        let second = NSObject(), current = registry.register(second)
        XCTAssertNotEqual(old, current)
        XCTAssertNil(registry.owner(for: old))
        XCTAssertTrue(registry.owner(for: current) === second)
    }
    func testNativeCallbackInvalidationIsSafeAcrossThreads() {
        let registry = WeakNotificationRegistry<LiveFocusInvalidation>()
        let flag = LiveFocusInvalidation(), token = registry.register(LiveFocusInvalidation())
        let live = registry.register(flag)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            registry.owner(for: token)?.invalidate() // already expired
            registry.owner(for: live)?.invalidate()
        }
        XCTAssertNil(registry.owner(for: token))
        XCTAssertTrue(flag.isInvalidated)
    }

}
