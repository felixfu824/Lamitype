import AppKit
import AVFoundation
import Combine
import XCTest
@testable import HushType

@MainActor
final class SettingsStatusModelTests: XCTestCase {
    func testPermissionsAndRestrictedMicrophone() {
        let fixture = Fixture()
        let model = fixture.makeModel()

        for (accessibility, microphone, expected) in [
            (true, AVAuthorizationStatus.authorized, PaneStatus.ok(.permissionsGranted)),
            (false, .authorized, .attention(.needsAccessibility)),
            (true, .notDetermined, .attention(.needsMicrophone)),
            (true, .denied, .attention(.needsMicrophone)),
            (false, .denied, .attention(.needsBoth)),
            (true, .restricted, .attention(.microphoneRestricted)),
            (false, .restricted, .attention(.microphoneRestricted))
        ] {
            fixture.permissions = (accessibility, microphone)
            model.refresh(.general)
            XCTAssertEqual(model.status[.general], expected)
        }
    }

    func testDictationUsesActiveModelAndSelectedCloudKeyState() {
        let fixture = Fixture()
        let model = fixture.makeModel()

        for modelID in [AppConfig.LocalModel.fast.huggingFaceID,
                        AppConfig.LocalModel.optimized.huggingFaceID,
                        "/tmp/custom-model"] {
            fixture.localModel = LocalModelKind(modelID: modelID)
            model.refresh(.dictation)
            XCTAssertEqual(model.status[.dictation], .ok(.localModel(fixture.localModel)))
        }
        XCTAssertEqual(LocalModelKind(modelID: AppConfig.LocalModel.fast.huggingFaceID), .fast)
        XCTAssertEqual(LocalModelKind(modelID: AppConfig.LocalModel.optimized.huggingFaceID), .optimized)
        XCTAssertEqual(LocalModelKind(modelID: "/tmp/custom-model"), .custom("custom-model"))

        for (engine, provider) in [(AppConfig.DictationEngine.openai, CloudProvider.openAI), (.gemini, .gemini)] {
            fixture.engine = engine
            for (key, hasKey) in [(KeyState.loaded, true), (.unusualFormat, true), (.missing, false)] {
                fixture.keys[provider] = key
                model.refresh(.dictation)
                let detail = PaneStatusDetail.cloudEngine(provider, hasKey: hasKey)
                XCTAssertEqual(model.status[.dictation], hasKey ? .ok(detail) : .attention(detail))
            }
        }
    }

    func testCaptionRefreshUsesRunningSourceAndOptionalApplicationName() {
        let fixture = Fixture()
        let model = fixture.makeModel()
        XCTAssertEqual(model.status[.caption], .ok(.captionOff))

        fixture.captionSource = .mic
        model.refresh(.caption)
        XCTAssertEqual(model.status[.caption], .ok(.captionMicrophone))

        fixture.captionSource = .system(bundleID: "com.example.player")
        fixture.appNames["com.example.player"] = "Player"
        model.refresh(.caption)
        XCTAssertEqual(model.status[.caption], .ok(.captionSystem(appName: "Player")))

        fixture.captionSource = .system(bundleID: "com.example.unknown")
        model.refresh(.caption)
        XCTAssertEqual(model.status[.caption], .ok(.captionSystem(appName: nil)))

        fixture.captionSource = nil
        model.refresh(.caption)
        XCTAssertEqual(model.status[.caption], .ok(.captionOff))
    }

    func testCloudStatusReadsWithoutCreatingKeyFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let openAI = directory.appendingPathComponent("openai.json")
        let gemini = directory.appendingPathComponent("gemini.json")
        let fixture = Fixture()
        let model = fixture.makeModel(keyState: { provider in
            SettingsStatusModel.keyState(provider, at: provider == .openAI ? openAI : gemini)
        })

