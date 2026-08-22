{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
  bruvtab ?
    (builtins.getFlake "github:pschmitt/bruvtab")
    .packages.${pkgs.stdenv.hostPlatform.system}
    .bruvtab,
}:

melpaBuild {
  pname = "bruvtab";
  version = "0.1.0-unstable-2026-08-19";

  src = lib.cleanSource ./.;

  postPatch = ''
    substituteInPlace bruvtab.el \
      --replace-fail 'bruvtab-program "bruvtab"' 'bruvtab-program "${lib.getExe' bruvtab "bruvtab"}"'
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
    platforms = lib.platforms.unix;
  };
}