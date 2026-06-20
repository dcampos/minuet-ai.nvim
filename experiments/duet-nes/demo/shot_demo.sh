#!/usr/bin/env bash
# Screenshot a demo state via a HEADLESS wlroots compositor (cage) + foot (real
# Wayland terminal, true color) + grim -- the same high-fidelity, GPU-free path
# the visual harness uses. It loads the demo, opens a scenario, replays a key
# sequence, then grabs the frame. No model, no network (after the first run).
#
#   nix shell nixpkgs#cage nixpkgs#foot nixpkgs#grim nixpkgs#git \
#       -c bash shot_demo.sh <scenario> [keys] [tag]
#
#   scenario : 1-based scenario number (see scenarios.lua)
#   keys     : replay string, chars in {n=<CR>, t=<Tab>, b=<BS>} (default none)
#   tag      : output basename (default: s<scenario>_<keys>)
#
# Output: out/<tag>.png
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DEMO_DIR/../../.." && pwd)"
SCENARIO="${1:-1}"
KEYS="${2:-}"
TAG="${3:-s${SCENARIO}${KEYS:+_$KEYS}}"

export MINUET_REPO="$REPO"
export MINUET_DEMO_SCENARIO="$SCENARIO"
export MINUET_DEMO_KEYS="$KEYS"
export XDG_DATA_HOME="$DEMO_DIR/.state/data"
export XDG_STATE_HOME="$DEMO_DIR/.state/state"
export XDG_CACHE_HOME="$DEMO_DIR/.state/cache"
export XDG_CONFIG_HOME="$DEMO_DIR/.state/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$DEMO_DIR/out"

# Prewarm tokyonight once (network only on first run).
nvim --headless -u "$DEMO_DIR/init.lua" -c 'qa!' >/dev/null 2>&1 || true

OUT="$DEMO_DIR/out/${TAG}.png"
LOG="$DEMO_DIR/.state/cage_${TAG}.log"

INNER="$DEMO_DIR/.state/cage_inner_${TAG}.sh"
cat > "$INNER" <<EOF
#!/usr/bin/env bash
set -e
foot --log-level=error \
     --font="DejaVu Sans Mono:size=16" \
     -e nvim -u "$DEMO_DIR/init.lua" &
FOOT_PID=\$!
sleep 3.5
grim "$OUT"
kill \$FOOT_PID 2>/dev/null || true
sleep 0.2
EOF
chmod +x "$INNER"

WLR_BACKENDS=headless \
WLR_RENDERER=pixman \
WLR_LOG=error \
WLR_LIBINPUT_NO_DEVICES=1 \
WLR_HEADLESS_OUTPUTS=1 \
LIBGL_ALWAYS_SOFTWARE=1 \
    cage -- "$INNER" >"$LOG" 2>&1 || {
        cat "$LOG" >&2
        exit 1
    }

echo "wrote $OUT"
