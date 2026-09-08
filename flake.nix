{
  description = "EXWM Firefox URL lookup via bruvtab (Emacs package)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    bruvtab = {
      url = "github:pschmitt/bruvtab";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      bruvtab,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          system,
          pkgs,
          lib,
          config,
          ...
        }:
        let
          inherit (pkgs.emacsPackages) melpaBuild;
          bruvtabCli = bruvtab.packages.${system}.bruvtab;
        in
        {
          packages.bruvtab = melpaBuild {
            pname = "bruvtab";
            version = "0.1.0-unstable-2026-08-19";

            src = lib.cleanSource ./.;

            postPatch = ''
              substituteInPlace bruvtab.el \
                --replace-fail 'bruvtab-program "bruvtab"' 'bruvtab-program "${
                  lib.getExe' bruvtabCli "bruvtab"
                }"'
            '';

            turnCompilationWarningToError = true;

            meta = {
              description = "URL lookup for EXWM Firefox windows via bruvtab";
              longDescription = ''
                bruvtab is glue between EXWM X11 windows and the bruvtab/brotab
                `--json' commands.  Given an EXWM buffer that is a Firefox window,
                it returns the URL of the active tab by joining the EXWM window
                title with bruvtab's active-tab list.  The default backend talks
                HTTP directly to the running bruvtab mediator; a `cli' backend
                shells out to the bruvtab executable instead.
              '';
              license = lib.licenses.agpl3Plus;
              homepage = "https://github.com/nagy/emacs-bruvtab";
              maintainers = with lib.maintainers; [ nagy ];
              platforms = lib.platforms.linux;
            };
          };

          packages.default = config.packages.bruvtab;

          devShells.default = pkgs.mkShell {
            packages = [ bruvtabCli ];
          };
        };
    };
}
