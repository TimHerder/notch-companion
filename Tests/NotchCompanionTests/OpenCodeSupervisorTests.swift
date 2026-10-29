import XCTest
@testable import NotchCompanion

@MainActor
final class OpenCodeSupervisorTests: XCTestCase {
    func testOwnershipEOFTerminatesOnlyTheOwnedNativeServer() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let owner = Pipe(), wrapper = Process(), unrelated = Process()
        wrapper.executableURL = supervisorBinary
        wrapper.arguments = [OpenCodeSupervisor.flag, fixture.server.path]
        wrapper.environment = ProcessInfo.processInfo.environment.merging(["NOTCH_TEST_DIRECTORY": fixture.directory.path]) { _, new in new }
        wrapper.standardInput = owner; wrapper.standardOutput = FileHandle.nullDevice; wrapper.standardError = FileHandle.nullDevice
        unrelated.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        unrelated.arguments = ["-c", "import time; time.sleep(10)"]
        unrelated.standardOutput = FileHandle.nullDevice; unrelated.standardError = FileHandle.nullDevice
        try unrelated.run(); try wrapper.run()
        defer { try? owner.fileHandleForWriting.close(); if unrelated.isRunning { unrelated.terminate() } }
        try await wait { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("native.pid").path) }
        try owner.fileHandleForWriting.close()
        try await wait { !wrapper.isRunning }
        XCTAssertEqual(wrapper.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("stopped"), encoding: .utf8), "signal")
        XCTAssertTrue(unrelated.isRunning, "Stopping this server must not stop another native process")
    }

    func testAbruptOwnerExitClosesTheNativeServerWithoutAnAppCleanupCallback() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        launcher.arguments = ["-c", #"""
        import os,pathlib,subprocess,sys,time
        root=pathlib.Path(os.environ['NOTCH_TEST_DIRECTORY'])
        child=subprocess.Popen([sys.argv[1],sys.argv[2],sys.argv[3]],stdin=subprocess.PIPE,
          stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,close_fds=True)
        deadline=time.monotonic()+5
        while not (root/'native.pid').exists() and time.monotonic()<deadline: time.sleep(.01)
        os._exit(0 if (root/'native.pid').exists() else 2)
        """#, supervisorBinary.path, OpenCodeSupervisor.flag, fixture.server.path]
        launcher.environment = ProcessInfo.processInfo.environment.merging(["NOTCH_TEST_DIRECTORY": fixture.directory.path]) { _, new in new }
        launcher.standardInput = FileHandle.nullDevice
        launcher.standardOutput = FileHandle.nullDevice; launcher.standardError = FileHandle.nullDevice
        try launcher.run()
        try await wait { !launcher.isRunning }
        XCTAssertEqual(launcher.terminationStatus, 0)
        try await wait { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("stopped").path) }
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("stopped"), encoding: .utf8), "signal",
                       "The native server must stop from pipe EOF, not its fixture watchdog")
    }

    private var supervisorBinary: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/NotchCompanion")
    }
    private func makeFixture() throws -> (directory: URL, server: URL) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Native process fixtures require system Python 3") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-opencode-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let server = directory.appendingPathComponent("native-server")
        try #"""
        #!/usr/bin/python3
        import os,pathlib,signal,sys,time
        assert sys.argv[1:]==['serve','--hostname','127.0.0.1','--port','0']
        root=pathlib.Path(os.environ['NOTCH_TEST_DIRECTORY'])
        def stop(*args):
          (root/'stopped').write_text('signal')
          sys.exit(0)
        signal.signal(signal.SIGINT,stop)
        signal.signal(signal.SIGTERM,stop)
        (root/'native.pid').write_text(str(os.getpid()))
        # Self-clean even if the implementation under test fails.
        time.sleep(10)
        (root/'stopped').write_text('watchdog')
        """#.write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        return (directory, server)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard predicate() else { XCTFail("Owned native process did not reach its expected state"); throw AppError("Supervisor fixture timeout") }
    }
}
