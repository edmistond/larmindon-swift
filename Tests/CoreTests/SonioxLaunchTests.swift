import XCTest
@testable import LarmindonKit

@MainActor
final class SonioxLaunchTests: XCTestCase {
    private struct StubCredentials: ProviderCredentialStore {
        func hasCredential(for provider: ServerProviderID) -> Bool { true }
        func credential(for provider: ServerProviderID) throws -> String? { "test-key" }
        func saveCredential(_ credential: String, for provider: ServerProviderID) throws {}
        func removeCredential(for provider: ServerProviderID) throws {}
    }

    /// Regression for 2026-09-29: Release builds crashed the instant a Soniox session
    /// started, on the first retain of the source `CaptionSession.makeSource` returned. Goes
    /// through the real `makeSource`, not a `sourceFactory`, because that inlined path is what
    /// broke. It only fails when built with `-configuration Release`.
    func testStartingSonioxThroughRealSourceFactoryDoesNotCrash() async {
        for encoding in SonioxAudioEncoding.allCases {
            let session = CaptionSession(
                selectedSourceKind: .live,
                requestedMode: .server,
                sonioxAudioEncoding: encoding,
                diagnostics: DiagnosticRecorder(capacity: 100),
                credentialStore: StubCredentials()
            )
            XCTAssertTrue(session.startIfIdle(mode: .server))
            let deadline = ContinuousClock.now + .seconds(5)
            while session.lastError == nil, !session.store.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await session.stop()
        }
    }

    /// URLSession can call a ping's pong handler more than once when the connection fails;
    /// only the first call may resume the continuation.
    func testSingleResumptionAdmitsOnlyTheFirstCaller() async {
        let resumption = SingleResumption()
        let claims = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<50 {
                group.addTask { resumption.claim() }
            }
            var count = 0
            for await claimed in group where claimed {
                count += 1
            }
            return count
        }
        XCTAssertEqual(claims, 1)
        XCTAssertFalse(resumption.claim())
    }
}
