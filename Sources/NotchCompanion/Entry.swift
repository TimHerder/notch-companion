import AppKit
import Darwin

@main
enum NotchCompanionEntry {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == OpenCodeSupervisor.flag {
            exit(OpenCodeSupervisor.run(arguments: CommandLine.arguments))
        }
        if CommandLine.arguments.dropFirst().first == DelegationBridge.flag {
            exit(DelegationBridge.run())
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = CompanionAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var host: NativeHost?
    private var connectTask: Task<Void, Never>?
    private var terminationApproved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let model = AppModel()
        self.model = model
        model.terminateApplication = { [weak self] in
            self?.terminationApproved = true
            NSApp.terminate(nil)
        }
        host = NativeHost(model: model)
        connectTask = Task { await model.connect() }
        if CommandLine.arguments.contains("--open") { host?.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        host?.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationApproved, let model else { return .terminateNow }
        Task { await model.requestQuit() }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        connectTask?.cancel()
        host?.shutdown()
        model?.shutdown()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit Notch Companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
}
