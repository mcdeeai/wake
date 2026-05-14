# wake

A tiny macOS CLI that keeps your Mac awake while a command runs, then optionally pings you when it's done.

```sh
wake run -- npm run build
wake run --notify -- cargo build --release
wake run --notify --display --reason "training run" -- python train.py
```

## Why does this exist?

macOS already ships with [`caffeinate(8)`](x-man-page://caffeinate), and you should know about it:

```sh
caffeinate -i npm run build
```

That covers the 90% case. `wake` is a thin convenience wrapper around the same `IOPMAssertion` API that `caffeinate` uses, with a few extras I kept reaching for:

- **`--notify`** — desktop notification when the command finishes, with elapsed time and exit status. No more tabbing back to a terminal to check if your build is done.
- **`--display`** — keep the display awake too (equivalent to `caffeinate -d`), but spelled in a way I can remember.
- **`--reason TEXT`** — labels the power assertion so it shows up clearly in `pmset -g assertions`. Helpful when you're auditing what's keeping your machine awake.
- **Signal forwarding** — `Ctrl-C`, `SIGTERM`, `SIGHUP`, `SIGQUIT` are forwarded to the child process, so it cleans up properly.
- **Exit code passthrough** — `wake` exits with the same status as the wrapped command, so it composes in shell pipelines and CI.

If `caffeinate` does what you need, use `caffeinate`. If you want notifications and a slightly friendlier interface, try `wake`.

## Install

Requires macOS 11+ and Swift 5.9+ (ships with Xcode / Command Line Tools).

```sh
git clone https://github.com/mcdeeai/wake.git
cd wake
swift build -c release
cp .build/release/wake /usr/local/bin/
```

Or in one line:

```sh
swift build -c release && sudo install .build/release/wake /usr/local/bin/wake
```

## Usage

```
wake run [--notify] [--display] [--reason TEXT] -- <command> [args...]
```

| Flag | Meaning |
| --- | --- |
| `--notify` | Show a notification when the command finishes |
| `--display` | Also prevent display sleep |
| `--reason TEXT` | Reason shown in `pmset -g assertions` (default: `wake CLI session`) |
| `--` | Optional separator before the command |

The `--` is optional but recommended if your command has flags that look like `wake`'s own flags.

### Examples

```sh
# Long build, notify me when done
wake run --notify -- pnpm build

# Keep the screen on for a presentation script
wake run --display -- ./demo.sh

# Tag your assertion so you can find it in pmset
wake run --reason "nightly export" -- ./export.sh
```

## How it works

`wake` calls `IOPMAssertionCreateWithName` with either `PreventUserIdleSystemSleep` or `PreventUserIdleDisplaySleep`, spawns your command via `Process`, waits for it to exit, then releases the assertion. Notifications use `osascript` so there are zero runtime dependencies.

You can verify it's working while a command runs:

```sh
pmset -g assertions | grep wake
```

## Credits

- Apple's [`caffeinate(8)`](x-man-page://caffeinate) — the original and still the default. `wake` is a love letter, not a replacement.
- The `IOPMAssertion` family of APIs in `IOKit.pwr_mgt`.

## License

MIT — see [LICENSE](LICENSE).
