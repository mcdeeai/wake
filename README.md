# wake

A tiny macOS CLI that keeps your Mac awake while a command runs, then optionally pings you when it's done.

```sh
# Just works. Notification when done. Lid-closed mode if it's set up.
wake run -- codex
wake run -- npm run build

# Quiet, no notification
wake run -q -- cargo build --release

# Smoke test (close the lid, wait, get a notification)
wake test 30
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

- **Convenient defaults** — notifications on, clamshell mode on (if set up). The common case is just `wake run -- cmd`. Use `--quiet` / `-q` to silence, `--no-clamshell` to skip lid-closed mode for one run.
- **`--display`** — keep the display awake too (equivalent to `caffeinate -d`).
- **`--clamshell`** — *close your laptop and walk away.* Auto-enabled when set up; pass explicitly to **require** it (errors out if `wake clamshell setup` hasn't been run). See [Closing the lid](#closing-the-lid-aka-clamshell-mode).
- **`wake test [seconds]`** — built-in smoke test. Runs `sleep N` under wake so you can close the lid, walk to the kitchen, and confirm the notification fires when you come back.
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
wake run [options] -- <command> [args...]
wake test [seconds]               # smoke test (defaults to 30s)

wake clamshell setup              # one-time install (requires sudo)
wake clamshell uninstall          # remove sudoers + watchdog (requires sudo)
wake clamshell status             # show clamshell setup state
```

**Defaults:** notifications on, clamshell mode auto-on if set up.

| Flag | Meaning |
| --- | --- |
| `--quiet`, `-q` | Don't show a notification when finished |
| `--display` | Also prevent display sleep |
| `--clamshell` | Require clamshell mode (error if not set up) |
| `--no-clamshell` | Skip clamshell mode for this run, even if set up |
| `--reason TEXT` | Reason shown in `pmset -g assertions` (default: `wake CLI session`) |
| `--` | Optional separator before the command |

The `--` is optional but recommended if your command has flags that look like `wake`'s own flags.

### Examples

```sh
# Local coding agent — get pinged when it's done thinking
wake run -- codex
wake run -- claude
wake run -- amp

# Long build (notification fires when it finishes)
wake run -- pnpm build

# Same, but quiet
wake run -q -- pnpm build

# Keep the screen on for a presentation script
wake run --display -- ./demo.sh

# Force clamshell — fail loudly if it's not set up
wake run --clamshell -- codex

# Smoke test the install
wake test          # 30s
wake test 60       # 60s
```

### Closing the lid (a.k.a. clamshell mode)

The default `wake run` only prevents *idle* sleep. To keep the system awake with the **lid closed** (no external display required), there's `--clamshell`:

```sh
# One-time install (writes a scoped sudoers fragment + a launchd watchdog)
sudo wake clamshell setup

# Then, forever after:
wake run -- codex
```

Once setup is done, `--clamshell` is automatic — every `wake run` will keep the system awake with the lid closed. Pass `--no-clamshell` to skip it for one run, or `--clamshell` explicitly to error out if setup is missing (useful in scripts where you want a guarantee).

Close your laptop, walk away, and Codex (or whatever) keeps running. When it finishes, the default notification fires — open the lid and see it waiting.

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
