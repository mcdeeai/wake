import Foundation
import IOKit
import IOKit.pwr_mgt
import Darwin

// MARK: - Argument parsing

let args = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    wake — prevent sleep while a command runs

    Usage:
      wake run [--notify] [--display] [--reason TEXT] -- <command> [args...]
      wake run [--notify] [--display] [--reason TEXT] <command> [args...]

    Options:
      --notify        Show a notification when the command finishes
      --display       Also prevent display sleep
      --reason TEXT   Reason shown in `pmset -g assertions`
    """)
}

guard let subcommand = args.first, subcommand == "run" else {
    printUsage()
    exit(2)
}

var rest = Array(args.dropFirst())
var notify = false
var preventDisplay = false
var reason = "wake CLI session"

parseLoop: while let first = rest.first {
    switch first {
    case "--notify":
        notify = true
        rest.removeFirst()
    case "--display":
        preventDisplay = true
        rest.removeFirst()
    case "--reason":
        rest.removeFirst()
        guard let value = rest.first else {
            fputs("--reason requires a value\n", stderr)
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

// MARK: - Power assertion

func createAssertion(display: Bool, reason: String) -> IOPMAssertionID? {
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

guard let assertionID = createAssertion(display: preventDisplay, reason: reason) else {
    fputs("wake: failed to create power assertion\n", stderr)
    exit(1)
}

// Ensure release on any exit path
var released = false
func releaseAssertion() {
    if !released {
        IOPMAssertionRelease(assertionID)
        released = true
    }
}

// MARK: - Spawn child

let startTime = Date()
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = [command] + commandArgs
process.standardInput = FileHandle.standardInput
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

// MARK: - Signal forwarding

var currentChildPID: pid_t = 0

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

// MARK: - Run

do {
    try process.run()
    currentChildPID = process.processIdentifier
    process.waitUntilExit()
} catch {
    fputs("wake: failed to run command: \(error.localizedDescription)\n", stderr)
    releaseAssertion()
    exit(1)
}

let exitCode = process.terminationStatus
let elapsed = Date().timeIntervalSince(startTime)

releaseAssertion()

// MARK: - Notification

if notify {
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

exit(exitCode)
