#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PYTHONIOENCODING=utf-8
umask 077
if [[ $EUID -ne 0 ]] || [[ $(uname -s) != Linux ]]; then
  echo '请在 Linux 服务器上用 root/sudo 执行 bash install.sh --endpoint SERVER_IP。' >&2
  exit 1
fi
source_dir=$(cd -- "$(dirname -- "$BASH_SOURCE")" && pwd)
for command_name in python3 ip firewall-cmd systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "缺少依赖：$command_name" >&2; exit 1; }
done
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)'
python3 "$source_dir/relayctl.py" plan "$@"
if [[ $(uname -m) != x86_64 ]] || [[ ! -d /run/systemd/system ]]; then
  echo '此发布包需要 Linux x86_64 和 systemd。' >&2
  exit 1
fi
for config_path in /etc/civ6-relay /etc/systemd/system/civ6-relay.service; do
  if [[ -e $config_path ]] || [[ -L $config_path ]]; then
    echo "已有配置：$config_path；不会重置现有密钥。" >&2
    exit 1
  fi
done
target_dir=/opt/civ6-relay
if [[ -L $target_dir ]] || [[ -L /usr/local/sbin/civ6-relay ]] ||
   { [[ -e $target_dir ]] && [[ ! -f $target_dir/.civ6-relay-managed ]]; } ||
   { [[ -e /usr/local/sbin/civ6-relay ]] && [[ ! -f $target_dir/.civ6-relay-managed ]]; }; then
  echo '同名安装路径不属于本工具，停止安装。' >&2
  exit 1
fi
# Hash bundled components once at installation; no periodic binary scans.
python3 - "$source_dir" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
for folder, names in [
    ('vendor/easytier/linux-x86_64', ['easytier-core', 'easytier-cli']),
    ('vendor/easytier/windows-x86_64', ['easytier-core.exe', 'easytier-cli.exe', 'wintun.dll', 'WinDivert64.sys']),
    ('vendor/linux-amd64', ['wg'])]:
    directory = root / folder
    hashes = json.loads((directory / 'checksums.json').read_text())
    for name in names:
        path = directory / name
        if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != hashes.get(name):
            raise SystemExit('组件缺失或校验失败：' + name)
for name in ('Start.cmd', 'Civ6Relay.exe', 'Civ6Relay.ps1', 'LiveMonitor.cs', 'README.txt'):
    if not (root / 'client/windows' / name).is_file():
        raise SystemExit('缺少客户端文件：' + name)
PY
install -d -m 755 "$target_dir" "$target_dir/bin" "$target_dir/client/windows/bin" "$target_dir/client/windows/licenses"
install -m 755 "$source_dir/relayctl.py" "$target_dir/relayctl.py"
for name in easytier-core easytier-cli; do
  install -m 755 "$source_dir/vendor/easytier/linux-x86_64/$name" "$target_dir/bin/$name"
done
install -m 755 "$source_dir/vendor/linux-amd64/wg" "$target_dir/bin/wg"
python3 - "$source_dir" "$target_dir" <<'PY'
import json, sys
from pathlib import Path
source, target = map(Path, sys.argv[1:])
hashes = json.loads((source / 'vendor/easytier/linux-x86_64/checksums.json').read_text())
hashes['wg'] = json.loads((source / 'vendor/linux-amd64/checksums.json').read_text())['wg']
(target / 'bin/checksums.json').write_text(json.dumps(hashes, indent=2) + '\n')
PY
install -m 644 "$source_dir/README.md" "$target_dir/README.md"
for name in Start.cmd Civ6Relay.exe Civ6Relay.ps1 LiveMonitor.cs README.txt; do
  install -m 644 "$source_dir/client/windows/$name" "$target_dir/client/windows/$name"
done
for name in easytier-core.exe easytier-cli.exe wintun.dll WinDivert64.sys checksums.json; do
  cp "$source_dir/vendor/easytier/windows-x86_64/$name" "$target_dir/client/windows/bin/$name"
done
cp -R "$source_dir/vendor/easytier/licenses/." "$target_dir/client/windows/licenses/"
cp -R "$source_dir/vendor/linux-amd64/licenses" "$target_dir/"
python3 - "$target_dir" <<'PY'
from pathlib import Path
import sys, zipfile
target = Path(sys.argv[1])
folder = target / 'client/windows'
with zipfile.ZipFile(str(target / 'client/windows-template.zip'), 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(folder.rglob('*')):
        if path.is_file():
            archive.write(str(path), str(path.relative_to(folder)))
PY
printf '%s\n' 'civ6-relay/v3' > "$target_dir/.civ6-relay-managed"
cat > /usr/local/sbin/civ6-relay <<'WRAPPER'
#!/usr/bin/env bash
export PYTHONIOENCODING=utf-8
exec /usr/bin/python3 /opt/civ6-relay/relayctl.py "$@"
WRAPPER
chmod 755 /usr/local/sbin/civ6-relay
/usr/local/sbin/civ6-relay init "$@"
