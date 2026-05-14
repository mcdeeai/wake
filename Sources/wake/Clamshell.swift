import Foundation
import Darwin

// MARK: - Paths

enum ClamshellPaths {
    static let pidDir = "/tmp/wake-clamshell.d"
    static let lockFile = "/tmp/wake-clamshell.lock"
    static let sudoersFile = "/etc/sudoers.d/wake"
    static let watchdogScript = "/usr/local/libexec/wake-watchdog.sh"
    static let launchdPlist = "/Library/LaunchDaemons/com.mcdeeai.wake.watchdog.plist"
    static let launchdLabel = "com.mcdeeai.wake.watchdog"
    static let logFile = "/var/log/wake-watchdog.log"
}

// MARK: - File contents

let sudoersContent = """
# Installed by `wake clamshell setup` (https://github.com/mcdeeai/wake)
# Allows the wake CLI to toggle clamshell-sleep prevention without prompting.
# To remove: sudo wake clamshell uninstall
ALL ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
ALL ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1

"""

let watchdogScriptContent = """
#!/bin/bash
# Installed by `wake clamshell setup`. Re-enables system sleep if all wake
# processes have died without cleaning up. Runs every 30s via launchd.
set -u

PIDDIR="/tmp/wake-clamshell.d"

# Remove markers for processes that no longer exist.
if [ -d "$PIDDIR" ]; then
    for f in "$PIDDIR"/*; do
        [ -e "$f" ] || continue
        pid=$(basename "$f")
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$f"
        fi
    done
fi

# Count remaining live markers.
COUNT=0
if [ -d "$PIDDIR" ]; then
    COUNT=$(/usr/bin/find "$PIDDIR" -type f 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
fi

# Read current disablesleep state.
DISABLED=$(/usr/bin/pmset -g 2>/dev/null | /usr/bin/awk '/disablesleep/ {print $2}' | /usr/bin/head -n 1)

if [ "$COUNT" = "0" ] && [ "$DISABLED" = "1" ]; then
    /usr/bin/pmset -a disablesleep 0
fi

"""

