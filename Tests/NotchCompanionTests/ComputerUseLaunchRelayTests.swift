import XCTest
@testable import NotchCompanion

@MainActor
final class ComputerUseLaunchRelayTests: XCTestCase {
    private func fixture(_ check: (URL, [String: Any]) throws -> Void) throws {
        let relay = try ComputerUseLaunchRelay()
        defer { relay.stop() }
        let app = relay.directory.appendingPathComponent("Fixture.app")
        let executable = app.appendingPathComponent("Contents/MacOS/cua-driver")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: app) }
        let arguments = ["serve", "--embedded", "--socket", relay.directory.appendingPathComponent("hc-123456789abc.sock").path,
                         "--no-permissions-gate", "--permission-mode", "unrestricted", "--dangerously-bypass-approvals", "--no-overlay"]
        try check(relay.directory, ["app": app.path, "arguments": arguments, "expires_at": 110.0])
    }

    func testNativeUnrestrictedRequestPreservesExactArgumentsAndPrivateSocket() throws {
        try fixture { lease, payload in
            let request = try ComputerUseLaunchRelay.validate(payload, directory: lease, now: 100)
            XCTAssertEqual(request.arguments, payload["arguments"] as? [String])
            XCTAssertEqual(request.socket.deletingLastPathComponent(), lease)
            XCTAssertEqual(request.executable.lastPathComponent, "cua-driver")
            let attributes = try FileManager.default.attributesOfItem(atPath: lease.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }

    func testRefusesExpiredExcessiveBooleanAndNonfiniteDeadlines() throws {
        try fixture { lease, original in
            let expiries: [Any] = [99.0, 100.0, 120.1, true, Double.infinity, Double.nan, "110"]
            for expiry in expiries {
                var payload = original; payload["expires_at"] = expiry
                XCTAssertThrowsError(try ComputerUseLaunchRelay.validate(payload, directory: lease, now: 100))
            }
        }
    }

    func testRefusesGlobalOtherLeaseTraversalAndExistingSockets() throws {
        try fixture { lease, original in
            let initial = original["arguments"] as! [String]
            for path in ["/tmp/cua-driver.sock", "/private/tmp/notch-cua-other/hc-123456789abc.sock",
                         lease.path + "/../hc-123456789abc.sock", lease.path + "/hc-123.sock"] {
                var arguments = initial; arguments[3] = path
                var payload = original; payload["arguments"] = arguments
                XCTAssertThrowsError(try ComputerUseLaunchRelay.validate(payload, directory: lease, now: 100))
            }
            let socket = URL(fileURLWithPath: initial[3])
            try Data().write(to: socket)
            defer { try? FileManager.default.removeItem(at: socket) }
            XCTAssertThrowsError(try ComputerUseLaunchRelay.validate(original, directory: lease, now: 100))
        }
    }

    func testRefusesDanglingSocketSymlink() throws {
        try fixture { lease, original in
            let socket = (original["arguments"] as! [String])[3]
            try FileManager.default.createSymbolicLink(atPath: socket, withDestinationPath: "/tmp/notch-nonexistent-\(UUID())")
            defer { try? FileManager.default.removeItem(atPath: socket) }
            XCTAssertThrowsError(try ComputerUseLaunchRelay.validate(original, directory: lease, now: 100))
        }
    }

    func testRequiresMatchingModeAcknowledgementAndRefusesUnknownOrDuplicateFlags() throws {
        try fixture { lease, original in
            let initial = original["arguments"] as! [String]
            let variants = [Array(initial.prefix(7)), initial + ["--unknown"], initial + ["--no-overlay"],
                            initial + ["--approve-capability-manifest"], initial + ["--socket", "/tmp/another.sock"],
                            Array(initial.prefix(6)) + ["standard"]]
            for arguments in variants {
                var payload = original; payload["arguments"] = arguments
                XCTAssertThrowsError(try ComputerUseLaunchRelay.validate(payload, directory: lease, now: 100))
            }
        }
    }

    func testBoundedModeRequiresManifestAndApprovalWithoutBypass() throws {
        try fixture { lease, original in
            let manifest = lease.appendingPathComponent("policy.json")
            try Data("{}".utf8).write(to: manifest)
            defer { try? FileManager.default.removeItem(at: manifest) }
            let prefix = Array((original["arguments"] as! [String]).prefix(6)) + ["bounded"]
            var payload = original
            payload["arguments"] = prefix + ["--capability-manifest", manifest.path, "--approve-capability-manifest", "--no-overlay"]
            let request = try ComputerUseLaunchRelay.validate(payload, directory: lease, now: 100)
            XCTAssertTrue(request.arguments.contains(manifest.path))
            for arguments in [prefix, prefix + ["--capability-manifest", manifest.path],
                              prefix + ["--capability-manifest", manifest.path, "--approve-capability-manifest", "--dangerously-bypass-approvals"]] {
                payload["arguments"] = arguments
                XCTAssertThrowsError(try ComputerUseLaunchRelay.validate(payload, directory: lease, now: 100))
            }
        }
    }

    func testUnknownPayloadFieldsAndExecutableSymlinksAreRejected() throws {
        try fixture { lease, original in
            var payload = original; payload["command"] = "/bin/sh"
            XCTAssertThrowsError(try ComputerUseLaunchRelay.validate(payload, directory: lease, now: 100))
            let app = URL(fileURLWithPath: original["app"] as! String)
            let executable = app.appendingPathComponent("Contents/MacOS/cua-driver")
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
            XCTAssertThrowsError(try ComputerUseLaunchRelay.validate(original, directory: lease, now: 100))
        }
    }

    func testOnlyExactSignedIdentitiesAreAccepted() {
        XCTAssertTrue(ComputerUseLaunchRelay.hasExpectedIdentity("Identifier=com.trycua.driver\nTeamIdentifier=YCK386LBJ7\n"))
        XCTAssertTrue(ComputerUseLaunchRelay.hasExpectedIdentity("Identifier=com.trycua.driver\nTeamIdentifier=4YEC26S9KF\n"))
        for output in ["Identifier=com.trycua.driver.other\nTeamIdentifier=YCK386LBJ7",
                       "Identifier=com.trycua.driver\nTeamIdentifier=not set",
                       "Identifier=com.trycua.driver\nTeamIdentifier=OTHER",
                       "Identifier=com.trycua.driver\nTeamIdentifier=YCK386LBJ7\nTeamIdentifier=OTHER"] {
            XCTAssertFalse(ComputerUseLaunchRelay.hasExpectedIdentity(output))
        }
    }

    func testLeaseMustRemainPrivateAndCannotBeReplacedWithSymlink() throws {
        try fixture { lease, payload in
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lease.path)
            XCTAssertThrowsError(try ComputerUseLaunchRelay.validate(payload, directory: lease, now: 100))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lease.path)
            let moved = lease.deletingLastPathComponent().appendingPathComponent("notch-cua-moved-\(UUID())")
            try FileManager.default.moveItem(at: lease, to: moved)
            try FileManager.default.createSymbolicLink(at: lease, withDestinationURL: moved)
            defer {
                try? FileManager.default.removeItem(at: lease)
                try? FileManager.default.moveItem(at: moved, to: lease)
            }
            XCTAssertThrowsError(try ComputerUseLaunchRelay.validate(payload, directory: lease, now: 100))
        }
    }

    func testRelayRejectsRecreatedLeaseWithDifferentInode() async throws {
        let relay = try ComputerUseLaunchRelay()
        let moved = relay.directory.deletingLastPathComponent().appendingPathComponent("notch-cua-moved-\(UUID())")
        try FileManager.default.moveItem(at: relay.directory, to: moved)
        try FileManager.default.createDirectory(at: relay.directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            try? FileManager.default.removeItem(at: relay.directory)
            try? FileManager.default.removeItem(at: moved)
        }
        do { try await relay.launch([:]); XCTFail("Replaced lease must not launch") } catch {}
        relay.stop()
        await relay.waitForStop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: relay.directory.path), "Cleanup must not remove a replacement directory")
    }

    func testStoppedRelayRejectsAllLaunches() async throws {
        let relay = try ComputerUseLaunchRelay()
        relay.stop()
        await relay.waitForStop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: relay.directory.path))
        do { try await relay.launch([:]); XCTFail("Stopped relay must reject launch") } catch {}
    }
}
