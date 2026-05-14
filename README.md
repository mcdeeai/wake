# wake

A tiny macOS CLI that keeps your Mac awake while a command runs, then optionally pings you when it's done.

```sh
wake run -- npm run build
wake run --notify -- cargo build --release
wake run --notify --display --reason "training run" -- python train.py

# Close your laptop and walk away (one-time: `sudo wake clamshell setup`)
wake run --clamshell --notify -- codex
```

## Why does this exist?

Because people are propping their laptop lids open with books so [Codex](https://openai.com/codex), [Claude Code](https://www.anthropic.com/claude-code), [Amp](https://ampcode.com), and other local agents don't get killed by idle sleep. There's a better way.

> "Are people still leaving their laptops open? In this day and age? 🤔"

Yes. Local coding agents have real advantages over cloud ones — they read your actual filesystem, run your actual toolchain, respect your actual secrets, and don't bill per token of context. The trade-off is that they need a live machine. `wake` is the small thing that keeps that machine live.

macOS already ships with [`caffeinate(8)`](x-man-page://caffeinate), and you should know about it:

```sh
caffeinate -i npm run build
```

That covers the 90% case. `wake` is a thin convenience wrapper around the same `IOPMAssertion` API that `caffeinate` uses, with a few extras I kept reaching for:

- **`--notify`** — desktop notification when the command finishes, with elapsed time and exit status. No more tabbing back to a terminal to check if your build is done.
- **`--display`** — keep the display awake too (equivalent to `caffeinate -d`), but spelled in a way I can remember.
- **`--clamshell`** — *close your laptop and walk away.* Keeps the system awake with the lid closed, no external display required. Needs a one-time `sudo wake clamshell setup`; see [Closing the lid](#closing-the-lid-aka-clamshell-mode).
- **`--reason TEXT`** — labels the power assertion so it shows up clearly in `pmset -g assertions`. Helpful when you're auditing what's keeping your machine awake.
- **Signal forwarding** — `Ctrl-C`, `SIGTERM`, `SIGHUP`, `SIGQUIT` are forwarded to the child process, so it cleans up properly.
- **Exit code passthrough** — `wake` exits with the same status as the wrapped command, so it composes in shell pipelines and CI.

If `caffeinate` does what you need, use `caffeinate`. If you want notifications and a slightly friendlier interface, try `wake`.

## Install

Requires macOS 11+ and Swift 5.9+ (ships with Xcode / Command Line Tools).

**One-liner (recommended):**

```sh
curl -fsSL https://raw.githubusercontent.com/mcdeeai/wake/main/install.sh | bash
```

Add `-s -- --clamshell` to also do the one-time clamshell setup:

```sh
curl -fsSL https://raw.githubusercontent.com/mcdeeai/wake/main/install.sh | bash -s -- --clamshell
```

The installer clones into `~/.local/share/wake/src`, builds with `swift build -c release`, and installs the binary to `/usr/local/bin/wake` (one sudo prompt). Re-run it anytime to update. Read [`install.sh`](install.sh) before piping anything to bash, obviously.

**Or, from a clone:**

```sh
git clone https://github.com/mcdeeai/wake.git
cd wake
make install                  # build + sudo-install to /usr/local/bin
make clamshell-setup          # optional: enable lid-closed mode
```

**Manually:**

```sh
swift build -c release
sudo install .build/release/wake /usr/local/bin/wake
```

## Usage

```
wake run [--notify] [--display] [--clamshell] [--reason TEXT] -- <command> [args...]

wake clamshell setup        # one-time install (requires sudo)
wake clamshell uninstall    # remove sudoers + watchdog (requires sudo)
wake clamshell status       # show clamshell setup state
```

| Flag | Meaning |
| --- | --- |
| `--notify` | Show a notification when the command finishes |
| `--display` | Also prevent display sleep |
| `--clamshell` | Also keep system awake when the lid is closed (requires setup) |
| `--reason TEXT` | Reason shown in `pmset -g assertions` (default: `wake CLI session`) |
| `--` | Optional separator before the command |

The `--` is optional but recommended if your command has flags that look like `wake`'s own flags.

### Examples

```sh
# Local coding agent — get pinged when it's done thinking
wake run --notify -- codex
wake run --notify -- claude
wake run --notify -- amp

# Long build, notify me when done
wake run --notify -- pnpm build

# Keep the screen on for a presentation script
wake run --display -- ./demo.sh

# Tag your assertion so you can find it in pmset
wake run --reason "nightly export" -- ./export.sh
```

### Closing the lid (a.k.a. clamshell mode)

The default `wake run` only prevents *idle* sleep. To keep the system awake with the **lid closed** (no external display required), there's `--clamshell`:

```sh
# One-time install (writes a scoped sudoers fragment + a launchd watchdog)
sudo wake clamshell setup

# Then, forever after:
wake run --clamshell --notify -- codex
```

Now you can close your laptop, walk away, and Codex (or whatever) keeps running. When it finishes, `--notify` will fire a notification — open the lid and see it waiting.

#### How it works (and what it touches)

There's no public IOKit assertion for clamshell sleep, so under the hood `--clamshell` toggles the system-wide `pmset -a disablesleep` flag for the duration of your command. To do that without prompting for a password every run, `wake clamshell setup` installs three things:

| Path | Why |
| --- | --- |
| `/etc/sudoers.d/wake` | NOPASSWD entry for *exactly* `pmset -a disablesleep 0` and `pmset -a disablesleep 1` — nothing else |
| `/usr/local/libexec/wake-watchdog.sh` | A 30-second watchdog that re-enables sleep if `wake` ever dies without cleaning up (kill -9, panic, power loss) |
| `/Library/LaunchDaemons/com.mcdeeai.wake.watchdog.plist` | launchd plist that runs the watchdog as root |

`wake` itself uses a per-PID marker directory at `/tmp/wake-clamshell.d/` and a `flock`-based critical section so multiple concurrent `wake --clamshell` runs cooperate cleanly: the first one flips `disablesleep` on, the last one flips it off. The watchdog is the safety net.

To inspect or remove:

```sh
wake clamshell status       # shows installed state and current pmset value
sudo wake clamshell uninstall
```

#### Honest caveats

- `disablesleep` is system-wide. While `--clamshell` is active, your Mac will not sleep for *any* reason. The display will turn off when you close the lid, but the machine is fully running.
- The sudoers fragment is mildly trust-asking: you're letting `wake` flip a system setting silently. It's scoped to two exact `pmset` invocations and nothing else, but read it before you install.
- Apple-Silicon-specific quirks have been reported with `pmset disablesleep` in some macOS versions. Test on your hardware before relying on it.
- For a fully GUI-managed alternative, [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704) is excellent.

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
