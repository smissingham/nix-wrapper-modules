{
  config,
  lib,
  wlib,
  pkgs,
  ...
}:
let
  inherit (config)
    binName
    outputName
    package
    ;

  isDerivation = builtins.isAttrs package && package ? outPath;

  # `.app` bundles shipped by the package which contain an executable
  # named like `binName` inside `Contents/MacOS/`.
  #
  # Detection reads the package's store path, so it only succeeds when the
  # package is already present in the local store. On a cold store this
  # returns `[]` and the module stays dormant until the package has been
  # built once. Users may set `appBundles.bundles` explicitly to bypass
  # detection.
  #
  # `builtins.pathExists` is used to guard every `builtins.readDir`, since
  # a missing path makes `readDir` throw an error which `tryEval` cannot
  # catch.
  detectedBundles =
    let
      packageRoot = package.${outputName} or package;
      rootEntries =
        if isDerivation && binName != null && builtins.pathExists packageRoot then
          builtins.readDir packageRoot
        else
          { };
      hasApplications = (rootEntries.Applications or null) == "directory";
      appsRoot = packageRoot + "/Applications";
      appEntries = if hasApplications then builtins.readDir appsRoot else { };
      appNames = builtins.filter (app: appEntries.${app} == "directory") (builtins.attrNames appEntries);
      hasMatchingExecutable = app: builtins.pathExists (appsRoot + "/${app}/Contents/MacOS/${binName}");
    in
    map (app: "Applications/${app}") (builtins.filter hasMatchingExecutable appNames);

  cfg = config.appBundles;

  # The `binary` wrapper implementation cannot represent shell-only
  # features. Wrappers which rely on them keep the default (shell) wrapper,
  # and bundle handling stays off, since a shell script cannot be used as a
  # bundle executable.
  hasShellOnlyFeatures =
    let
      argv0type = config.argv0type or "inherit";
    in
    builtins.isFunction argv0type
    || (builtins.isAttrs argv0type && argv0type ? __functor)
    || config.runShell or [ ] != [ ]
    || config.prefixContent or [ ] != [ ]
    || config.suffixContent or [ ] != [ ];
in
{
  imports = [ wlib.modules.makeWrapper ];

  options.appBundles = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = (pkgs.stdenv.hostPlatform.isDarwin or false) && detectedBundles != [ ];
      description = ''
        Whether to wrap the macOS `.app` bundles shipped by `config.package`.

        When enabled, and a matching bundle is found, the wrapper binary is
        placed inside each bundle's `Contents/MacOS/` directory, so launching
        the app via Finder, Spotlight, or the Dock runs the wrapped binary
        instead of the unwrapped original
        (see nix-wrapper-modules issue #587).

        The wrapper also targets the bundle's executable, so processes launched
        through `bin/` are recognized by LaunchServices as belonging to the
        `.app` bundle and get the real application icon instead of a generic
        executable icon.

        Detection requires the package to be present in the local store, so on
        a cold store this stays off until the package has been built once. Set
        `appBundles.bundles` explicitly to opt in without detection.

        Wrappers which rely on shell-only wrapper features (`argv0type`
        functions, `runShell`, `prefixContent`, `suffixContent`) keep the
        shell wrapper and get no bundle handling, since a shell script cannot
        be used as a bundle executable.
      '';
    };
    bundles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = detectedBundles;
      description = ''
        Paths (relative to the package root) of the `.app` bundles to wrap,
        i.e. `Applications/Alacritty.app`.

        Defaults to every bundle shipped by the package whose
        `Contents/MacOS/` directory contains an executable named like
        `config.binName`. Only that executable is replaced within each bundle,
        helper executables are left untouched.

        The first bundle in this list is also used as the wrap target
        (`config.exePath`) so that the final process runs from inside a
        `.app` bundle.
      '';
    };
  };

  config = lib.mkMerge [
    {
      meta.maintainers = [ wlib.maintainers.smissingham ];
      meta.description = ''
        Wraps macOS `.app` bundles shipped by the package, so both bundle
        launches (Finder, Spotlight, Dock) and `bin/` launches run the
        wrapped binary with the real application icon.

        Imported by `wlib.modules.default`
      '';
    }
    (lib.mkIf (cfg.enable && cfg.bundles != [ ] && !hasShellOnlyFeatures) (
      lib.mkMerge [
        {
          # The wrapper binary replaces the bundle's Mach-O executable,
          # so a shell script wrapper cannot be used.
          wrapperImplementation = lib.mkDefault "binary";

          # Target the bundle's executable so processes launched through
          # `bin/` are associated with the `.app` bundle by LaunchServices.
          exePath = lib.mkDefault "${lib.head cfg.bundles}/Contents/MacOS/${binName}";
        }
        {
          buildCommand.appBundle = {
            after = [
              "symlinkScript"
              "makeWrapper"
            ];
            data =
              if config.wrapperImplementation or "nix" != "binary" then
                throw ''
                  modules.appBundles requires `wrapperImplementation = "binary"`,
                  since the wrapper binary replaces the bundle's Mach-O
                  executable. Set `appBundles.enable = false` to opt out, or
                  stop requesting the `shell` wrapper implementation.
                ''
              else
                lib.concatMapStringsSep "\n" (bundle: ''
                  bundleExe="${placeholder outputName}/${bundle}/Contents/MacOS/${binName}"
                  if [[ -e "$bundleExe" || -L "$bundleExe" ]]; then
                    rm -f "$bundleExe"
                    cp "${config.wrapperPaths.placeholder}" "$bundleExe"
                  fi
                '') cfg.bundles;
          };
        }
      ]
    ))
  ];
}
