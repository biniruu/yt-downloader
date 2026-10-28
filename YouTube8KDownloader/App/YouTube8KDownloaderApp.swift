import AppKit
import SwiftUI

/// Ensures that closing the app window completely terminates the process,
/// preventing stale background processes from persisting when reopening.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

@main
@MainActor
struct YouTube8KDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        YTDLPService.appLog("=== YouTube 8K Downloader Launched (v1.3.0 Build 6) PID: \(ProcessInfo.processInfo.processIdentifier) ===")
    }

    var body: some Scene {
        WindowGroup("YouTube 8K Downloader") {
            MainContentView()
        }
        .defaultSize(width: 900, height: 720)
        .windowResizability(.contentMinSize)
    }
}
