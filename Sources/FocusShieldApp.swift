import SwiftUI
import KeyboardShortcuts
import AppKit

// MARK: - App Delegate

/// Custom delegate that prevents the main window from being destroyed on close.
@MainActor
class FocusShieldAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    @Published var isWindowVisible = true
    var viewModel: FocusShieldViewModel?

    private var mainWindow: NSWindow?
    private var restartObserver: NSObjectProtocol?
    private var isPresentingBrowserRestartAlert = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enforce single instance
        if let bundleID = Bundle.main.bundleIdentifier {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            let currentPID = ProcessInfo.processInfo.processIdentifier
            if let existing = runningApps.first(where: { $0.processIdentifier != currentPID }) {
                print("Another instance of Focus Shield is already running. Activating it and terminating this duplicate.")
                existing.activate(options: .activateAllWindows)
                NSApplication.shared.terminate(nil)
                return
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // Must activate so an LSUIElement app window can accept keyboard input
            NSApplication.shared.activate(ignoringOtherApps: true)
            self?.findAndConfigureMainWindow()
            self?.mainWindow?.makeKeyAndOrderFront(nil)
        }

        restartObserver = NotificationCenter.default.addObserver(
            forName: .focusShieldBrowserRestartRequired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.presentPendingBrowserRestartIfNeeded()
            }
        }
    }

    private func findAndConfigureMainWindow() {
        for window in NSApplication.shared.windows where window.canBecomeMain {
            mainWindow = window
            window.delegate = self
            isWindowVisible = window.isVisible
            break
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        presentPendingBrowserRestartIfNeeded()
        sender.orderOut(nil)
        isWindowVisible = false
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func toggleMainWindow() {
        if isWindowVisible { hideMainWindow() } else { showMainWindow() }
    }

    func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            isWindowVisible = true
            return
        }
        for window in NSApplication.shared.windows where window.canBecomeMain {
            mainWindow = window
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
            isWindowVisible = true
            return
        }
    }

    func hideMainWindow() {
        presentPendingBrowserRestartIfNeeded()
        mainWindow?.orderOut(nil)
        isWindowVisible = false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let restartObserver {
            NotificationCenter.default.removeObserver(restartObserver)
            self.restartObserver = nil
        }
        viewModel?.cleanupOnQuit()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.viewModel?.refreshNetworkFilterStatus(force: true)
        }
    }

    func presentPendingBrowserRestartIfNeeded() {
        guard let vm = viewModel, vm.hasPendingBrowserRestart else { return }
        guard !isPresentingBrowserRestartAlert else { return }
        let names = vm.runningBrowserNames
        guard !names.isEmpty else {
            vm.hasPendingBrowserRestart = false
            return
        }

        isPresentingBrowserRestartAlert = true
        defer { isPresentingBrowserRestartAlert = false }

        let alert = NSAlert()
        alert.messageText = "Restart Browsers?"
        alert.informativeText = "You have updated the Focus Shield rules. To enforce these changes immediately, open browsers (\(names.joined(separator: ", "))) must be restarted to clear their active connections.\n\nDo you want to restart them now?"
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            vm.restartBrowsers()
        } else {
            vm.hasPendingBrowserRestart = true
        }
    }
}

// MARK: - App Entry Point

@main
struct FocusShieldApp: App {
    @NSApplicationDelegateAdaptor(FocusShieldAppDelegate.self) var appDelegate
    @State private var viewModel = FocusShieldViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .preferredColorScheme(viewModel.settings.themeMode.colorScheme)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 680)

        MenuBarExtra {
            MenuBarView(appDelegate: appDelegate)
                .environment(viewModel)
        } label: {
            Image(systemName: viewModel.settings.masterEnabled ? "shield.checkered" : "shield")
                .symbolRenderingMode(.hierarchical)
        }
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @ObservedObject var appDelegate: FocusShieldAppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: vm.settings.masterEnabled ? "shield.checkered" : "shield")
                    .font(.title3)
                    .foregroundStyle(vm.settings.masterEnabled ? .green : .secondary)
                Text(vm.settings.masterEnabled ? "Focus Shield Active" : "Focus Shield Off")
                    .font(.headline)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            Button {
                appDelegate.toggleMainWindow()
            } label: {
                Label(
                    appDelegate.isWindowVisible ? "Hide Focus Shield" : "Show Focus Shield",
                    systemImage: appDelegate.isWindowVisible ? "macwindow.badge.minus" : "macwindow"
                )
            }

            Divider()

            Button {
                vm.toggle()
            } label: {
                Label(
                    vm.settings.masterEnabled ? "Turn Off Shield" : "Turn On Shield",
                    systemImage: vm.settings.masterEnabled ? "shield.slash" : "shield.checkered"
                )
            }

            if vm.settings.masterEnabled, let profile = vm.activeProfile {
                Divider()

                let domainCount = profile.totalEnabledDomains
                let appCount = profile.blockedAppBundleIDs.count
                let cliCount = profile.totalCLIRulesCount

                Text("  \(domainCount) domains · \(appCount) apps · \(cliCount) CLI rules")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)

                Text("  Profile: \(profile.profile.name)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleFocusShield) {
                Text("  Hotkey: \(shortcut.description)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
            }

            Divider()

            Button("Quit Focus Shield") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
    }
}
