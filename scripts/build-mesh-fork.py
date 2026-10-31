#!/usr/bin/env python3
"""Build the published, minimal EasyTier patch for Linux musl and Windows MSVC.

Docker keeps Cargo objects and SDK downloads in named build-only volumes.
The exact upstream source archive and local patch ship with every release.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import posixpath
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DOCKER = shutil.which('docker') or str(Path.home() / '.docker/bin/docker')
WINPCAP_SDK_URL = 'https://www.winpcap.org/install/bin/WpdPack_4_1_2.zip'
WINPCAP_SDK_SHA256 = 'ea799cf2f26e4afb1892938070fd2b1ca37ce5cf75fec4349247df12b784edbd'
WINPCAP_IMPORT_SHA256 = '5be8eb0ef57344cedc940fd81edbf7fc98680ba0c8337b577e7fdc448408130b'


def run(args, **kwargs):
    subprocess.run(list(map(str, args)), check=True, **kwargs)


def prepare_windows_imports():
    """Keep the legacy SDK import library in a private build-only cache.

    pnet declares a Packet native library even when its Windows backend is
    unused. The published executables must have no Packet.dll import; no
    WinPcap/Npcap DLL or driver is extracted or redistributed.
    """
    directory = ROOT / '.build/mesh-build-imports'
    library = directory / 'Packet.lib'
    if library.is_file() and hashlib.sha256(library.read_bytes()).hexdigest() == WINPCAP_IMPORT_SHA256:
        return directory
    with urllib.request.urlopen(WINPCAP_SDK_URL, timeout=60) as response:
        sdk = response.read()
    if hashlib.sha256(sdk).hexdigest() != WINPCAP_SDK_SHA256:
        raise SystemExit('Unexpected WinPcap SDK archive checksum')
    with zipfile.ZipFile(io.BytesIO(sdk)) as archive:
        data = archive.read('WpdPack/Lib/x64/Packet.lib')
    if hashlib.sha256(data).hexdigest() != WINPCAP_IMPORT_SHA256:
        raise SystemExit('Unexpected WinPcap SDK import library checksum')
    directory.mkdir(parents=True, exist_ok=True)
    library.write_bytes(data)
    return directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['linux', 'windows', 'all'], default='all')
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--skip-image', action='store_true')
    args = parser.parse_args()
    archive = ROOT / 'vendor/easytier/licenses/EasyTier-2.6.4-source.tar.gz'
    source = ROOT / '.build/mesh-source'
    patch = ROOT / 'build/easytier-fast-failover.patch'
    stamp = hashlib.sha256(archive.read_bytes() + patch.read_bytes()).hexdigest()
    if not (source / '.civ6-build-stamp').is_file() or (source / '.civ6-build-stamp').read_text() != stamp:
        if source.exists():
            shutil.rmtree(source)
        source.mkdir(parents=True)
        with tarfile.open(archive) as tar:
            links = []
            for member in tar.getmembers():
                relative = Path(*Path(member.name).parts[1:])
                if relative.is_absolute() or '..' in relative.parts:
                    raise SystemExit('Unsafe source archive entry')
                if member.issym():
                    resolved = Path(posixpath.normpath(str(relative.parent / member.linkname)))
                    if resolved.is_absolute() or '..' in resolved.parts:
                        raise SystemExit('Unsafe source archive link')
                    links.append((relative, resolved))
                    continue
                if member.islnk():
                    raise SystemExit('Unexpected hard link in source archive')
                if member.isfile():
                    target = source / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(tar.extractfile(member).read())
                    target.chmod(member.mode & 0o777)
            for relative, resolved in links:
                if (source / resolved).is_dir():
                    shutil.copytree(source / resolved, source / relative)
                else:
                    shutil.copy2(source / resolved, source / relative)
        run(['patch', '-p1', '--batch', '-i', patch], cwd=source)
        (source / '.civ6-build-stamp').write_text(stamp)
    if args.prepare_only:
        print(source)
        return
    if not args.skip_image:
        run([DOCKER, 'build', '-f', ROOT / 'build/mesh-fork.Dockerfile', '-t', 'civ6-mesh-build:local', ROOT / '.build'])
    output = ROOT / '.build/mesh-fork-out'
    output.mkdir(parents=True, exist_ok=True)
    for platform in (['linux', 'windows'] if args.platform == 'all' else [args.platform]):
        native_imports = []
        if platform == 'linux':
            target, tool, extension = 'x86_64-unknown-linux-musl', 'zigbuild', ''
        else:
            target, tool, extension = 'x86_64-pc-windows-msvc', 'xwin', '.exe'
            imports = prepare_windows_imports()
            native_imports = ['-v', str(imports) + ':/build-imports:ro', '-e', 'LIB=/build-imports']
        build = ['cargo', tool]
        if tool == 'xwin':
            build += ['build']
        build += ['--locked', '--release', '--target', target, '-p', 'easytier', '--no-default-features',
                  '--features', 'tun,aes-gcm,zstd', '--bin', 'easytier-core', '--bin', 'easytier-cli']
        # Source changes remain mounted read-only; Cargo output uses native
        # container storage to avoid thousands of host filesystem operations.
        run([DOCKER, 'run', '--rm', '--name', 'civ6-build-' + platform,
             '-v', str(source) + ':/src:ro', '-v', str(output) + ':/artifacts',
             '-v', str(ROOT / 'scripts') + ':/build-tools:ro',
             '-v', 'civ6-mesh-cargo-registry:/usr/local/cargo/registry',
             '-v', 'civ6-mesh-cargo-git:/usr/local/cargo/git',
             '-v', 'civ6-mesh-target:/target', '-v', 'civ6-mesh-xwin:/xwin',
             *native_imports,
             '-e', 'XWIN_ARCH=x86_64', '-e', 'XWIN_CACHE_DIR=/xwin',
             '-e', 'CARGO_TARGET_DIR=/target', '-e', 'CARGO_BUILD_JOBS=4', '-e', 'RUSTUP_TOOLCHAIN=1.95.0',
             'civ6-mesh-build:local', 'sh', '-c',
             ('python3 /build-tools/fix-windivert-build.py && ' if platform == 'windows' else '') +
             ' '.join(build) + ' && cp /target/' + target + '/release/easytier-core' + extension +
             ' /target/' + target + '/release/easytier-cli' + extension + ' /artifacts/'])
        print('Built ' + platform, flush=True)
    (output / 'build.json').write_text(json.dumps(dict(version='2.6.4-civ6.2', packaging_variant='3.2.5-no-npcap',
                                                       source_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                                                       patch_sha256=hashlib.sha256(patch.read_bytes()).hexdigest(),
                                                       source_and_patch_sha256=stamp,
                                                       features=['tun', 'aes-gcm', 'zstd']), indent=2) + '\n')


if __name__ == '__main__':
    main()
