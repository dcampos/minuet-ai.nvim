#!/usr/bin/env bash
# Screenshot a duet preview fixture via a HEADLESS wlroots compositor (cage) +
# foot (real Wayland terminal, true color, real font) + grim. Highest fidelity:
# renders with the actual terminal + font + colorscheme, no GPU required
# (pixman software renderer), and never touches the user's visible session.
#
#   nix shell nixpkgs#cage nixpkgs#foot nixpkgs#grim -c bash shot_cage.sh [fixture]
#
# Output: out/<fixture>.cage.png
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HARNESS_DIR/../../.." && pwd)"
FIXTURE="${1:-word_swap}"

# Optional nvim driver override (default init.lua); relative paths resolve
# against the harness dir. MINUET_TAG suffixes the output filename.
INIT="${MINUET_INIT:-init.lua}"
case "$INIT" in /*) : ;; *) INIT="$HARNESS_DIR/$INIT" ;; esac
TAG="${MINUET_TAG:+.$MINUET_TAG}"

export MINUET_REPO="$REPO"
export MINUET_FIXTURE="$FIXTURE"
export XDG_DATA_HOME="$HARNESS_DIR/.state/data"
export XDG_STATE_HOME="$HARNESS_DIR/.state/state"
export XDG_CACHE_HOME="$HARNESS_DIR/.state/cache"
export XDG_CONFIG_HOME="$HARNESS_DIR/.state/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$HARNESS_DIR/out"

# Prewarm tokyonight once (network only on first run).
nvim --headless -u "$INIT" -c 'qa!' >/dev/null 2>&1 || true

OUT="$HARNESS_DIR/out/${FIXTURE}${TAG}.cage.png"

# Inner client: cage launches this once; it owns the headless wayland session.
# It runs foot+nvim, waits for the render, grabs the frame, then exits (which
# tears the compositor down).
INNER="$HARNESS_DIR/.state/cage_inner_${FIXTURE}.sh"
cat > "$INNER" <<EOF
#!/usr/bin/env bash
set -e
foot --font="DejaVu Sans Mono:size=16" \
     -e nvim -u "$INIT" &
FOOT_PID=\$!
sleep 3.5
grim "$OUT"
kill \$FOOT_PID 2>/dev/null || true
sleep 0.2
EOF
chmod +x "$INNER"

# Headless wlroots: software renderer, no input devices, virtual 1500x800 output.
WLR_BACKENDS=headless \
WLR_RENDERER=pixman \
WLR_LIBINPUT_NO_DEVICES=1 \
WLR_HEADLESS_OUTPUTS=1 \
LIBGL_ALWAYS_SOFTWARE=1 \
    cage -- "$INNER"

echo "wrote $OUT"
