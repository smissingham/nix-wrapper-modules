{
  lib,
  pkgs,
  self,
  tlib,
  ...
}:
let
  inherit (tlib)
    areEqual
    fileContains
    isFile
    test
    ;

  # A dummy package which ships a `.app` bundle alongside its `bin/` script
  bundlePackage =
    (pkgs.runCommand "bundle-app" { } ''
      mkdir -p $out/bin
      mkdir -p $out/Applications/Foo.app/Contents/MacOS
      mkdir -p $out/Applications/Foo.app/Contents/Resources

      cat > $out/bin/foo <<'EOF'
      #!/bin/sh
      echo "foo"
      EOF
      chmod +x $out/bin/foo

      cp $out/bin/foo $out/Applications/Foo.app/Contents/MacOS/foo

      cat > $out/Applications/Foo.app/Contents/Info.plist <<'EOF'
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleExecutable</key>
        <string>foo</string>
        <key>CFBundleIdentifier</key>
        <string>org.nix-wrapper-modules.foo</string>
      </dict>
      </plist>
      EOF

      cat > $out/Applications/Foo.app/Contents/Resources/foo.icns <<'EOF'
      icns
      EOF
    '')
    // {
      meta.mainProgram = "foo";
    };

  # Bundles are set explicitly so the test does not depend on the package
  # already being present in the store (eval time detection reads it)
  testModule = self.lib.wrapModule {
    package = bundlePackage;
    appBundles.enable = true;
    appBundles.bundles = [ "Applications/Foo.app" ];
  };
  wrapper = (testModule.apply { inherit pkgs; }).wrapper;

  defaultModule = self.lib.wrapModule { package = bundlePackage; };
  defaultWrapper = (defaultModule.apply { inherit pkgs; }).wrapper;

  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  bundleExe = "${wrapper}/Applications/Foo.app/Contents/MacOS/foo";
in
test { name = "module-darwinAppBundle"; } {
  "exePath points into the bundle" = [
    (areEqual "Applications/Foo.app/Contents/MacOS/foo" testModule.exePath)
  ];

  "bundle executable is replaced by the wrapper binary" = [
    (isFile bundleExe)
    "[ ! -L ${bundleExe} ]"
    "cmp -s ${wrapper}/bin/foo ${bundleExe}"
  ];

  "bin wrapper targets the bundle executable" = [
    (fileContains "${wrapper}/bin/foo" "Applications/Foo\\.app/Contents/MacOS/foo")
  ];

  "bin wrapper runs" = [
    "${wrapper}/bin/foo | grep -qx foo"
  ];

  "bundle executable runs without looping" = [
    "${bundleExe} | grep -qx foo"
  ];

  "disabled by default off darwin" = [
    "true"
  ]
  ++ lib.optionals isLinux [
    (areEqual false defaultModule.appBundles.enable)
    (areEqual "bin/foo" defaultModule.exePath)
    "[ -L ${defaultWrapper}/Applications/Foo.app/Contents/MacOS/foo ]"
    "${defaultWrapper}/bin/foo | grep -qx foo"
  ];
}
