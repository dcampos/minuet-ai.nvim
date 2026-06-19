{
  description = "Visual harness for the duet NES preview renderer: screenshot nvim highlight output (vhs / headless wlroots).";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # Capture toolchain only. We deliberately do NOT ship neovim here: the
      # harness uses the system nvim so it inherits the user's bundled
      # treesitter parser set + runtime queries (a vanilla pkgs.neovim would
      # not have them). Plugins (tokyonight) come from nvim's built-in vim.pack.
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            # NB: vhs is intentionally NOT here. The pinned nixpkgs ships a
            # vhs/ttyd/chromium combo that fails with ERR_CONNECTION_REFUSED;
            # shot_vhs.sh self-manages vhs via `nix shell nixpkgs#vhs` instead.
            cage # single-app wlroots compositor (headless, pixman, no GPU)
            foot # wayland-native terminal, true color
            grim # wlroots screenshotter
            slurp # region select (optional cropping)
            wl-clipboard
            wtype # wayland virtual-keyboard input injection
            tmux # truecolor-in-tmux capture angle
            charm-freeze # ANSI/code -> PNG/SVG (tmux capture-pane path); binary is `freeze`. NB: nixpkgs `freeze` is an unrelated shellcode tool.
            imagemagick # crop/trim/convert screenshots
            luajit
            luarocks # per project convention: flake-managed lua deps
            git
            jq
          ];
          shellHook = ''
            echo "duet visual harness: nvim=$(command -v nvim)  ($(nvim --version | head -1))"
            echo "  bash shot_vhs.sh  <fixture>   # self-contained"
            echo "  bash shot_cage.sh <fixture>   # headless wlroots, highest fidelity"
          '';
        };
      });

      # nix run .#shot -- <vhs|cage> <fixture>
      # Resolves the harness via git worktree (not the immutable store path) so
      # the scripts' MINUET_REPO/REPO resolution stays correct.
      apps = forAll (pkgs:
        let
          shot = pkgs.writeShellApplication {
            name = "duet-shot";
            runtimeInputs = with pkgs; [ cage foot grim imagemagick tmux charm-freeze git ];
            text = ''
              approach="''${1:-vhs}"
              fixture="''${2:-word_swap}"
              dir="$(git rev-parse --show-toplevel)/experiments/duet-nes/visual-harness"
              case "$approach" in
                vhs)  bash "$dir/shot_vhs.sh"  "$fixture" ;;
                cage) bash "$dir/shot_cage.sh" "$fixture" ;;
                *) echo "unknown approach: $approach (use vhs|cage)" >&2; exit 1 ;;
              esac
            '';
          };
        in
        {
          shot = { type = "app"; program = "${shot}/bin/duet-shot"; };
          default = { type = "app"; program = "${shot}/bin/duet-shot"; };
        });
    };
}
