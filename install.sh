#!/usr/bin/env bash
# wake installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mcdeeai/wake/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/mcdeeai/wake/main/install.sh | bash -s -- --clamshell
#
# What it does:
#   1. Clones (or updates) the repo into ~/.local/share/wake/src
#   2. Builds with `swift build -c release`
#   3. Installs the binary to /usr/local/bin/wake (prompts once for sudo)
#   4. With --clamshell: also runs `sudo wake clamshell setup`

set -euo pipefail

REPO_URL="https://github.com/mcdeeai/wake.git"
SRC_DIR="${HOME}/.local/share/wake/src"
BIN_DIR="/usr/local/bin"
DO_CLAMSHELL=0

for arg in "$@"; do
    case "$arg" in
        --clamshell) DO_CLAMSHELL=1 ;;
        -h|--help)
            sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "wake is macOS-only." >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "wake needs Swift. Install Xcode or the Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

mkdir -p "$(dirname "$SRC_DIR")"
if [[ -d "$SRC_DIR/.git" ]]; then
    echo "==> Updating $SRC_DIR"
    git -C "$SRC_DIR" pull --ff-only
else
    echo "==> Cloning into $SRC_DIR"
    git clone --depth 1 "$REPO_URL" "$SRC_DIR"
fi

echo "==> Building (release)"
( cd "$SRC_DIR" && swift build -c release )

BUILT="$SRC_DIR/.build/release/wake"
if [[ ! -x "$BUILT" ]]; then
    echo "build did not produce $BUILT" >&2
    exit 1
fi

echo "==> Installing to $BIN_DIR/wake (sudo)"
sudo install -m 0755 "$BUILT" "$BIN_DIR/wake"

echo
echo "✓ wake installed: $(wake --help | head -n 1)"

if [[ "$DO_CLAMSHELL" -eq 1 ]]; then
    echo
    echo "==> Setting up clamshell mode (sudo)"
    sudo wake clamshell setup
fi

cat <<EOF

Try it:
  wake run --notify -- sleep 5

For lid-closed mode (one-time):
  sudo wake clamshell setup
  wake run --clamshell --notify -- sleep 60

Re-run this installer anytime to update.
EOF
