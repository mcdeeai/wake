import Foundation
import Darwin

// MARK: - Top-level dispatch

let allArgs = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    wake — prevent sleep while a command runs

    Usage:
      wake run [--notify] [--display] [--clamshell] [--reason TEXT] -- <command> [args...]

      wake clamshell setup        One-time install (requires sudo)
      wake clamshell uninstall    Remove sudoers + watchdog (requires sudo)
      wake clamshell status       Show clamshell setup state

    Options for `run`:
      --notify        Show a notification when the command finishes
      --display       Also prevent display sleep
      --clamshell     Also keep system awake when the lid is closed
                      (requires `wake clamshell setup` to have been run once)
      --reason TEXT   Reason shown in `pmset -g assertions`
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
