# SPDX-License-Identifier: MIT
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True
from common import APPLICATIONS, ROOTS, load, name

parser = argparse.ArgumentParser()
parser.add_argument('operation', choices=['install', 'remove'])
parser.add_argument('subject')
parser.add_argument('nix_store')
args = parser.parse_args()
if os.geteuid() != 0 or not os.environ.get('TRANSACTIONAL_UPDATE'):
    parser.error('the staging worker must run inside a native root transaction')
ROOTS.mkdir(parents=True, exist_ok=True)
state_lock = (ROOTS / '.lock').open('a')
fcntl.flock(state_lock, fcntl.LOCK_EX)
if args.operation == 'install':
    source = Path(args.subject)
    meta = json.loads((source / 'deployment.json').read_text())
    app_name = name(meta['name'])
    implementation = source / 'rootfs' / APPLICATIONS.relative_to('/') / app_name
    config, identity = load(implementation)
    if config['name'] != app_name:
        raise ValueError('application identity does not match deployment')
    program = name(config['program'])
    rootfs = source / 'rootfs'
    for item in rootfs.rglob('*'):
        relative = item.relative_to(rootfs)
        allowed = relative in [Path('usr'), Path('usr/bin'), *list(APPLICATIONS.relative_to('/').parents)[:-1], APPLICATIONS.relative_to('/')]
        if not allowed and relative != Path('usr/bin') / program and not relative.is_relative_to(APPLICATIONS.relative_to('/') / app_name):
            raise ValueError('deployment contains an unexpected path')
        if item.is_symlink() or (not item.is_dir() and not item.is_file()):
            raise ValueError('deployment payload must contain regular files and directories')
else:
    app_name = name(args.subject)
    implementation = None
    config = None
    identity = None

destination = APPLICATIONS / app_name
old = load(destination)[0] if destination.exists() else None
if args.operation == 'remove' and old is None:
    raise ValueError('application is not installed in the selected snapshot')
if config is not None and Path('/usr/bin', program).exists() and (old is None or old['program'] != program):
    raise ValueError('command path is already owned outside this application')

# Root only imports Nix output data with the trusted host executable. Roots
# are outside the snapshotted filesystem so native rollback/copy retains them.
if config is not None:
    ROOTS.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.prepare-', dir=ROOTS) as temporary:
        staged = Path(temporary)
        for field, cache_name in [('sdk', 'sdk-cache'), ('installable', 'cache')]:
            command = [args.nix_store, '--realise', config[field], '--add-root', str(staged / field)]
            cache = implementation / cache_name
            if cache.is_dir():
                command += ['--option', 'substituters', cache.as_uri(), '--option', 'require-sigs', 'false']
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
        (staged / 'source.json').write_text(json.dumps({'identity': identity, 'name': app_name}))
        published = ROOTS / identity
        if not published.exists():
            os.rename(staged, published)

if old:
    Path('/usr/bin', name(old['program'])).unlink(missing_ok=True)
    shutil.rmtree(destination)
if implementation is not None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    Path('/usr/bin').mkdir(parents=True, exist_ok=True)
    shutil.copytree(implementation, destination)
    shutil.copy2(rootfs / 'usr/bin' / program, Path('/usr/bin', program))
