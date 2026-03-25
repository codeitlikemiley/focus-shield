import SwiftUI
import KeyboardShortcuts
import AppKit

// MARK: - App Delegate

/// Custom delegate that prevents the main window from being destroyed on close.
class FocusShieldAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    @Published var isWindowVisible = true
    var viewModel: FocusShieldViewModel?

    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.findAndConfigureMainWindow()
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
        mainWindow?.orderOut(nil)
        isWindowVisible = false
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.cleanupOnQuit()
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
