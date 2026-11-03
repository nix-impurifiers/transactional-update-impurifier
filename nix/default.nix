# SPDX-License-Identifier: MIT
{
  pkgs,
  coreSrc,
  sourceInfo ? { },
}:
let
  inherit (pkgs) lib;
  native = import ./tools.nix { inherit pkgs; };
  core = import (coreSrc + "/nix") {
    inherit pkgs;
    namespace = "transactional-update-impurifier";
  };
  sdk = pkgs.linkFarm "transactional-update-impurifier-sdk" [
    {
      name = "python";
      path = pkgs.python3;
    }
    {
      name = "nix";
      path = pkgs.nix;
    }
  ];
  nativeClient = pkgs.symlinkJoin {
    name = "transactional-update-native-client";
    paths =
      map (program: pkgs.writeShellScriptBin program ''exec ${native}/usr/sbin/${program} "$@"'')
        [
          "tukit"
          "transactional-update"
        ];
  };
  package = pkgs.writeShellApplication {
    name = "transactional-update-impurifier";
    runtimeInputs = [
      pkgs.nix
      pkgs.python3
    ];
    text = ''exec ${sdk}/python/bin/python3 ${../src}/cli.py "$@"'';
  };
  safe = value: builtins.match "[A-Za-z0-9_][A-Za-z0-9_.+-]*" value != null;
  makeNativeDeployment =
    { name, payload }:
    assert lib.assertMsg (safe name) "invalid deployment name";
    pkgs.runCommand "${name}-native-transactional-tree" { } ''
      mkdir -p $out/rootfs
      cp -r ${payload}/. $out/rootfs/
    '';
  makeDeployment =
    {
      pkg,
      name ? pkg.pname,
      program ? pkg.meta.mainProgram or pkg.pname,
      offline ? false,
      hardware ? null,
      bundledNixStore ? null,
      bundledNixNotices ? [ ],
    }:
    assert lib.assertMsg (safe name && safe program) "invalid application or executable name";
    let
      appSdk =
        if bundledNixStore == null then
          sdk
        else
          pkgs.linkFarm "transactional-update-python-sdk" [
            {
              name = "python";
              path = pkgs.python3;
            }
          ];
      bundle = core.makeRuntimeTree { inherit bundledNixStore bundledNixNotices; };
    in
    pkgs.runCommand "${name}-${pkg.version}-transactional-deployment"
      {
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        test -x ${pkg}/bin/${program}
        implementation=$out/rootfs/usr/share/transactional-update-impurifier/apps/${name}
        mkdir -p "$implementation" $out/rootfs/usr/bin
        cp ${../src/launch.py} "$implementation/launch.py"
        cp ${../src/common.py} "$implementation/common.py"
        cp ${coreSrc}/src/engine.py "$implementation/engine.py"
        cp ${../LICENSE} "$implementation/LICENSE"
        ${lib.optionalString (bundledNixStore != null) ''
          cp ${bundle}/usr/lib/transactional-update-impurifier/nix-store "$implementation/nix-store"
          mkdir -p "$implementation/share/licenses/bundled-nix"
          cp -r ${bundle}/usr/share/licenses/transactional-update-impurifier/bundled-nix/. "$implementation/share/licenses/bundled-nix/"
        ''}
        cp ${
          pkgs.writeText "deployment.json" (
            builtins.toJSON {
              inherit name;
              schema = 1;
            }
          )
        } $out/deployment.json
        cp ${
          pkgs.writeText "application.json" (
            builtins.toJSON {
              inherit name program offline;
              inherit (pkg) version;
              installable = toString pkg;
              sdk = toString appSdk;
              nixBin = "${pkgs.nix}/bin";
              implementationDigest =
                builtins.hashFile "sha256" ../src/launch.py
                + builtins.hashFile "sha256" ../src/common.py
                + builtins.hashFile "sha256" (coreSrc + "/src/engine.py");
              hardware = if hardware == null then null else { preload = [ ]; } // hardware;
            }
          )
        } "$implementation/application.json"
        cat > $out/rootfs/usr/bin/${program} <<'PY'
        #!${pkgs.python3}/bin/python3
        import runpy
        import sys
        sys.dont_write_bytecode = True
        sys.path.insert(0, '/usr/share/transactional-update-impurifier/apps/${name}')
        runpy.run_path('/usr/share/transactional-update-impurifier/apps/${name}/launch.py', run_name='__main__')
        PY
        chmod 755 $out/rootfs/usr/bin/${program}
        ${lib.optionalString offline ''
          cp -r ${core.offlineCache pkg} "$implementation/cache"
          cp -r ${core.offlineCache appSdk} "$implementation/sdk-cache"
        ''}
      '';
in
{
  inherit
    package
    native
    nativeClient
    sdk
    makeDeployment
    makeNativeDeployment
    ;
  makeNetDeployment = args: makeDeployment (args // { offline = false; });
  makeOfflineDeployment = args: makeDeployment (args // { offline = true; });
  makePackage = args: {
    net = makeDeployment (args // { offline = false; });
    offline = makeDeployment (args // { offline = true; });
  };
}
