{
  description = "EXWM Firefox URL lookup via bruvtab (Emacs package)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    # Single formatter entry point for the repo: `nix fmt' formats every
    # tracked file with the configured programs.
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    # The CLI the package shells out to.  Its nixpkgs follows ours so the
    # closure stays small and versions agree.
    bruvtab = {
      url = "github:pschmitt/bruvtab";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs,
      treefmt-nix,
      bruvtab,
      ...
    }:
    let
      # Date of the last commit as YYYY-MM-DD, folded into the version
      # string.  Flake source info gives it as e.g. "20260922133522";
      # slice out the year, month and day.  A plain path import has no
      # git metadata, so fall back to the epoch instead of failing.
      sourceInfo = inputs.self.sourceInfo or { };
      lastModifiedDate = sourceInfo.lastModifiedDate or "19700101000000";
      commitDate = "${builtins.substring 0 4 lastModifiedDate}-${
        builtins.substring 4 2 lastModifiedDate
      }-${builtins.substring 6 2 lastModifiedDate}";
      version = "0.1.0-unstable-${commitDate}";

      # checkdoc and package-lint catch style and packaging problems that
      # byte-compilation does not.  Keep this in `checks', not in the
      # package: lint findings must not block an otherwise buildable
      # package forever.
      mkLint =
        { pkgs, src }:
        pkgs.runCommand "emacs-bruvtab-lint"
          {
            nativeBuildInputs = [
              (pkgs.emacsPackages.emacsWithPackages (epkgs: [ epkgs.package-lint ]))
              # Makes $HOME a writable copy of $TMPDIR.  Emacs and
              # package-lint both write into the home directory.
              pkgs.writableTmpDirAsHomeHook
            ];
            inherit src;
            meta.description = "emacs-bruvtab checkdoc and package-lint checks";
          }
          ''
            cp "$src/bruvtab.el" .

            # package-lint exits non-zero on any finding.  The package has
            # no external dependencies, so it needs no package-alist stubs.
            emacs --batch -l package-lint -f package-lint-batch-and-exit bruvtab.el

            # checkdoc exits 0 even when it reports problems, so gate on
            # output.
            doc=$(emacs --batch -l checkdoc \
              --eval '(checkdoc-file "bruvtab.el")' 2>&1)
            if [ -n "$doc" ]; then
              printf '%s\n' "$doc"
              exit 1
            fi

            touch $out
          '';
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ treefmt-nix.flakeModule ];

      # Emacs packages are pure Elisp: no ELF binaries, so evaluate on
      # every Linux arch.
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
          # The package stays overridable, so a consumer can swap the
          # Emacs, the CLI or the source:
          #   inputs.bruvtab.packages.${system}.bruvtab.override {
          #     emacs = pkgs.emacs-nox;
          #   }
          # The flake passes the commit-derived version, because a plain
          # import of the expression cannot know it.
          bruvtabEmacs = pkgs.lib.makeOverridable (
            {
              # One Emacs package set supplies the build, so an override
              # of this argument moves every dependency with it.
              emacs ? pkgs.emacs,
              emacsPackages ? pkgs.emacsPackagesFor emacs,
              melpaBuild ? emacsPackages.melpaBuild,
              # The CLI the default `bruvtab-program' value points at.
              # The upstream flake lacks `meta.mainProgram', so name the
              # executable explicitly.
              bruvtabCli ? bruvtab.packages.${system}.bruvtab,
              src ? pkgs.lib.cleanSource ./.,
              version ? "0.1.0",
            }:
            melpaBuild {
              pname = "bruvtab";
              inherit version;

              # `./.' is the repository root.  cleanSource drops VCS
              # metadata and editor backup files, so only real package
              # sources enter the store.
              inherit src;

              # Point the default program at the store path of the CLI.
              postPatch = ''
                substituteInPlace bruvtab.el \
                  --replace-fail 'bruvtab-program "bruvtab"' 'bruvtab-program "${lib.getExe' bruvtabCli "bruvtab"}"'
              '';

              # A byte-compile warning fails the build.  This is the
              # cheapest lint the package gets, and it keeps the source
              # warning-free.
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
            }
          ) { inherit version; };
        in
        {
          packages = {
            bruvtab = bruvtabEmacs;
            default = config.packages.bruvtab;
          };

          checks = {
            # melpaBuild byte-compiles with warnings as errors, so the
            # package is the check.
            default = bruvtabEmacs;
            lint = pkgs.callPackage mkLint { inherit (bruvtabEmacs) src; };
          };

          devShells.default = pkgs.mkShell {
            packages = [
              # The CLI under development, plus a real Emacs for
              # interactive testing of the package.
              bruvtab.packages.${system}.bruvtab
              pkgs.emacs
              config.treefmt.build.wrapper
            ];
          };

          # nixfmt only.  Elisp has no formatter in this stack, so the
          # sources stay untouched and checkdoc/package-lint guard style.
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
          };
        };
    };
}
