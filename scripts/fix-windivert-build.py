#!/usr/bin/env python3
"""Normalize two build-only WinDivert paths for Linux -> MSVC compilation.

The dependency commit remains pinned by Cargo.lock. No C or Rust runtime code
is changed. The resulting dependency source ships with the release licenses.
"""
import os
from pathlib import Path
import shutil
import subprocess

cache = Path(os.environ.get('CARGO_HOME', '/usr/local/cargo')) / 'git/checkouts'
pattern = 'windivert-rust-*/adcc56d/windivert-sys/build/compile/msvc.rs'
paths = list(cache.glob(pattern))
if not paths:
    subprocess.run(['cargo', 'fetch', '--locked', '--target', 'x86_64-pc-windows-msvc'], check=True)
    paths = list(cache.glob(pattern))
if not paths:
    raise SystemExit('Pinned WinDivert dependency source is missing')
for path in paths:
    old = path.read_text()
    new = old.replace('vendor\\include', 'vendor/include').replace('vendor\\dll\\windivert.c', 'vendor/dll/windivert.c')
    if new != old:
        path.write_text(new)
    marker = path.parent / '.civ6-cross-paths-v2'
    if not marker.exists():
        # Cargo treats a pinned Git dependency as immutable; discard only this
        # package's old build script so a previous failed compile is not reused.
        target = Path(os.environ['CARGO_TARGET_DIR'])
        for profile in (target / 'release', target / 'x86_64-pc-windows-msvc/release'):
            for category in ('build', '.fingerprint'):
                for cached in (profile / category).glob('windivert-sys-*'):
                    shutil.rmtree(cached)
        marker.touch()
print('WinDivert build paths ready; runtime source unchanged', flush=True)
