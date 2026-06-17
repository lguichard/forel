import Foundation
// import Sparkle  // TEMP: disabled in dev — see note below.

/// Thin wrapper around Sparkle's standard updater, driven by a GitHub
/// Releases appcast. Replaces the Tauri updater plugin.
///
/// TEMP (dev): Sparkle is disabled because starting the updater in an
/// unsigned dev build with no valid appcast feed throws an error on launch.
/// This stub keeps the app's interface intact (no auto-check, no error).
/// Re-enable the commented code below before shipping a signed/notarised build.
@MainActor
final class UpdaterManager: ObservableObject {
    // let controller: SPUStandardUpdaterController

    private var autoCheck = false

    init() {
        // controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        // controller.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { autoCheck }
        set { autoCheck = newValue }
        // get { controller.updater.automaticallyChecksForUpdates }
        // set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
