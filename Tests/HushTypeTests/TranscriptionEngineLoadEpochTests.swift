import XCTest
@testable import HushType

@MainActor
final class TranscriptionEngineLoadEpochTests: XCTestCase {
    func testTwoWaitersForOneLoadBothSucceed() async {
        let commits = SharedModelCommitState<NSObject>()
        let loaded = NSObject()
        var release: CheckedContinuation<NSObject, Never>?
        let load = Task { @MainActor in
            await withCheckedContinuation { release = $0 }
        }
        let first = Task { @MainActor in
            commits.acceptLoad(await load.value, generation: 0)
        }
        let second = Task { @MainActor in
            commits.acceptLoad(await load.value, generation: 0)
        }
        while release == nil { await Task.yield() }
        release?.resume(returning: loaded)
        let firstAccepted = await first.value
        let secondAccepted = await second.value
        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(secondAccepted)
        XCTAssertTrue(commits.model === loaded)
    }

    func testSwitchBetweenSharedLoadWaitersRejectsLateWaiter() async {
        let commits = SharedModelCommitState<NSObject>()
        let loaded = NSObject()
        var releaseLate: CheckedContinuation<Void, Never>?
        let sharedLoad = Task { @MainActor in loaded }
        let first = Task { @MainActor in
            commits.acceptLoad(await sharedLoad.value, generation: 0)
        }
        let late = Task { @MainActor in
            let sameLoaded = await sharedLoad.value
            await withCheckedContinuation { releaseLate = $0 }
            return commits.acceptLoad(sameLoaded, generation: 0)
        }
        let firstAccepted = await first.value
        XCTAssertTrue(firstAccepted)
        while releaseLate == nil { await Task.yield() }
        // Reinstalling the same instance makes the epoch check essential.
        XCTAssertTrue(commits.swap(loaded, generation: 0))
        releaseLate?.resume()
        let lateAccepted = await late.value
        XCTAssertFalse(lateAccepted)
        XCTAssertTrue(commits.model === loaded)
        XCTAssertEqual(commits.generation, 1)
    }
}
