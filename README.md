# transactional-update-impurifier

Project Nix application closures into native Tukit/Snapper root transactions.
Original adapter code is MIT. The upstream transactional-update SDK and its
licenses are preserved separately; it uses GPL/LGPL components.

```nix
imp = inputs.transactional-update-impurifier.lib.transactional-update-impurifier { inherit pkgs; };
deployment = imp.makeOfflineDeployment { pkg = pkgs.hello; };
# Also: makeNetDeployment, makeDeployment { offline = false; ...; },
# and makePackage, returning { net, offline }.
```

Install the helper and provide native `tukit`, Snapper and Nix on the host.
The host must already have a working Btrfs root snapshot configuration and boot
selection. This adapter does not repartition disks or install a bootloader.

```sh
sudo transactional-update-impurifier install /path/to/deployment
# Reboot normally to activate the selected native snapshot.
sudo transactional-update-impurifier install /path/to/new-deployment --base default
sudo transactional-update-impurifier remove hello
# Native rollback and snapshot deletion remain native operations.
sudo tukit rollback SNAPSHOT
sudo transactional-update-impurifier prune --owner YOUR_USER
```

The default base is the active root. `--base default` chains a pending change;
a native snapshot number selects an explicit base. Staging never changes the
active `/usr`. Failed transactions are discarded by Tukit. Choose the intended
base when composing updates to avoid replacing another pending change.

Offline deployments contain closure caches. Root imports output data through
the trusted host Nix executable, with unsigned-cache acceptance scoped to that
explicit import. No application code runs as root and no daemon trust policy
is changed. Net deployments require the host to realize their closure normally.
Native Nix provisioning is deferred work; users can supply their own Nix package.

Launchers run as the calling user. Optional `hardware` uses the shared engine's
explicit library mapping and immutable per-user captures; arbitrary host library
access is not enabled. Application files remain unchanged after launch.

Nix roots live outside the snapshotted root under
`/nix/var/nix/gcroots/transactional-update-impurifier`. Their identity follows
application content, so native rollback clones retain their closures even after
an original snapshot is deleted. `prune` consults the actual Snapper snapshot
list and the active root. Only after every snapshot containing an application
has been deleted can pruning release its global roots. `--owner` also drops that
user's obsolete library/closure roots, with privileges dropped before touching
user state. Repeat it for other users who launched removed applications.
Keep `/nix` and user state persistent across root rollback.

## Native verification

`nix flake check -L` boots QEMU with a real Btrfs disk, real Snapper and upstream
transactional-update 6.2.0. It exercises failure, boot activation, native rollback
clones, snapshot deletion, unsigned offline recovery, upgrades, unchanged owned
files, library replacement across reboot, and Nix GC retention/release.
The NixOS fixture supplies real FHS tools required by upstream's sanitized PATH,
a separate persistent Nix store, CA certificates and initial bootable snapshots.
It does not emulate Snapper metadata or replace Tukit's transaction engine.

The SDK uses upstream libeconf 0.8.6 for its required quote-handling API. Private
ELF search paths locate the SDK libraries. Native deployment currently covers
x86_64 Linux application commands with a writable Btrfs root; read-only-root
variants, services/accounts, arbitrary payload transaction policies, concurrent administration,
SUSE package upgrades and other architectures need separate coverage.

## Native payloads and bundled clients

`makeNativeDeployment { name; payload; }` produces `rootfs/` from a complete
prepared filesystem tree without an SDK, engine, Nix dependencies or activation
hooks. Apply its files using native `transactional-update run` or `tukit execute`,
for example by copying `rootfs/.` to `/` inside the transaction. The native
tool owns snapshot activation and rollback. This artifact is not input to the
Nix-backed `transactional-update-impurifier install` helper, which retains its
Nix requirement. No per-file uninstall inventory or automatic relocation is
added; native snapshot rollback removes the applied tree.

The VM stages and boots a static proof through the native transaction, executes
it in a separate root without `/nix`, and rolls back to its absence. The manager
fixture retains its documented NixOS host tools and persistent Nix store.

Nix-backed application constructors also accept `bundledNixStore` (a supplied
static ELF executable) and `bundledNixNotices` (upstream notice files). The
application carries the client privately and uses a Python-only SDK. Launch
prefers a compatible external client, then the bundle, before registering roots
or capturing hardware. Explicit `IMPURIFIER_NIX_STORE` disables fallback.
Trusted preparation still uses host tools and never executes the image-owned
client as root. An existing store, daemon and initial SDK preparation remain
required. The separate bundled VM repeats the native lifecycle with an
incompatible external candidate; this is not a Nix installer.
