import AppKit
import Cocoa
import GhosttyKit

// Launched from a shell inside another Ghostty (e.g. `open Ghostty.app`), we
// inherit that app's GHOSTTY_RESOURCES_DIR, and every shell would load its
// shell integration instead of ours. Drop a value from another app bundle;
// a hand-set one (development) is left alone.
if let inherited = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"],
   inherited.contains(".app/Contents/Resources"),
   !inherited.hasPrefix(Bundle.main.bundlePath + "/") {
    unsetenv("GHOSTTY_RESOURCES_DIR")
}

// Initialize Ghostty global state. We do this once right away because the
// CLI APIs require it and it lets us ensure it is done immediately for the
// rest of the app.
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    Ghostty.logger.critical("ghostty_init failed")

    // We also write to stderr if this is executed from the CLI or zig run
    switch Ghostty.launchSource {
    case .cli, .zig_run:
        let stderrHandle = FileHandle.standardError
        stderrHandle.write(
            "Ghostty failed to initialize! If you're executing Ghostty from the command line\n" +
            "then this is usually because an invalid action or multiple actions were specified.\n" +
            "Actions start with the `+` character.\n\n" +
            "View all available actions by running `ghostty +help`.\n")
        exit(1)

    case .app:
        // For the app we exit immediately. We should handle this case more
        // gracefully in the future.
        exit(1)
    }
}

// This will run the CLI action and exit if one was specified. A CLI
// action is a command starting with a `+`, such as `ghostty +boo`.
ghostty_cli_try_action()

// Make tooltips appear near-instantly (default is ~1.5s).
// Must be set before NSApplicationMain so the tooltip system picks it up.
UserDefaults.standard.set(100, forKey: "NSInitialToolTipDelay")

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
