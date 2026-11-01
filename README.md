# 文明6联机助手 3.3.0-preview

让 Windows 玩家通过虚拟局域网联机：优先玩家直连，无法直连时由自己的 Linux 服务器中继。文明6中选择 **多人游戏 → 局域网**。

## 服务端要求

- Linux x86_64，使用 systemd 管理服务。
- 系统 Python 3.6 或更新版本，路径为 `/usr/bin/python3`。
- 已安装 `ip`、`firewall-cmd`、`systemctl`，且 firewalld 正在运行。
- 可供玩家访问的公网 IPv4，以及一个空闲的 TCP/UDP 端口。

安装器按这些条件检查环境，不限定发行版名称。默认使用其他防火墙管理工具的系统，需要先确认 firewalld 的配置与现有规则兼容。

## 全新部署

可以在服务器直接下载下面的 Release 安装包，也可以从 [Releases](https://github.com/FLF-Gamer/civ6-relay/releases) 下载后，通过 SCP 或 SFTP 上传到服务器。

Release 完整安装包已包含服务端和 Windows 组件，推荐用于部署；Git 仓库保存源码和构建脚本，源码包需要另行准备组件后才能安装。

在服务器上执行：

```bash
curl -fLO https://github.com/FLF-Gamer/civ6-relay/releases/download/v3.3.0-preview/civ6-relay-server-3.3.0-preview-linux-amd64.tar.gz
tar -xzf civ6-relay-server-3.3.0-preview-linux-amd64.tar.gz
cd civ6-relay
sudo bash install.sh --endpoint SERVER_IP --port 9527
sudo civ6-relay status
sudo civ6-relay bundle
```

将 `SERVER_IP` 替换为服务器的公网 IPv4。示例端口为 `9527`，可以改为其他空闲端口；玩家填写相同端口。

云安全组或云防火墙需放行该端口的 **TCP 和 UDP 入站流量**。安装器会在服务器的 firewalld 中放行同一端口，保留已有规则。管理端口 `15887` 仅监听本机回环地址，无需向公网开放。

安装成功后，服务会立即启动并设置开机启动。程序位于 `/opt/civ6-relay`，配置位于 `/etc/civ6-relay`。

## 分发 Windows 客户端

`sudo civ6-relay bundle` 默认生成：

```text
/etc/civ6-relay/exports/windows.zip
```

将这个 ZIP 私下发给本次联机的玩家，并告知服务器 IP 和端口。同一服务器的所有玩家使用同一份 ZIP，各自在客户端填写昵称。

Release 中的 Windows 模板用于打包，不含服务器配置；玩家使用这里导出的 `windows.zip`。

**Windows ZIP 包含本服务器的共享接入信息，仅供联机玩家使用，不要提交到 Git 或作为 Release 附件。** `/etc/civ6-relay` 中的配置和密钥也应保密。服务端安装包不包含已部署服务器的接入信息。

再次导出时不会覆盖已有文件，请指定新的输出路径：

```bash
sudo civ6-relay bundle --output /root/windows-new.zip
```

再次导出沿用服务器现有接入信息和已安装的客户端模板。

## Windows 使用

适用于 Windows 10/11 x64。

1. 完整解压 `windows.zip`，双击 `Civ6Relay.exe`，允许管理员权限。请在解压后的文件夹启动，保留同目录的其他文件。
2. 填写自己的玩家昵称、服务器 IP 和端口，点击“连接”。支持中文昵称。
3. 所有玩家连接后，在文明6中选择“多人游戏 → 局域网”，由一人建房，其他人刷新列表并加入。
4. 结束后点击“断开”。默认关闭窗口也会断开，可取消“关闭窗口时自动断开”。

“网络状态”显示玩家、实际直连或中继路径及延迟。“延迟（Ping）”测量到玩家的延迟，无回应不等于游戏不通；“链路延迟”在中继时只代表到中继的延迟。

“运行日志”支持复制和导出；排查问题时点击“网络诊断”，复制完整结果，并注明谁建房、谁看不到房间。

虚拟网络承载游戏 UDP 和 ICMP，仅为游戏网段添加路由；普通上网和下载保持本地网络。直连时游戏数据在玩家之间传输，中继时会占用服务器带宽。

## 维护与排查

查看服务和已接入玩家：

```bash
sudo civ6-relay status
sudo systemctl status civ6-relay.service
```

- 无法连接：检查服务器 IP、客户端端口、云安全组和 firewalld，确认同一端口的 TCP、UDP 都已放行。
- 看不到玩家：确认双方使用同一服务器导出的 ZIP，并且都已连接。
- 看不到房间：确认选择“局域网”，游戏版本、DLC 和模组兼容，并允许文明6通过 Windows 防火墙。
- 提示组件缺失或损坏：先断开，再点击“检查组件”；更换 Windows 客户端时请先断开旧版，再完整解压新版。

当前安装脚本用于全新安装：检测到已有配置或服务时会停止，尚无原地升级命令。重复执行安装脚本不会覆盖现有接入信息。

卸载服务及本工具配置：

```bash
sudo civ6-relay uninstall
```

卸载会停止服务，删除服务器接入信息和导出的客户端包，并移除本工具新增的防火墙端口；原有规则及程序目录保留。

第三方组件源码、补丁和许可证见 Release 安装包内的 `vendor/easytier/licenses` 与 `vendor/linux-amd64/licenses`。

## 源码构建

完整构建需要 Python 3、Docker（命令在 PATH 中）和下载构建依赖的网络。依次准备组件、构建启动器，再生成公开发布包：

```bash
python3 scripts/build-deps.py
python3 scripts/build-mesh-fork.py
python3 scripts/build-launcher.py --verify-reproducible
python3 scripts/package.py --output-dir .build/release-public
```

启动器默认复用组网组件构建生成的 `civ6-mesh-build:local` 镜像和 Windows SDK 缓存，离线构建。生成的 `client/windows/Civ6Relay.exe` 不提交到 Git，由打包脚本加入发布包。

也可在 Windows x64 上单独构建启动器：安装 Python 3、Rust 1.95.0（MSVC 工具链）以及 Visual Studio Build Tools 的“使用 C++ 的桌面开发”（含 MSVC 和 Windows SDK），执行：

```powershell
$env:RUSTUP_TOOLCHAIN = '1.95.0'
python scripts/build-launcher.py --native --verify-reproducible
```

`--native` 使用本机编译器和 SDK，不使用 Docker。完整发布包仍需前述 Linux、Windows 组网组件；公开打包时不要传入私有 `--profile`。
