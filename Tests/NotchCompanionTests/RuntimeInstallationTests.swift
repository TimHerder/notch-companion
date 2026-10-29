import XCTest
@testable import NotchCompanion

final class RuntimeInstallationTests: XCTestCase {
    private var directory: URL!
    private var home: URL { directory.appendingPathComponent("User Home") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-installation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        directory = directory.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testSavedHermesSourceOverridesEnvironmentAndSupportsSpacesAndSymlinks() throws {
        let selected = try source("Selected Hermes", virtualEnvironment: ".venv")
        let other = try source("Other Hermes")
        let alias = home.appendingPathComponent("Hermes Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: selected)
        let result = try hermes(["NOTCH_HERMES_SOURCE": other.path], configuredSource: alias.path)
        XCTAssertEqual(result.source, selected.resolvingSymlinksInPath())
        XCTAssertEqual(result.python, result.source.appendingPathComponent(".venv/bin/python"))
    }

    func testInvalidExplicitHermesSourceDoesNotSilentlyUseWorkingFallback() throws {
        let fallback = try source(".hermes/hermes-agent")
        for selected in ["missing", home.appendingPathComponent("missing").path, fallback.appendingPathComponent("venv").path] {
            XCTAssertThrowsError(try hermes(["NOTCH_HERMES_SOURCE": fallback.path], configuredSource: selected)) {
                XCTAssertTrue($0.localizedDescription.contains("Settings"))
            }
        }
        XCTAssertThrowsError(try hermes(["NOTCH_HERMES_SOURCE": home.appendingPathComponent("missing").path]))
        try FileManager.default.removeItem(at: fallback.appendingPathComponent("venv/bin/python"))
        XCTAssertThrowsError(try hermes([:], configuredSource: fallback.path))
    }

    func testHermesManagedInterpreterFromLiteralLauncherWithoutExecutingIt() throws {
        let installed = try source("Canary Hermes")
        try FileManager.default.removeItem(at: installed.appendingPathComponent("venv"))
        try Data().write(to: installed.appendingPathComponent("hermes_bootstrap.py"))
        let python = home.appendingPathComponent("tools/python/bin/python3")
        try executable(python)
        let console = installed.appendingPathComponent(".hermes/bin/hermes")
        let marker = directory.appendingPathComponent("must-not-exist")
        try executable(console, text: "#!/bin/sh\nexec \"\(python.path)\" -I -c 'raise RuntimeError()'\n")
        try executable(home.appendingPathComponent(".local/bin/hermes"),
                       text: "#!/bin/sh\ntouch '\(marker.path)'\nexec \"\(console.path)\" \"$@\"\n")
        let automatic = try hermes([:])
        XCTAssertEqual(automatic.source, installed.resolvingSymlinksInPath())
        XCTAssertEqual(automatic.python.path, python.path)
        XCTAssertEqual(try hermes([:], configuredSource: installed.path), automatic)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try executable(console, text: "#!/bin/sh\nexec \"$(touch '\(marker.path)')\" -I -c 'pass'\n")
        XCTAssertThrowsError(try hermes([:]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testHermesDefaultInstallationDoesNotRequireProfileOrCredentials() throws {
        let installed = try source(".hermes/hermes-agent", virtualEnvironment: ".venv")
        XCTAssertEqual(try hermes([:]).source, installed.resolvingSymlinksInPath())
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".hermes/config.yaml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".hermes/auth.json").path))
    }

    func testHermesFindsInstallerHomeAndExplicitInstallDirectoryHints() throws {
        let inProfileHome = try source("Agent Data/hermes-agent")
        let custom = try source("Developer Tools/hermes")
        XCTAssertEqual(try hermes(["HERMES_HOME": home.appendingPathComponent("Agent Data").path]).source,
                       inProfileHome.resolvingSymlinksInPath())
        XCTAssertEqual(try hermes(["NOTCH_HERMES_SOURCE_HOME": home.appendingPathComponent("Agent Data").path]).source,
                       inProfileHome.resolvingSymlinksInPath())
        XCTAssertEqual(try hermes(["HERMES_INSTALL_DIR": custom.path,
                                  "HERMES_HOME": home.appendingPathComponent("Agent Data").path]).source,
                       custom.resolvingSymlinksInPath())
    }

    func testHermesNamedProfileHintsFindSourceInNativeRoot() throws {
        let installed = try source("Agent Data/hermes-agent")
        let namedProfile = home.appendingPathComponent("Agent Data/profiles/work")
        try FileManager.default.createDirectory(at: namedProfile, withIntermediateDirectories: true)
        XCTAssertEqual(try hermes(["HERMES_HOME": namedProfile.path]).source, installed.resolvingSymlinksInPath())
        XCTAssertEqual(try hermes(["NOTCH_HERMES_SOURCE_HOME": namedProfile.path]).source, installed.resolvingSymlinksInPath())
        XCTAssertFalse(FileManager.default.fileExists(atPath: namedProfile.appendingPathComponent("hermes-agent").path))
    }

    func testHermesFollowsBothOfficialWrapperLayoutsWithoutExecutingThem() throws {
        let installed = try source("Custom Installation")
        let marker = directory.appendingPathComponent("must-not-exist")
        let consoleScript = installed.appendingPathComponent("venv/bin/hermes")
        try executable(consoleScript, text: "#!/bin/sh\ntouch '\(marker.path)'\n")
        let launcher = home.appendingPathComponent(".local/bin/hermes")
        for command in ["\"\(consoleScript.path)\"", "\"\(installed.path)/venv/bin/python\" \"\(installed.path)/hermes\""] {
            try executable(launcher, text: "#!/usr/bin/env bash\nunset PYTHONPATH\nunset PYTHONHOME\nexec \(command) \"$@\"\n")
            XCTAssertEqual(try hermes([:]).source, installed.resolvingSymlinksInPath())
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testHermesPathSymlinkTakesPrecedenceOverDefaultInstallation() throws {
        _ = try source(".hermes/hermes-agent")
        let selected = try source("Development Hermes")
        let entrypoint = selected.appendingPathComponent("hermes")
        try executable(entrypoint)
        let bin = home.appendingPathComponent("Commands")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("hermes"), withDestinationURL: entrypoint)
        XCTAssertEqual(try hermes(["PATH": bin.path]).source, selected.resolvingSymlinksInPath())
    }

    func testHermesPreservesVirtualEnvironmentInterpreterSymlink() throws {
        let installed = try source("Hermes")
        let python = installed.appendingPathComponent("venv/bin/python")
        let base = directory.appendingPathComponent("Base Python")
        try executable(base)
        try FileManager.default.removeItem(at: python)
        try FileManager.default.createSymbolicLink(at: python, withDestinationURL: base)
        let result = try hermes(["NOTCH_HERMES_SOURCE": installed.path])
        XCTAssertEqual(result.python, installed.resolvingSymlinksInPath().appendingPathComponent("venv/bin/python"))
        XCTAssertNotEqual(result.python, base)
    }

    func testHermesRejectsShellExpressionsAndBoundsWrapperCycles() throws {
        let bin = home.appendingPathComponent("Commands")
        let first = bin.appendingPathComponent("hermes")
        let second = bin.appendingPathComponent("second")
        try executable(first, text: "#!/bin/sh\nexec \"\(second.path)\" \"$@\"\n")
        try executable(second, text: "#!/bin/sh\nexec \"\(first.path)\" \"$@\"\n")
        XCTAssertThrowsError(try hermes(["PATH": bin.path]))
        let marker = directory.appendingPathComponent("must-not-exist")
        try executable(first, text: "#!/bin/sh\nexec \"$(touch '\(marker.path)')\" \"$@\"\n")
        XCTAssertThrowsError(try hermes(["PATH": bin.path]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSavedCodexExecutableOverridesEnvironmentAndPath() throws {
        let saved = home.appendingPathComponent("My Codex/codex")
        let other = home.appendingPathComponent("Commands/codex")
        try executable(saved)
        try executable(other)
        let result = try codex(["NOTCH_CODEX_EXECUTABLE": other.path, "PATH": other.deletingLastPathComponent().path],
                               configuredExecutable: "~/My Codex/codex")
        XCTAssertEqual(result, saved)
        XCTAssertEqual(try codex(["NOTCH_CODEX_EXECUTABLE": other.path]), other)
    }

    func testInvalidExplicitCodexExecutableDoesNotSilentlyUseWorkingFallback() throws {
        let fallback = home.appendingPathComponent(".local/bin/codex")
        try executable(fallback)
        let folder = home.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let nonexecutable = home.appendingPathComponent("not-executable")
        try Data().write(to: nonexecutable)
        for invalid in [folder.path, nonexecutable.path, home.appendingPathComponent("missing").path, "codex"] {
            XCTAssertThrowsError(try codex([:], configuredExecutable: invalid)) {
                XCTAssertTrue($0.localizedDescription.contains("Settings"))
            }
        }
        XCTAssertThrowsError(try codex(["NOTCH_CODEX_EXECUTABLE": nonexecutable.path]))
    }

    func testCodexFindsUserBinWithoutInheritedPathAndPreservesPathPrecedence() throws {
        let userBin = home.appendingPathComponent(".local/bin/codex")
        let pathBin = home.appendingPathComponent("Development/bin/codex")
        try executable(userBin)
        try executable(pathBin)
        XCTAssertEqual(try codex([:]), userBin)
        XCTAssertEqual(try codex(["PATH": pathBin.deletingLastPathComponent().path]), pathBin)
    }

    func testCodexFindsBothUserApplicationBundles() throws {
        for path in ["Applications/Codex.app/Contents/Resources/codex",
                     "Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"] {
            let appExecutable = home.appendingPathComponent(path)
            try executable(appExecutable)
            XCTAssertEqual(try codex([:]), appExecutable)
            try FileManager.default.removeItem(at: appExecutable)
        }
        XCTAssertThrowsError(try codex([:]))
    }

    private func hermes(_ environment: [String: String], configuredSource: String? = nil) throws -> RuntimeInstallation.Hermes {
        try RuntimeInstallation.hermes(environment: environment, userHome: home, configuredSource: configuredSource,
                                       searchSystemLocations: false)
    }

    private func codex(_ environment: [String: String], configuredExecutable: String? = nil) throws -> URL {
        try RuntimeInstallation.codex(environment: environment, userHome: home, configuredExecutable: configuredExecutable,
                                      searchSystemLocations: false)
    }

    private func source(_ name: String, virtualEnvironment: String = "venv") throws -> URL {
        let source = home.appendingPathComponent(name)
        let module = source.appendingPathComponent("hermes_cli/main.py")
        try FileManager.default.createDirectory(at: module.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Fixture only; never imported.\n".utf8).write(to: module)
        try executable(source.appendingPathComponent("\(virtualEnvironment)/bin/python"))
        return source
    }

    private func executable(_ path: URL, text: String = "#!/bin/sh\nexit 1\n") throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }
}
