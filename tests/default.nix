# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  coreSrc,
}:
let
  tools = impurifier.native;
  app = pkgs.writeShellScriptBin "tu-app" "echo transactional-one" // {
    pname = "tu-app";
    version = "1";
  };
  app2 = pkgs.writeShellScriptBin "tu-app" "echo transactional-two" // {
    pname = "tu-app";
    version = "2";
  };
  net = impurifier.makeNetDeployment { pkg = app; };
  offline = impurifier.makeOfflineDeployment { pkg = app; };
  upgrade = impurifier.makeOfflineDeployment { pkg = app2; };
  fixture = import (coreSrc + "/tests/hardware-fixture.nix") { inherit pkgs; };
  hardware = impurifier.makeOfflineDeployment {
    pkg = fixture.tool;
    hardware = fixture.hardware;
  };
  disk = pkgs.runCommand "tukit-empty-btrfs.raw" { nativeBuildInputs = [ pkgs.btrfs-progs ]; } ''
    truncate -s 4096M $out
    mkfs.btrfs -f -L nixos $out
  '';
in
{
  native-vm = pkgs.testers.runNixOSTest {
    name = "transactional-update-native-contract";
    globalTimeout = 600;
    requiredFeatures = {
      kvm = false;
      devnet = false;
    };
    nodes.machine = { lib, ... }: {
      virtualisation.qemu.package = lib.mkForce pkgs.qemu;
      virtualisation.qemu.forceAccel = false;
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
      virtualisation.writableStoreUseTmpfs = false;
      virtualisation.fileSystems."/".fsType = lib.mkForce "btrfs";
      virtualisation.fileSystems."/nix" = {
        device = "/dev/disk/by-label/nixos";
        fsType = "btrfs";
        options = [ "subvol=/nix" ];
        neededForBoot = true;
      };
      virtualisation.fileSystems."/home" = {
        device = "/dev/disk/by-label/nixos";
        fsType = "btrfs";
        options = [ "subvol=/home" ];
        neededForBoot = true;
      };
      virtualisation.fileSystems."/var" = {
        device = "/dev/disk/by-label/nixos";
        fsType = "btrfs";
        options = [ "subvol=/var" ];
        neededForBoot = true;
      };
      virtualisation.fileSystems."/.snapshots" = {
        device = "/dev/disk/by-label/nixos";
        fsType = "btrfs";
        options = [ "subvol=/.snapshots" ];
        neededForBoot = true;
      };
      boot.supportedFilesystems = [ "btrfs" ];
      boot.initrd.systemd.storePaths = [ pkgs.btrfs-progs ];
      boot.initrd.systemd.services.tukit-subvolumes = {
        requiredBy = [
          "sysroot-home.mount"
          "sysroot-nix.mount"
          "sysroot-var.mount"
          "sysroot-.snapshots.mount"
        ];
        before = [
          "sysroot-home.mount"
          "sysroot-nix.mount"
          "sysroot-var.mount"
          "sysroot-.snapshots.mount"
        ];
        after = [ "sysroot.mount" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig.Type = "oneshot";
        script = ''
          for path in nix var .snapshots home; do
            if ! test -e /sysroot/$path; then ${pkgs.btrfs-progs}/bin/btrfs subvolume create /sysroot/$path; fi
          done
        '';
      };
      services.snapper.configs.root.SUBVOLUME = "/";
      services.snapper.snapshotRootOnBoot = false;
      networking.useDHCP = lib.mkForce false;
      system.activationScripts.native-fhs.text = ''
        mkdir -p /usr/bin /usr/sbin /usr/libexec /usr/lib /var/lib/ca-certificates
        cp ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt /var/lib/ca-certificates/ca-bundle.pem
        for directory in ${pkgs.snapper}/bin ${pkgs.btrfs-progs}/bin ${pkgs.util-linux}/bin ${pkgs.util-linux}/sbin ${pkgs.rpm}/bin ${pkgs.rsync}/bin ${pkgs.coreutils}/bin ${pkgs.findutils}/bin ${pkgs.gnused}/bin ${pkgs.gnugrep}/bin ${pkgs.bash}/bin; do
          for program in "$directory"/*; do
            if test -f "$program"; then ln -sf "$program" /usr/bin/$(basename "$program"); fi
          done
        done
        cp -rs --remove-destination ${tools}/usr/sbin/. /usr/sbin/
        cp -rs --remove-destination ${tools}/usr/libexec/. /usr/libexec/
      '';
      users.users.consumer.isNormalUser = true;
      nix.settings.substituters = lib.mkForce [ ];
      environment.systemPackages = [
        impurifier.package
        impurifier.nativeClient
        pkgs.nix
        pkgs.python3
        pkgs.snapper
        pkgs.btrfs-progs
        pkgs.rsync
        pkgs.util-linux
        pkgs.rpm
      ];
      environment.etc."tukit.conf".text = ''
        SNAPSHOT_MANAGER="snapper"
        BINDDIRS[0]="/nix/store"
        BINDDIRS[1]="/nix/var"
        BINDDIRS[2]="/var/lib/test-drivers"
      '';
    };
    testScript = ''
      import os
      import csv
      import shlex
      import subprocess
      root_disk = str((machine.state_dir / "btrfs-root.qcow2").resolve())
      subprocess.run(["${pkgs.qemu}/bin/qemu-img", "create", "-f", "qcow2", "-b", "${disk}", "-F", "raw", root_disk], check=True)
      os.environ["NIX_DISK_IMAGE"] = root_disk
      start_all()
      machine.wait_for_unit("multi-user.target", timeout=60)
      machine.succeed("findmnt /; snapper -c root list")
      machine.succeed("mkdir -p /var/lib/tu-fixtures; cp -r ${net} /var/lib/tu-fixtures/net; cp -r ${offline} /var/lib/tu-fixtures/offline; cp -r ${upgrade} /var/lib/tu-fixtures/upgrade")
      machine.succeed("cp -r ${hardware} /var/lib/tu-fixtures/hardware; mkdir -p /var/lib/test-drivers; cp ${fixture.driver "1"}/usr/lib/libimpurifier-driver.so.1 /var/lib/test-drivers/1.so; cp ${fixture.driver "2"}/usr/lib/libimpurifier-driver.so.1 /var/lib/test-drivers/2.so")
      base = machine.succeed("snapper -c root create --read-write --print-number --description native-base").strip()
      machine.succeed("for name in nix var .snapshots home; do rmdir /.snapshots/" + base + "/snapshot/$name; mkdir /.snapshots/" + base + "/snapshot/$name; done")
      machine.succeed("btrfs subvolume set-default /.snapshots/" + base + "/snapshot")
      machine.shutdown()
      machine.start()
      machine.wait_for_unit("multi-user.target", timeout=60)
      machine.succeed("${tools}/usr/sbin/tukit snapshots")
      machine.succeed("${tools}/usr/sbin/transactional-update --no-selfupdate run ${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/mkdir -p /usr/share; echo staged > /usr/share/tukit-native-marker'")
      machine.succeed("test ! -e /usr/share/tukit-native-marker")
      machine.fail("${tools}/usr/sbin/tukit execute ${pkgs.bash}/bin/bash -c 'exit 23'")
      machine.shutdown()
      machine.start()
      machine.wait_for_unit("multi-user.target", timeout=60)
      assert machine.succeed("cat /usr/share/tukit-native-marker").strip() == "staged"
      machine.succeed("${tools}/usr/sbin/tukit rollback " + base)
      machine.shutdown()
      machine.start()
      machine.wait_for_unit("multi-user.target", timeout=60)
      machine.succeed("test ! -e /usr/share/tukit-native-marker")

      def user(command):
          return "su - consumer -c " + shlex.quote(command)
      def default_snapshot():
          rows = csv.DictReader(machine.succeed("snapper --csvout list --columns number,default").splitlines())
          return next(row['number'] for row in rows if row['default'] == 'yes')
      def delete_inactive():
          selected = default_snapshot()
          rows = list(csv.DictReader(machine.succeed("snapper --csvout list --columns number").splitlines()))
          for row in rows:
              if row['number'] not in ['0', selected]:
                  machine.succeed("snapper delete " + row['number'])
      def boot_default():
          machine.shutdown()
          machine.start()
          machine.wait_for_unit("multi-user.target", timeout=60)
      machine.fail(user("transactional-update-impurifier install /var/lib/tu-fixtures/offline"))
      before = default_snapshot()
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}")
      machine.fail("transactional-update-impurifier install /var/lib/tu-fixtures/net")
      assert default_snapshot() == before
      machine.succeed("test ! -e /usr/bin/tu-app")
      machine.succeed("transactional-update-impurifier install /var/lib/tu-fixtures/offline")
      app_one = default_snapshot()
      machine.succeed("nix-store --gc; test -e ${builtins.unsafeDiscardStringContext (toString app)}; test ! -e /usr/bin/tu-app")
      boot_default()
      checksum = machine.succeed("find /usr/share/transactional-update-impurifier/apps/tu-app -type f -exec sha256sum {} + | sort")
      assert machine.succeed(user("/usr/bin/tu-app")).strip() == "transactional-one"
      assert machine.succeed("find /usr/share/transactional-update-impurifier/apps/tu-app -type f -exec sha256sum {} + | sort") == checksum
      machine.succeed("transactional-update-impurifier install /var/lib/tu-fixtures/upgrade")
      assert machine.succeed(user("/usr/bin/tu-app")).strip() == "transactional-one"
      machine.succeed("nix-store --gc; test -e ${builtins.unsafeDiscardStringContext (toString app)}; test -e ${builtins.unsafeDiscardStringContext (toString app2)}")
      boot_default()
      assert machine.succeed(user("/usr/bin/tu-app")).strip() == "transactional-two"
      machine.succeed("tukit rollback " + app_one)
      boot_default()
      assert machine.succeed(user("/usr/bin/tu-app")).strip() == "transactional-one"
      delete_inactive()
      machine.succeed("transactional-update-impurifier prune --owner consumer; nix-store --gc; test -e ${builtins.unsafeDiscardStringContext (toString app)}; test ! -e ${builtins.unsafeDiscardStringContext (toString app2)}")
      machine.succeed("transactional-update-impurifier remove tu-app")
      assert machine.succeed(user("/usr/bin/tu-app")).strip() == "transactional-one"
      boot_default()
      machine.succeed("test ! -e /usr/bin/tu-app")
      delete_inactive()
      machine.succeed("transactional-update-impurifier prune --owner consumer; nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}")
      machine.succeed("transactional-update-impurifier install /var/lib/tu-fixtures/hardware")
      machine.succeed("tukit --continue=default execute ${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/mkdir -p /usr/lib; ${pkgs.coreutils}/bin/cp /var/lib/test-drivers/1.so /usr/lib/libimpurifier-driver.so.1'")
      boot_default()
      assert machine.succeed(user("/usr/bin/hardware-tool")).strip() == "1"
      machine.succeed("tukit execute ${pkgs.coreutils}/bin/cp /var/lib/test-drivers/2.so /usr/lib/libimpurifier-driver.so.1")
      assert machine.succeed(user("/usr/bin/hardware-tool")).strip() == "1"
      boot_default()
      assert machine.succeed(user("/usr/bin/hardware-tool")).strip() == "2"
      machine.succeed("transactional-update-impurifier remove hardware-tool")
      boot_default()
      delete_inactive()
      machine.succeed("transactional-update-impurifier prune --owner consumer; nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString fixture.tool)}; test ! -e /usr/bin/hardware-tool")
    '';
  };
}
