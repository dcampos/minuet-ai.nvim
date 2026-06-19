#!/usr/bin/env bash
# Screenshot a duet preview fixture via VHS (self-contained terminal -> PNG).
#
#   bash shot_vhs.sh [fixture]
#
# Self-contained: it invokes vhs via `nix shell nixpkgs#vhs` (the registry rev,
# which works) rather than the flake devShell. The flake's pinned nixpkgs ships a
# vhs/ttyd/chromium combination that fails with ERR_CONNECTION_REFUSED, and VHS
# offers no fidelity edge over shot_cage.sh, so it is kept out of the flake.
#
# Output: out/<fixture>.png
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HARNESS_DIR/../../.." && pwd)"
FIXTURE="${1:-word_swap}"

export MINUET_REPO="$REPO"
export MINUET_FIXTURE="$FIXTURE"

# Isolate nvim state so the harness never touches the user's real nvim data.
export XDG_DATA_HOME="$HARNESS_DIR/.state/data"
export XDG_STATE_HOME="$HARNESS_DIR/.state/state"
export XDG_CACHE_HOME="$HARNESS_DIR/.state/cache"
export XDG_CONFIG_HOME="$HARNESS_DIR/.state/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$HARNESS_DIR/out"

# Prewarm: install tokyonight via vim.pack once (network on first run only).
nvim --headless -u "$HARNESS_DIR/init.lua" -c 'qa!' >/dev/null 2>&1 || true

OUT="$HARNESS_DIR/out/${FIXTURE}.png"
TAPE="$HARNESS_DIR/.state/${FIXTURE}.tape"

cat > "$TAPE" <<EOF
Output "${HARNESS_DIR}/.state/${FIXTURE}.gif"
Set Shell "bash"
Set FontFamily "DejaVu Sans Mono"
Set FontSize 18
Set Width 1500
Set Height 760
Set Padding 14
Hide
Type "MINUET_REPO='${REPO}' MINUET_FIXTURE='${FIXTURE}' nvim -u '${HARNESS_DIR}/init.lua'"
Enter
Sleep 3.5s
Show
Screenshot "${OUT}"
Sleep 300ms
EOF

nix shell nixpkgs#vhs -c vhs "$TAPE"
echo "wrote $OUT"
