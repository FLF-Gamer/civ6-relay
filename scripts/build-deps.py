#!/usr/bin/env python3
"""Download checksum-pinned upstream sources; build portable Linux binaries."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

def main():
    lock = json.loads((ROOT / 'build/dependencies.json').read_text())
    cache = ROOT / '.build/sources'
    context = ROOT / '.build/deps-context'
    cache.mkdir(parents=True, exist_ok=True)
    context.mkdir(parents=True, exist_ok=True)
    for name, package in lock.items():
        archive = cache / (name + '.tar.xz')
        if not archive.is_file():
            print('Downloading ' + name, flush=True)
            with urllib.request.urlopen(package['url'], timeout=60) as response:
                archive.write_bytes(response.read())
        if hashlib.sha256(archive.read_bytes()).hexdigest() != package['sha256']:
            raise SystemExit('Source checksum mismatch: ' + name)
        destination = context / name
        if destination.exists():
            shutil.rmtree(destination)
        destination.mkdir()
        with tarfile.open(archive) as source:
            for item in source.getmembers():
                parts = Path(item.name).parts
                relative = Path(*parts[1:]) if len(parts) > 1 else Path('.')
                if relative.is_absolute() or '..' in relative.parts:
                    raise SystemExit('Unsafe archive entry: ' + item.name)
                # wg-quick convenience links are not needed for the wg binary.
                if item.issym() or item.islnk():
                    continue
                if item.isfile():
                    path = destination / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(source.extractfile(item).read())
    output = ROOT / 'vendor/linux-amd64'
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(['docker', 'build', '--platform', 'linux/amd64', '--file', str(ROOT / 'build/deps.Dockerfile'),
                    '--output', 'type=local,dest=' + str(output), str(context)], check=True)
    hashes = {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in ('wg',)}
    (output / 'checksums.json').write_text(json.dumps(hashes, indent=2) + '\n')
    shutil.copy2(ROOT / 'build/musl-COPYRIGHT', output / 'licenses/musl.txt')
    sources = ROOT / 'vendor/sources'
    sources.mkdir(parents=True, exist_ok=True)
    for name in lock:
        shutil.copy2(cache / (name + '.tar.xz'), sources / (name + '.tar.xz'))
    print('Built Linux amd64 dependencies: ' + str(output))

if __name__ == '__main__':
    main()