        XCTAssertEqual(model.status[.cloud], .attention(.keys(openAI: .missing, gemini: .missing)))
        XCTAssertEqual(OpenAIKeyStore.readExisting(at: openAI), .empty)
        XCTAssertEqual(GeminiKeyStore.readExisting(at: gemini), .empty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])

        try #"{"api_key":"sk-example"}"#.write(to: openAI, atomically: true, encoding: .utf8)
        try #"{"api_key":"AIzaexample"}"#.write(to: gemini, atomically: true, encoding: .utf8)
        model.refresh(.cloud)
        XCTAssertEqual(model.status[.cloud], .ok(.keys(openAI: .loaded, gemini: .loaded)))

        try #"{"api_key":"unexpected-prefix"}"#.write(to: openAI, atomically: true, encoding: .utf8)
        try "invalid JSON".write(to: gemini, atomically: true, encoding: .utf8)
        model.refresh(.cloud)
        XCTAssertEqual(model.status[.cloud], .attention(.keys(openAI: .unusualFormat, gemini: .missing)))

        try #"{"api_key":"  "}"#.write(to: openAI, atomically: true, encoding: .utf8)
        try #"{"api_key":"unexpected-prefix"}"#.write(to: gemini, atomically: true, encoding: .utf8)
        model.refresh(.cloud)
        XCTAssertEqual(model.status[.cloud], .attention(.keys(openAI: .missing, gemini: .unusualFormat)))
    }

    func testTextAndServerStatesAndNoAboutStatus() {
        let fixture = Fixture()
        let model = fixture.makeModel()
        XCTAssertEqual(Set(model.status.keys), [.general, .dictation, .caption, .text, .cloud, .ios])
        XCTAssertEqual(model.status[.text], .attention(.polishUnavailable))
        XCTAssertEqual(model.status[.ios], .ok(.iosServerStopped))

        fixture.polish = (true, true)
        fixture.iosRunning = true
        model.refresh(.text)
        XCTAssertEqual(model.status[.text], .ok(.polishChecking))
        XCTAssertEqual(model.status[.ios], .ok(.iosServerStopped))

        fixture.polish = (true, false)
        model.refresh()
        XCTAssertEqual(model.status[.text], .ok(.polishAvailable))
        XCTAssertEqual(model.status[.ios], .ok(.iosServerRunning))

        model.refresh(.about)
        XCTAssertNil(model.status[.about])
    }

    func testNotificationsRefreshAffectedPanesAndActivationRefreshesAll() async {
        let fixture = Fixture()
        let notifications = NotificationCenter()
        let model = fixture.makeModel(notifications: notifications)

        func expectRefresh(_ name: Notification.Name, pane: SettingsPane, expected: PaneStatus) async {
            let updated = expectation(description: name.rawValue)
            let subscription = model.$status.dropFirst().first { $0[pane] == expected }
                .sink { _ in updated.fulfill() }
            notifications.post(name: name, object: nil)
            await fulfillment(of: [updated], timeout: 1)
            subscription.cancel()
        }

        fixture.engine = .openai
        await expectRefresh(.lamitypeDictationEngineDidChange, pane: .dictation,
                            expected: .attention(.cloudEngine(.openAI, hasKey: false)))

        fixture.engine = .local
        fixture.localModel = .optimized
        await expectRefresh(.lamitypeLocalModelDidChange, pane: .dictation, expected: .ok(.localModel(.optimized)))

        fixture.iosRunning = true
        await expectRefresh(.iosServerStatusDidChange, pane: .ios, expected: .ok(.iosServerRunning))

        fixture.captionSource = .mic
        fixture.permissions = (false, .authorized)
        await expectRefresh(NSApplication.didBecomeActiveNotification, pane: .caption, expected: .ok(.captionMicrophone))
        XCTAssertEqual(model.status[.general], .attention(.needsAccessibility))
    }

    @MainActor
    private final class Fixture {
        var permissions: (Bool, AVAuthorizationStatus) = (true, .authorized)
        var engine = AppConfig.DictationEngine.local
        var localModel = LocalModelKind.fast
        var captionSource: AudioSourceKind?
        var appNames: [String: String] = [:]
        var keys: [CloudProvider: KeyState] = [:]
        var polish = (false, false)
        var iosRunning = false

        func makeModel(
            notifications: NotificationCenter = NotificationCenter(),
            keyState: ((CloudProvider) -> KeyState)? = nil
        ) -> SettingsStatusModel {
            SettingsStatusModel(providers: .init(
                permissions: { self.permissions },
                dictationEngine: { self.engine },
                localModel: { self.localModel },
                captionSource: { self.captionSource },
                captionAppName: { self.appNames[$0] },
                keyState: keyState ?? { self.keys[$0] ?? .missing },
                polish: { self.polish },
                iosServerRunning: { self.iosRunning }
            ), notifications: notifications)
        }
    }
}
