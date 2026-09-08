#if os(macOS) && !targetEnvironment(macCatalyst)
import Darwin
import Foundation
@testable import LuminaModelRuntime
import XCTest

final class NativeEngineBridgeCancellationTests: XCTestCase, @unchecked Sendable {
    func testCancellableExternalEngineReceivesRequestCancellationAndNextCallSucceeds() async throws {
        try await checkCancellation(cancellable: true)
    }

    func testLegacyExternalEngineSuccessIsDiscardedAfterCallerCancellation() async throws {
        try await checkCancellation(cancellable: false)
    }

    func testUnavailableANEIsRejectedBeforeLoadingEngine() async throws {
        let response = try await LuminaMiniCPMV46CxxEngineBridge.generate(
            modelDirectory: URL(fileURLWithPath: "/missing-test-model"),
            backendPreference: .ane, prompt: "test", contextLength: 16000,
            maxOutputTokens: 192, safetyMarginTokens: 256
        )
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("no ANE partition") == true)
    }

    private func checkCancellation(cancellable: Bool) async throws {
        if ProcessInfo.processInfo.environment["LUMINA_MINICPMV46_ENGINE"] != nil {
            throw XCTSkip("An explicit external engine override prevents loading the isolated ABI fixture.")
        }
        let fixture = try NativeEngineFixture(cancellable: cancellable)
        defer { fixture.cleanUp() }
        let directory = fixture.directory
        let request = Task.detached {
            try await Self.generate(directory: directory)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !fixture.hasStarted() && ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(fixture.hasStarted(), "The native request must be running before cancellation.")
        request.cancel()
        // A legacy engine cannot be interrupted. Let it return success and
        // verify that the host and Swift bridge still discard that response.
        if !cancellable { fixture.release() }
        do {
            _ = try await request.value
            XCTFail("A cancelled native request must never return success.")
        } catch is CancellationError {
            // Expected: the native callback or legacy fallback reached Swift.
        }
        fixture.release()
        let following = try await Self.generate(directory: directory)
        XCTAssertTrue(following.ok)
        XCTAssertEqual(following.output, "completed")
    }

    private static func generate(directory: URL) async throws -> LuminaMiniCPMV46EngineResponse {
        try await LuminaMiniCPMV46CxxEngineBridge.generate(
            modelDirectory: directory, backendPreference: .automatic, prompt: "test",
            contextLength: 16000, maxOutputTokens: 192, safetyMarginTokens: 256
        )
    }
}

private final class NativeEngineFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-abi-\(UUID().uuidString)")
    private let handle: UnsafeMutableRawPointer
    private let startedFunction: @convention(c) () -> Int32
    private let releaseFunction: @convention(c) () -> Void

    init(cancellable: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = app.appendingPathComponent("NativeEngines/MiniCPMV46/Tests/FakeExternalEngine.c")
        let library = directory.appendingPathComponent("libLuminaMiniCPMV46GGUFEngine.dylib")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", "-std=c11", "-dynamiclib",
            "-DLUMINA_FAKE_CANCELLABLE=\(cancellable ? 1 : 0)", source.path, "-o", library.path]
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw FixtureError.compilationFailed }
        guard let loaded = dlopen(library.path, RTLD_NOW | RTLD_LOCAL),
              let started = dlsym(loaded, "LuminaFakeEngineStarted"),
              let release = dlsym(loaded, "LuminaFakeEngineRelease") else {
            throw FixtureError.loadingFailed
        }
        handle = loaded
        startedFunction = unsafeBitCast(started, to: (@convention(c) () -> Int32).self)
        releaseFunction = unsafeBitCast(release, to: (@convention(c) () -> Void).self)
    }

    func hasStarted() -> Bool { startedFunction() != 0 }
    func release() { releaseFunction() }
    func cleanUp() {
        release()
        dlclose(handle)
        try? FileManager.default.removeItem(at: directory)
    }

    enum FixtureError: Error { case compilationFailed, loadingFailed }
}
#endif
