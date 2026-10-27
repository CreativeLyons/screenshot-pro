import AppKit

/// Quits the app and opens it again, for permission grants that only apply after a relaunch.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        // A detached shell waits for this process to exit, then reopens the bundle. The path is
        // passed as $0 rather than spliced into the script, so spaces need no quoting.
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath]
        do {
            try task.run()
        } catch {
            NSLog("Screenshot Pro: could not schedule the relaunch: %@", error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }
}