func launchdPlistContent() -> String {
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(ClamshellPaths.launchdLabel)</string>
        <key>ProgramArguments</key>
        <array>
            <string>/bin/bash</string>
            <string>\(ClamshellPaths.watchdogScript)</string>
        </array>
        <key>StartInterval</key>
        <integer>30</integer>
        <key>RunAtLoad</key>
        <true/>
        <key>StandardOutPath</key>
        <string>\(ClamshellPaths.logFile)</string>
        <key>StandardErrorPath</key>
        <string>\(ClamshellPaths.logFile)</string>
    </dict>
    </plist>

    """
}

// MARK: - Claim / release

enum ClaimResult {
    case ok
    case notSetUp
    case pmsetFailed(String)
}

private func withClamshellLock<T>(_ body: () throws -> T) rethrows -> T {
    let fd = open(ClamshellPaths.lockFile, O_RDWR | O_CREAT, 0o666)
    if fd < 0 {
        // Best-effort: proceed without lock
        return try body()
    }
    defer {
        flock(fd, LOCK_UN)
        close(fd)
    }
    flock(fd, LOCK_EX)
    return try body()
}

private func ensurePidDir() {
    let fm = FileManager.default
    if !fm.fileExists(atPath: ClamshellPaths.pidDir) {
        try? fm.createDirectory(
            atPath: ClamshellPaths.pidDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o1777]
        )
        // Re-chmod in case umask trimmed bits
        chmod(ClamshellPaths.pidDir, 0o1777)
    }
}

private func currentMarkerPath() -> String {
    return "\(ClamshellPaths.pidDir)/\(getpid())"
}

private func liveMarkerCount() -> Int {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: ClamshellPaths.pidDir) else {
        return 0
    }
    var count = 0
    for entry in entries {
        if let pid = pid_t(entry), kill(pid, 0) == 0 {
            count += 1
        } else {
            // stale; clean up
            try? fm.removeItem(atPath: "\(ClamshellPaths.pidDir)/\(entry)")
        }
    }
    return count
}

private func pmsetDisableSleepIs() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        return false
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let out = String(data: data, encoding: .utf8) else { return false }
    for line in out.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("disablesleep") {
            return trimmed.hasSuffix(" 1")
        }
    }
    return false
}

@discardableResult
private func runPmset(_ value: String) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]
    let errPipe = Pipe()
    p.standardError = errPipe
    p.standardOutput = Pipe()
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        return (-1, "could not run sudo: \(error.localizedDescription)")
    }
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    let errStr = String(data: errData, encoding: .utf8) ?? ""
    return (p.terminationStatus, errStr.trimmingCharacters(in: .whitespacesAndNewlines))
}

func claimClamshell() -> ClaimResult {
    // Verify sudoers fragment exists.
    if !FileManager.default.fileExists(atPath: ClamshellPaths.sudoersFile) {
        return .notSetUp
    }

    return withClamshellLock {
        ensurePidDir()
        // Touch marker for our PID
        let marker = currentMarkerPath()
        FileManager.default.createFile(atPath: marker, contents: nil, attributes: nil)

        // If disablesleep is already on, nothing more to do.
        if pmsetDisableSleepIs() {
            return .ok
        }

        let (status, err) = runPmset("1")
        if status != 0 {
            // Roll back our marker
            try? FileManager.default.removeItem(atPath: marker)
            if err.contains("a password is required") || err.contains("sudo:") {
                return .notSetUp
            }
            return .pmsetFailed(err.isEmpty ? "exit \(status)" : err)
        }
        return .ok
    }
}

func releaseClamshell() {
    withClamshellLock {
        let marker = currentMarkerPath()
        try? FileManager.default.removeItem(atPath: marker)
        if liveMarkerCount() == 0 {
            // Best-effort; ignore failure
            _ = runPmset("0")
        }
    }
}

// MARK: - Setup / uninstall / status

private func requireRoot(_ action: String) {
    if getuid() != 0 {
        fputs("wake: `clamshell \(action)` must be run as root. Try: sudo wake clamshell \(action)\n", stderr)
        exit(1)
    }
}

private func writeFile(path: String, contents: String, mode: mode_t) {
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        chmod(path, mode)
    } catch {
        fputs("wake: failed to write \(path): \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private func runOrFail(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        fputs("wake: \(args[0]) failed: \(error.localizedDescription)\n", stderr)
    }
}

func clamshellSetup() {
    requireRoot("setup")

    print("Installing sudoers fragment at \(ClamshellPaths.sudoersFile)…")
    writeFile(path: ClamshellPaths.sudoersFile, contents: sudoersContent, mode: 0o440)

    // Validate sudoers syntax.
    let visudo = Process()
    visudo.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
    visudo.arguments = ["-c", "-f", ClamshellPaths.sudoersFile]
    do {
        try visudo.run()
        visudo.waitUntilExit()
        if visudo.terminationStatus != 0 {
            try? FileManager.default.removeItem(atPath: ClamshellPaths.sudoersFile)
            fputs("wake: sudoers fragment failed validation; aborted.\n", stderr)
            exit(1)
        }
    } catch {
        fputs("wake: could not run visudo: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    print("Installing watchdog script at \(ClamshellPaths.watchdogScript)…")
    writeFile(path: ClamshellPaths.watchdogScript, contents: watchdogScriptContent, mode: 0o755)

    print("Installing launchd plist at \(ClamshellPaths.launchdPlist)…")
    writeFile(path: ClamshellPaths.launchdPlist, contents: launchdPlistContent(), mode: 0o644)
    chown(ClamshellPaths.launchdPlist, 0, 0)

    print("Loading watchdog…")
    // bootout first in case it's already loaded
    runOrFail(["/bin/launchctl", "bootout", "system", ClamshellPaths.launchdPlist])
    runOrFail(["/bin/launchctl", "bootstrap", "system", ClamshellPaths.launchdPlist])

    print("""

    ✓ wake clamshell installed.

      You can now run:
        wake run --clamshell --notify -- your-long-command

      To remove:
        sudo wake clamshell uninstall
    """)
}

func clamshellUninstall() {
    requireRoot("uninstall")

    print("Unloading watchdog…")
    runOrFail(["/bin/launchctl", "bootout", "system", ClamshellPaths.launchdPlist])

    let fm = FileManager.default
    for path in [
        ClamshellPaths.sudoersFile,
        ClamshellPaths.watchdogScript,
        ClamshellPaths.launchdPlist,
    ] {
        if fm.fileExists(atPath: path) {
            print("Removing \(path)…")
            try? fm.removeItem(atPath: path)
        }
    }

    // Make sure we don't leave the system with disablesleep stuck on.
    if pmsetDisableSleepIs() {
        print("Restoring system sleep (disablesleep=0)…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-a", "disablesleep", "0"]
        try? p.run()
        p.waitUntilExit()
    }

    print("\n✓ wake clamshell removed.")
}

func clamshellStatus() {
    let fm = FileManager.default
    let sudoersInstalled = fm.fileExists(atPath: ClamshellPaths.sudoersFile)
    let scriptInstalled = fm.fileExists(atPath: ClamshellPaths.watchdogScript)
    let plistInstalled = fm.fileExists(atPath: ClamshellPaths.launchdPlist)
    let disabled = pmsetDisableSleepIs()
    let live = (try? FileManager.default.contentsOfDirectory(atPath: ClamshellPaths.pidDir).count) ?? 0

    func mark(_ b: Bool) -> String { b ? "✓" : "✗" }

    print("""
    wake clamshell status
      \(mark(sudoersInstalled)) sudoers fragment   \(ClamshellPaths.sudoersFile)
      \(mark(scriptInstalled)) watchdog script    \(ClamshellPaths.watchdogScript)
      \(mark(plistInstalled)) launchd plist      \(ClamshellPaths.launchdPlist)

    Currently:
      disablesleep = \(disabled ? "1 (system sleep is being prevented)" : "0 (normal)")
      active wake --clamshell processes = \(live)
    """)

    if !(sudoersInstalled && scriptInstalled && plistInstalled) {
        print("\nRun `sudo wake clamshell setup` to install.")
    }
}
