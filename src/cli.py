# SPDX-License-Identifier: MIT
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True
from common import ROOTS, name
from prune import prune

parser = argparse.ArgumentParser()
commands = parser.add_subparsers(dest='operation', required=True)
for operation in ['install', 'remove']:
    command = commands.add_parser(operation)
    command.add_argument('subject')
    command.add_argument('--base', default='active')
command = commands.add_parser('prune')
command.add_argument('--owner')
args = parser.parse_args()
if os.geteuid() != 0:
    parser.error('snapshot staging and pruning require root')
if args.operation == 'prune':
    prune(args.owner)
    sys.exit(0)
if args.base not in ['active', 'default'] and not args.base.isdecimal():
    parser.error('base must be active, default or a native snapshot number')
nix_store = shutil.which('nix-store')
tukit = shutil.which('tukit')
if not nix_store or not tukit:
    parser.error('the host must provide Nix and native tukit')
ROOTS.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.source-', dir=ROOTS) as temporary:
    if args.operation == 'install':
        subject = subprocess.check_output([nix_store, '--add', str(Path(args.subject).resolve(strict=True))], text=True).strip()
        subprocess.run([nix_store, '--realise', subject, '--add-root', temporary + '/deployment'], check=True, stdout=subprocess.DEVNULL)
    else:
        subject = name(args.subject)
    command = [tukit]
    if args.base != 'active':
        command.append('--continue=' + args.base)
    command += ['execute', sys.executable, str(Path(__file__).with_name('stage.py')), args.operation, subject, nix_store]
    status = subprocess.call(command)
    prune()
    sys.exit(status)
