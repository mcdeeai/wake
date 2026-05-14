import Foundation
import IOKit
import IOKit.pwr_mgt
import Darwin

// Module-scope so the C signal handler can reach it
nonisolated(unsafe) var currentChildPID: pid_t = 0

func runCommand(args: [String]) {
    var rest = args
    var notify = false
    var preventDisplay = false
    var clamshell = false
    var reason = "wake CLI session"

    parseLoop: while let first = rest.first {
        switch first {
        case "--notify":
            notify = true
            rest.removeFirst()
        case "--display":
            preventDisplay = true
            rest.removeFirst()
        case "--clamshell":
            clamshell = true
            rest.removeFirst()
        case "--reason":
            rest.removeFirst()
            guard let value = rest.first else {
                fputs("wake: --reason requires a value\n", stderr)
                exit(2)
            }
            reason = value
            rest.removeFirst()
        case "--":
            rest.removeFirst()
            break parseLoop
        default:
            break parseLoop
        }
    }

    guard !rest.isEmpty else {
        printUsage()
        exit(2)
    }

    let command = rest[0]
    let commandArgs = Array(rest.dropFirst())

    // Power assertion (idle sleep)
    guard let assertionID = createAssertion(display: preventDisplay, reason: reason) else {
        fputs("wake: failed to create power assertion\n", stderr)
        exit(1)
    }

    var released = false
    func releaseAssertion() {
        if !released {
            IOPMAssertionRelease(assertionID)
            released = true
        }
    }

    // Clamshell claim (lid-closed sleep)
    var clamshellClaimed = false
    if clamshell {
        switch claimClamshell() {
        case .ok:
            clamshellClaimed = true
        case .notSetUp:
            fputs("wake: --clamshell requires one-time setup. Run: sudo wake clamshell setup\n", stderr)
            releaseAssertion()
            exit(1)
        case .pmsetFailed(let msg):
            fputs("wake: failed to enable clamshell mode: \(msg)\n", stderr)
            releaseAssertion()
            exit(1)
        }
    }

    func cleanup() {
        if clamshellClaimed {
            releaseClamshell()
            clamshellClaimed = false
        }
        releaseAssertion()
    }

    // Spawn child
    let startTime = Date()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + commandArgs
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    // Signal forwarding to child
    func forward(_ sig: Int32) {
        signal(sig) { s in
            if currentChildPID != 0 {
                kill(currentChildPID, s)
            }
        }
    }
    forward(SIGINT)
    forward(SIGTERM)
    forward(SIGHUP)
    forward(SIGQUIT)

    do {
        try process.run()
        currentChildPID = process.processIdentifier
        process.waitUntilExit()
    } catch {
        fputs("wake: failed to run command: \(error.localizedDescription)\n", stderr)
        cleanup()
        exit(1)
    }

    let exitCode = process.terminationStatus
    let elapsed = Date().timeIntervalSince(startTime)

    cleanup()

    if notify {
        sendNotification(command: command, exitCode: exitCode, elapsed: elapsed)
    }

    exit(exitCode)
}

private func createAssertion(display: Bool, reason: String) -> IOPMAssertionID? {
    var id: IOPMAssertionID = 0
    let type = display
        ? kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
        : kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
    let result = IOPMAssertionCreateWithName(
        type,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        reason as CFString,
        &id
    )
    return result == kIOReturnSuccess ? id : nil
}

private func sendNotification(command: String, exitCode: Int32, elapsed: TimeInterval) {
    let mins = Int(elapsed) / 60
    let secs = Int(elapsed) % 60
    let timeStr = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    let status = exitCode == 0 ? "finished" : "failed (exit \(exitCode))"
    let title = "wake: \(status)"
    let body = "\(command) — \(timeStr)"

    let osa = Process()
    osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    osa.arguments = ["-e", "display notification \"\(body)\" with title \"\(title)\""]
    try? osa.run()
    osa.waitUntilExit()
}
