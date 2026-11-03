# SPDX-License-Identifier: MIT
{ pkgs }:
let
  libeconf = pkgs.libeconf.overrideAttrs {
    version = "0.8.6";
    src = pkgs.fetchFromGitHub {
      owner = "openSUSE";
      repo = "libeconf";
      rev = "9f43b3480209272e4f4992129cca7a40b3e496e9";
      hash = "sha256-2x/PVDg/H9+u7FJKHbjLLLM++FGFe0mXY9mYKCrD6kw=";
    };
  };
in
pkgs.stdenv.mkDerivation {
  pname = "native-transactional-update";
  version = "6.2.0";
  src = pkgs.fetchFromGitHub {
    owner = "openSUSE";
    repo = "transactional-update";
    rev = "f63f3f1ff3c2ab39d6e6ef3a831a5ac8a6dc03af";
    hash = "sha256-pir3oAYLwj6QYfOW09dvj5uCL3LU7C5C/rlxVj+hXkE=";
  };
  nativeBuildInputs = [
    pkgs.autoreconfHook
    pkgs.autoconf-archive
    pkgs.pkg-config
    pkgs.patchelf
  ];
  buildInputs = [
    pkgs.systemd
    pkgs.dbus
    pkgs.dracut
    libeconf
    pkgs.libselinux
    pkgs.util-linux.dev
    pkgs.rpm
  ];
  configureFlags = [
    "--prefix=/usr"
    "--sysconfdir=/etc"
    "--with-doc=no"
  ];
  preConfigure = ''
    export SYSTEMDDIR=/usr/lib/systemd/system
    export TMPFILESDIR=/usr/lib/tmpfiles.d
    export DRACUTDIR=/usr/lib/dracut/modules.d
    export UDEVDIR=/usr/lib/udev
    export DBUSDATADIR=/usr/share
    export DBUSINTERFACESDIR=/usr/share/dbus-1/interfaces
    export DBUSSYSTEMBUSSERVICEDIR=/usr/share/dbus-1/system-services
  '';
  installFlags = [ "DESTDIR=$(out)" ];
  enableParallelBuilding = true;
  postInstall = ''
    mkdir -p $out/share/licenses/transactional-update
    cp gpl-2.0.txt lgpl-2.1.txt $out/share/licenses/transactional-update/
    tar -cf $out/share/licenses/transactional-update/source.tar -C $src .
    for executable in $out/usr/sbin/tukit $out/usr/sbin/tukitd; do
      if test -f "$executable"; then patchelf --add-rpath $out/usr/lib "$executable"; fi
    done
  '';
}
