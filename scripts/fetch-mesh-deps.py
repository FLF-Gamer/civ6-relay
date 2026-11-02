#!/usr/bin/env python3
"""Fetch and extract checksum-pinned official EasyTier release archives."""
import hashlib
import io
import json
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    spec = json.loads((ROOT / 'build/easytier.json').read_text())
    if spec.get('build_version'):
        raise SystemExit('此版本使用源码补丁构建；请运行 scripts/build-mesh-fork.py，避免覆盖快速回退组件。')
    cache = ROOT / '.build/research'
    cache.mkdir(parents=True, exist_ok=True)
    for platform, asset in sorted(spec['assets'].items()):
        cached = cache / asset['url'].rsplit('/', 1)[-1]
        if not cached.is_file():
            with urllib.request.urlopen(asset['url'], timeout=120) as response:
                cached.write_bytes(response.read())
        data = cached.read_bytes()
        if hashlib.sha256(data).hexdigest() != asset['sha256']:
            raise SystemExit('Official archive checksum mismatch: ' + platform)
        target = ROOT / 'vendor/easytier' / platform
        target.mkdir(parents=True, exist_ok=True)
        hashes = {}
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for name in asset['files']:
                content = archive.read('easytier-' + platform + '/' + name)
                (target / name).write_bytes(content)
                (target / name).chmod(0o755 if platform.startswith('linux') else 0o644)
                hashes[name] = hashlib.sha256(content).hexdigest()
        (target / 'checksums.json').write_text(json.dumps(hashes, indent=2) + '\n')
        print('Verified official EasyTier ' + spec['version'] + ': ' + platform)

if __name__ == '__main__':
    main()
