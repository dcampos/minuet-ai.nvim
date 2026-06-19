#!/usr/bin/env bash
# Screenshot a duet preview fixture via tmux + freeze, fully headless: no
# compositor, no browser, no GPU. nvim runs in a detached tmux pane; we dump the
# rendered grid (with color escapes) via capture-pane and render it to PNG with
# charm/freeze.
#
# The crux of "truecolor in tmux": tmux downsamples 24-bit color to 256 unless
# told the terminal has RGB, so we force terminal-features RGB in the conf.
#
#   nix shell nixpkgs#tmux nixpkgs#charm-freeze -c bash shot_tmux.sh [fixture]
#   (NB: nixpkgs#freeze is an unrelated shellcode tool; we want charm-freeze.)
#
# Output: out/<fixture>.tmux.png
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HARNESS_DIR/../../.." && pwd)"
FIXTURE="${1:-word_swap}"

export MINUET_REPO="$REPO"
export MINUET_FIXTURE="$FIXTURE"
export XDG_DATA_HOME="$HARNESS_DIR/.state/data"
export XDG_STATE_HOME="$HARNESS_DIR/.state/state"
export XDG_CACHE_HOME="$HARNESS_DIR/.state/cache"
export XDG_CONFIG_HOME="$HARNESS_DIR/.state/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$HARNESS_DIR/out" "$HARNESS_DIR/.state"

# Prewarm tokyonight once.
nvim --headless -u "$HARNESS_DIR/init.lua" -c 'qa!' >/dev/null 2>&1 || true

CONF="$HARNESS_DIR/.state/tmux.conf"
cat > "$CONF" <<'EOF'
set -g default-terminal "tmux-256color"
set -as terminal-features ",*:RGB"
set -g status off
set -g mouse off
EOF

SOCK="duetharness-$$"
DUMP="$HARNESS_DIR/.state/${FIXTURE}.ansi"
OUT="$HARNESS_DIR/out/${FIXTURE}.tmux.png"

tmux -L "$SOCK" -f "$CONF" new-session -d -x 100 -y 16 \
    -e MINUET_REPO="$REPO" \
    -e MINUET_FIXTURE="$FIXTURE" \
    -e TERM=tmux-256color \
    -e COLORTERM=truecolor \
    "nvim -u '$HARNESS_DIR/init.lua'"

sleep 3.5
tmux -L "$SOCK" capture-pane -p -e > "$DUMP"
tmux -L "$SOCK" kill-server 2>/dev/null || true

# freeze renders with its bundled font (JetBrains Mono). Passing an arbitrary
# --font.family that fontconfig can't resolve in this env yields blank glyphs
# (bg fills only), so we keep the default; use shot_cage.sh for exact-font
# fidelity to the user's terminal.
freeze "$DUMP" --output "$OUT" --font.size 16
# capture-pane emits the full grid (trailing blank rows). Trim the uniform
# border so the PNG is tight; +repage resets the virtual canvas.
magick "$OUT" -trim +repage "$OUT" 2>/dev/null || true
echo "wrote $OUT"
