#!/usr/bin/env python3
"""Build the native Windows GUI launcher with the cached Rust/MSVC SDK, offline.

The launcher has no Cargo dependencies. Build intermediates, targets and audit
reports stay in .build; only Civ6Relay.exe is copied beside the UI. On Windows,
use --native with the Rust MSVC toolchain and Windows SDK already installed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'client/launcher'
TARGET = 'x86_64-pc-windows-msvc'


def icon_bytes():
    """Render our original icon.svg geometry into deterministic 32-bit ICO DIBs."""
    navy, gold, ivory = (20, 51, 79), (213, 179, 106), (241, 230, 206)
    nodes = ((76, 76), (184, 106), (108, 184))

    def pixel(x, y):
        cx, cy = min(194, max(62, x)), min(194, max(62, y))
        if (x - cx) ** 2 + (y - cy) ** 2 > 54 ** 2:
            return None
        color = navy
        for i, (ax, ay) in enumerate(nodes):
            bx, by = nodes[(i + 1) % 3]
            t = max(0, min(1, ((x - ax) * (bx - ax) + (y - ay) * (by - ay)) / ((bx - ax) ** 2 + (by - ay) ** 2)))
            if (x - ax - t * (bx - ax)) ** 2 + (y - ay - t * (by - ay)) ** 2 <= 7 ** 2:
                color = gold
        for nx, ny in nodes:
            distance = (x - nx) ** 2 + (y - ny) ** 2
            if distance <= 25 ** 2:
                color = navy if distance <= 10 ** 2 else ivory
        return color

    images = []
    for size in (16, 24, 32, 48, 64, 128, 256):
        bitmap = bytearray()
        mask = bytearray()
        for row in reversed(range(size)):
            bits = bytearray(((size + 31) // 32) * 4)
            for column in range(size):
                samples = [pixel((column + dx) * 256 / size, (row + dy) * 256 / size)
                           for dx in (0.25, 0.75) for dy in (0.25, 0.75)]
                colors = [value for value in samples if value is not None]
                if colors:
                    rgb = [round(sum(value[channel] for value in colors) / len(colors)) for channel in range(3)]
                    bitmap.extend((rgb[2], rgb[1], rgb[0], round(255 * len(colors) / 4)))
                else:
                    bitmap.extend((0, 0, 0, 0))
                    bits[column // 8] |= 0x80 >> (column % 8)
            mask.extend(bits)
        header = struct.pack('<IiiHHIIiiII', 40, size, size * 2, 1, 32, 0, len(bitmap), 0, 0, 0, 0)
        images.append((size, header + bitmap + mask))
    output = bytearray(struct.pack('<HHH', 0, 1, len(images)))
    offset = 6 + 16 * len(images)
    for size, data in images:
        dimension = size if size < 256 else 0
        output.extend(struct.pack('<BBBBHHII', dimension, dimension, 0, 0, 1, 32, len(data), offset))
        offset += len(data)
    for _, data in images:
        output.extend(data)
    return bytes(output)


def inspect_pe(data):
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[:2] != b'MZ' or data[pe:pe + 4] != b'PE\0\0':
        raise SystemExit('Launcher is not a PE executable')
    machine, sections = struct.unpack_from('<HH', data, pe + 4)
    optional = pe + 24
    if machine != 0x8664 or struct.unpack_from('<H', data, optional)[0] != 0x20b:
        raise SystemExit('Expected a native x64 PE32+ launcher')
    if struct.unpack_from('<H', data, optional + 68)[0] != 2:
        raise SystemExit('Expected the Windows GUI subsystem')
    if struct.unpack_from('<II', data, optional + 112 + 14 * 8) != (0, 0):
        raise SystemExit('Unexpected managed/.NET executable')
    section_table = optional + struct.unpack_from('<H', data, pe + 20)[0]

    def file_offset(rva):
        for i in range(sections):
            entry = section_table + i * 40
            size, address, raw_size, raw = struct.unpack_from('<IIII', data, entry + 8)
            if address <= rva < address + max(size, raw_size):
                return raw + rva - address
        raise SystemExit('Invalid PE resource/import address')

    imports = []
    rva = struct.unpack_from('<I', data, optional + 120)[0]
    at = file_offset(rva)
    while any(data[at:at + 20]):
        name_rva = struct.unpack_from('<I', data, at + 12)[0]
        name_offset = file_offset(name_rva)
        name = data[name_offset:data.index(b'\0', name_offset)].decode('ascii')
        if any(value in name.lower() for value in ('vcruntime', 'msvcp', 'ucrtbase', 'api-ms-win-crt', 'hostfxr', 'mscoree', 'packet.dll')):
            raise SystemExit('Unexpected external runtime dependency: ' + name)
        imports.append(name)
        at += 20
    resource_rva = struct.unpack_from('<I', data, optional + 128)[0]
    resource = file_offset(resource_rva)
    named, ids = struct.unpack_from('<HH', data, resource + 12)
    types = [struct.unpack_from('<I', data, resource + 16 + i * 8)[0] for i in range(named + ids)]
    if not {3, 14, 24}.issubset(types) or b'level="requireAdministrator"' not in data:
        raise SystemExit('Launcher icon or administrator manifest is missing')
    return {'machine': 'AMD64', 'subsystem': 'Windows GUI', 'managed': False,
            'administrator_manifest': True, 'icon': True, 'imports': imports,
            'sha256': hashlib.sha256(data).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--docker', default=shutil.which('docker') or str(Path.home() / '.docker/bin/docker'))
    parser.add_argument('--image', default='civ6-mesh-build:local')
    parser.add_argument('--native', action='store_true', help='Use the local Windows Rust toolchain and Windows SDK, without Docker')
    parser.add_argument('--verify-reproducible', action='store_true', help='Rebuild in a second clean target directory and compare SHA-256')
    args = parser.parse_args()
    version = re.search(r'^version\s*=\s*"([^"]+)"', (SOURCE / 'Cargo.toml').read_text(), re.M).group(1)
    output = ROOT / '.build/launcher-out'
    target = ROOT / '.build/launcher-target'
    output.mkdir(parents=True, exist_ok=True)
    target.mkdir(parents=True, exist_ok=True)
    if (SOURCE / 'icon.ico').read_bytes() != icon_bytes():
        raise SystemExit('Original icon resource differs from its deterministic renderer')
    flags = '-C target-feature=+crt-static --remap-path-prefix=/src=client/launcher'
    build = 'cargo xwin build --locked --offline --release --target ' + TARGET
    script = '''set -eu
cd /src
rustc --version
cargo xwin --version
cargo test --locked --offline --target-dir /target/host
export RUSTFLAGS='{flags}'
export CARGO_TARGET_DIR=/target/windows
{build}
cp /target/windows/{target}/release/Civ6Relay.exe /artifacts/Civ6Relay.exe
llvm-readobj --file-header --coff-imports --coff-resources /artifacts/Civ6Relay.exe > /artifacts/inspection.txt
'''.format(flags=flags, build=build, target=TARGET)
    if args.verify_reproducible:
        script += ('export CARGO_TARGET_DIR=/target/repro\n' + build + '\ncp /target/repro/' + TARGET +
                   '/release/Civ6Relay.exe /artifacts/Civ6Relay.repro.exe\n')
    if args.native:
        if os.name != 'nt':
            raise SystemExit('--native requires Windows with Rust MSVC and a Windows SDK')
        environment = os.environ.copy()
        environment.pop('RUSTFLAGS', None)
        subprocess.run(['cargo', 'test', '--locked', '--offline', '--manifest-path', str(SOURCE / 'Cargo.toml'),
                        '--target-dir', str(target / 'host')], check=True, env=environment)
        environment['CARGO_ENCODED_RUSTFLAGS'] = '\x1f'.join(['-C', 'target-feature=+crt-static',
            '--remap-path-prefix=' + str(SOURCE) + '=client/launcher'])
        for directory, filename in [('windows', 'Civ6Relay.exe')] + ([('repro', 'Civ6Relay.repro.exe')] if args.verify_reproducible else []):
            subprocess.run(['cargo', 'build', '--locked', '--offline', '--release', '--target', TARGET,
                '--manifest-path', str(SOURCE / 'Cargo.toml'), '--target-dir', str(target / directory)], check=True, env=environment)
            shutil.copyfile(str(target / directory / TARGET / 'release/Civ6Relay.exe'), str(output / filename))
        toolchain = subprocess.check_output(['rustc', '--version'], universal_newlines=True).strip()
    else:
        (output / 'build.sh').write_text(script)
        subprocess.run([args.docker, 'run', '--rm', '--pull=never', '--network', 'none',
            '-v', str(SOURCE) + ':/src:ro', '-v', str(output) + ':/artifacts', '-v', str(target) + ':/target',
            '-v', 'civ6-mesh-xwin:/xwin', '-e', 'XWIN_ARCH=x86_64', '-e', 'XWIN_CACHE_DIR=/xwin',
            '-e', 'RUSTUP_TOOLCHAIN=1.95.0', args.image, 'sh', '/artifacts/build.sh'], check=True)
        toolchain = '1.95.0'
    data = (output / 'Civ6Relay.exe').read_bytes()
    report = inspect_pe(data)
    report.update(version=version, rust_toolchain=toolchain, image=(None if args.native else args.image),
                  source_sha256={str(path.relative_to(SOURCE)): hashlib.sha256(path.read_bytes()).hexdigest()
                                 for path in sorted(SOURCE.rglob('*')) if path.is_file()})
    if args.verify_reproducible:
        if data != (output / 'Civ6Relay.repro.exe').read_bytes():
            raise SystemExit('Launcher rebuild was not reproducible')
        report['reproducible_rebuild'] = True
    destination = ROOT / 'client/windows/Civ6Relay.exe'
    destination.write_bytes(data)
    (output / 'build.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps(report, indent=2, ensure_ascii=False))
    print(str(destination))


if __name__ == '__main__':
    main()
