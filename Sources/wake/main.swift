import Foundation
import Darwin

// MARK: - Top-level dispatch

let allArgs = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    wake — prevent sleep while a command runs

    Usage:
      wake run [options] -- <command> [args...]
      wake test [seconds]               Smoke test (defaults to 30s)

      wake clamshell setup              One-time install (requires sudo)
      wake clamshell uninstall          Remove sudoers + watchdog (requires sudo)
      wake clamshell status             Show clamshell setup state

    Defaults (the convenient ones):
      • Notify on completion (use --quiet / -q to silence)
      • Use clamshell mode if it's been set up (use --no-clamshell to skip)

    Options for `run`:
      --quiet, -q       Don't show a notification when finished
      --display         Also prevent display sleep
      --clamshell       Require clamshell mode (error if not set up)
      --no-clamshell    Disable clamshell mode for this run
      --reason TEXT     Reason shown in `pmset -g assertions`
    """)
}

guard let subcommand = allArgs.first else {
    printUsage()
    exit(2)
}

let subArgs = Array(allArgs.dropFirst())

switch subcommand {
case "run":
    runCommand(args: subArgs)
case "test":
    let seconds = subArgs.first.flatMap(Int.init) ?? 30
    print("wake: running a \(seconds)s smoke test. Close the lid now if you want to test clamshell mode.")
    runCommand(args: ["--reason", "wake smoke test", "--", "/bin/sleep", String(seconds)])
case "clamshell":
    guard let action = subArgs.first else {
        printUsage()
        exit(2)
    }
    switch action {
    case "setup":
        clamshellSetup()
    case "uninstall":
        clamshellUninstall()
    case "status":
        clamshellStatus()
    default:
        printUsage()
        exit(2)
    }
case "-h", "--help", "help":
    printUsage()
    exit(0)
default:
    printUsage()
    exit(2)
}
