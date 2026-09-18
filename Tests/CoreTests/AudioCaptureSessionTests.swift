import AVFAudio
import XCTest
@testable import LarmindonKit

@MainActor
final class AudioCaptureSessionTests: XCTestCase {
    private final class Driver: AudioCaptureDriving {
        var failsAfterAcquiring = false
        var ownsResource = false
        var startCount = 0
        var stopCount = 0

        func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> AudioCaptureStartInfo {
            startCount += 1
            ownsResource = true
            if failsAfterAcquiring { throw StartError.failed }
            return AudioCaptureStartInfo(voiceProcessingEnabled: false, fields: [:])
        }

        func stop() {
            stopCount += 1
            ownsResource = false
        }
    }

    private enum StartError: Error { case failed }

    func testPartialStartReleasesAcquiredResourceExactlyOnce() async {
        let driver = Driver()
        driver.failsAfterAcquiring = true
        let session = AudioCaptureSession(driver: driver)
        do {
            try await session.start()
            XCTFail("Expected startup to fail after acquiring the resource")
        } catch {}
        await session.stop()
        await session.stop()
        XCTAssertFalse(driver.ownsResource)
        XCTAssertEqual(driver.stopCount, 1)
        var frames = session.frames.makeAsyncIterator()
        let frame = await frames.next()
        XCTAssertNil(frame)
    }
    @MainActor
    private final class Permission {
        var continuation: CheckedContinuation<Void, Never>?
        var entered: CheckedContinuation<Void, Never>?
        func request() async {
            await withCheckedContinuation {
                continuation = $0
                entered?.resume()
                entered = nil
            }
        }
        func waitUntilRequested() async {
            if continuation != nil { return }
            await withCheckedContinuation { entered = $0 }
        }
        func grant() { continuation?.resume(); continuation = nil }
    }

    func testStopWhilePermissionIsPendingNeverAcquiresResources() async {
        let driver = Driver()
        let permission = Permission()
        let session = AudioCaptureSession(driver: driver, requestPermission: { await permission.request() })
        let start = Task { try await session.start() }
        await permission.waitUntilRequested()
        await session.stop()
        permission.grant()
        do { try await start.value; XCTFail("Stopped startup must not succeed") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(driver.stopCount, 0)
    }

    func testCancelledPermissionWaitDoesNotStartCapture() async {
        let driver = Driver()
        let permission = Permission()
        let session = AudioCaptureSession(driver: driver, requestPermission: { await permission.request() })
        let start = Task { try await session.start() }
        await permission.waitUntilRequested()
        start.cancel()
        permission.grant()
        do { try await start.value; XCTFail("Cancelled startup must not succeed") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await session.stop()
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(driver.stopCount, 0)
    }

    func testRetiredCaptureStopDoesNotReleaseReplacementResource() async throws {
        let oldDriver = Driver()
        let replacementDriver = Driver()
        let old = AudioCaptureSession(driver: oldDriver)
        let replacement = AudioCaptureSession(driver: replacementDriver)
        try await old.start()
        await old.stop()
        try await replacement.start()
        await old.stop()
        XCTAssertTrue(replacementDriver.ownsResource)
        XCTAssertEqual(oldDriver.stopCount, 1)
        XCTAssertEqual(replacementDriver.stopCount, 0)
        await replacement.stop()
        XCTAssertEqual(replacementDriver.stopCount, 1)
    }

    private final class CaptureOwningSource: TranscriptionSource {
        let name = "Capture owner"
        let results = AsyncStream<CaptionResult> { $0.finish() }
        let levelUpdates = AsyncStream<AudioLevelSnapshot> { $0.finish() }
        let gate = AsyncGate()
        var didRelease = false
        func start() async throws {}
        func stop() async {
            await gate.suspend()
            didRelease = true
        }
    }

    func testRouteReleaseWaitsForLocalCaptureAndSourceTeardown() async throws {
        let driver = Driver()
        let capture = AudioCaptureSession(driver: driver)
        let source = CaptureOwningSource()
        try await capture.start()
        var didReleaseRoute = false
        let stop = Task {
            await CaptionSessionTeardown.stopLocalResources(capture: capture, source: source) {
                XCTAssertFalse(driver.ownsResource)
                XCTAssertTrue(source.didRelease)
                didReleaseRoute = true
            }
        }
        await source.gate.waitUntilEntered()
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertFalse(didReleaseRoute)
        await source.gate.release()
        await stop.value
        XCTAssertTrue(didReleaseRoute)
        await capture.stop()
        XCTAssertEqual(driver.stopCount, 1)
    }

}
