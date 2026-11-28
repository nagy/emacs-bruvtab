{
  description = "EXWM Firefox URL lookup via bruvtab (Emacs package)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      # One nixpkgs closure: the formatter shares our package set.
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The house Emacs package build, ERT run, lint gate and formatter.
    common.url = "github:nagy/common";
    # The CLI the package shells out to. Its nixpkgs follows ours so the
    # closure stays small and versions agree.
    bruvtab = {
      url = "github:pschmitt/bruvtab";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      treefmt-nix,
      common,
      bruvtab,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        treefmt-nix.flakeModule
        common.flakeModules.treefmt
        common.flakeModules.emacs
      ];

      systems = [ "x86_64-linux" ];

      perSystem =
        { lib, system, ... }:
        {
          # Version, description, licence, homepage and maintainers come from
          # the header of bruvtab.el. The ERT suite in `test/` runs inside the
          # package build, so `nix flake check` runs it.
          nagy.emacs = {
            enable = true;
            src = ./.;
            name = "bruvtab";

            # `bruvtab` is not a nixpkgs attribute, so a
            # `;; NIX-EMACS-PROGRAM:` annotation cannot name it. Rewrite the
            # default to the store path of the CLI input instead; the
            # `cli` backend then works without the executable on `$PATH`.
            postPatch = ''
              substituteInPlace bruvtab.el \
                --replace-fail 'bruvtab-program "bruvtab"' \
                  'bruvtab-program "${lib.getExe' bruvtab.packages.${system}.bruvtab "bruvtab"}"'
            '';

            # The CLI the `cli` backend drives, for interactive testing.
            devShell.extraPackages = [ bruvtab.packages.${system}.bruvtab ];
          };
        };
    };
}
