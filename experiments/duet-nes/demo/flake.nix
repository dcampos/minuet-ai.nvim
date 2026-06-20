{
  description = "Standalone, model-free demo of minuet's duet NES (next-edit-suggestion) preview.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # Like the visual harness, we deliberately do NOT ship neovim: the demo
      # uses the *system* nvim so it inherits the bundled treesitter parser set
      # (lua is what the scenarios use) and the 0.12 `vim.pack` package manager,
      # which a vanilla pkgs.neovim may predate. The flake provides git (vim.pack
      # clones the colorscheme over it) and the launcher.
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ git ];
          shellHook = ''
            echo "duet NES demo: nvim=$(command -v nvim)  ($(nvim --version | head -1))"
            echo "  nix run path:\$PWD#demo       # launch the demo (isolated nvim state)"
            echo "  nix run path:\$PWD#demo -- 3  # open at scenario 3"
            echo "  or directly: nvim -u init.lua"
          '';
        };
      });

      # nix run .#demo [-- <scenario-number>]
      # Isolated nvim state under ./.state so the demo never touches the user's
      # real ~/.config/nvim; tokyonight installs there via vim.pack on first run.
      apps = forAll (pkgs:
        let
          demo = pkgs.writeShellApplication {
            name = "duet-nes-demo";
            runtimeInputs = with pkgs; [ git ];
            text = ''
              if ! command -v nvim >/dev/null; then
                echo "error: neovim (>= 0.12, for vim.pack) must be on PATH" >&2
                exit 1
              fi
              dir="$(git rev-parse --show-toplevel)/experiments/duet-nes/demo"
              export XDG_DATA_HOME="$dir/.state/data"
              export XDG_STATE_HOME="$dir/.state/state"
              export XDG_CACHE_HOME="$dir/.state/cache"
              export XDG_CONFIG_HOME="$dir/.state/config"
              mkdir -p "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
              if [ -n "''${1:-}" ]; then export MINUET_DEMO_SCENARIO="$1"; fi
              exec nvim -u "$dir/init.lua"
            '';
          };
        in
        {
          demo = { type = "app"; program = "${demo}/bin/duet-nes-demo"; };
          default = { type = "app"; program = "${demo}/bin/duet-nes-demo"; };
        });
    };
}
