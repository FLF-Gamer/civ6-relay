# 可选 Key 服务

Key 模式默认关闭，由服务器管理员显式开启。开启后 Key 由玩家填写的服务器签发；当前开放免费获取，没有支付接口。普通自建服务器仍可使用原有的免费部署和客户端导出流程。

## 玩家使用

1. 完整解压通用 Windows 客户端，启动 `Civ6Relay.exe`。
2. 填写服务器提供者告知的地址和**接入端口**。
3. 需要新 Key 时点击 **获取 Key**，结果会自动填入输入框。点击 **复制** 后发给朋友；一起联机的玩家填写同一个 Key。
4. 已有朋友提供的 Key 时直接粘贴，填写昵称后点击 **连接网络**。不需要先连接一次。
5. 不需要 Key 的服务器可以留空直接连接。主动点击“获取 Key”时显示“此服务器无需 Key。”。
6. 在文明6选择 **多人游戏 → 局域网**，由一人创建房间，其他人刷新加入。

Key 从第一次成功签发连接配置起计算连续 48 小时，断开、重新连接或加入新玩家均不延长。客户端连接后显示到期时间。默认同一个 Key 最多同时连接 6 台设备，不同 Key 属于不同虚拟局域网。

新版通用客户端不含服务器地址、Key 或共享连接配置。旧的自建服务器专用 ZIP 含有该服务器的 `profile.json`，仍支持填写原组网端口直接连接；使用新版 Key 接口请使用通用客户端。

## 版本查询与客户端更新

客户端的“设置 → 关于与更新”显示当前客户端版本、GitHub 项目地址与“下载新版”按钮。更新时先断开旧客户端，再完整解压新版 ZIP；使用自建服务器专用 ZIP 的玩家仍需由管理员导出对应的客户端包。

点击“查询服务端版本”会向大厅中填写的服务器地址和接入端口发送 `GET /v1/version`。查询不需要昵称、Key 或连接授权，也不会生成 Key、激活房间或影响已连接的玩家。免费与 Key 模式都可使用此接口。

```json
{"server_version":"1.0.0","engine_version":"2.6.4-civ6.2","api_version":1}
```

该接口由本页的接入服务提供，使用 HTTPS 接入端口；EasyTier 原组网端口不提供 HTTP 接口。仅部署原免费组网服务时，需要先按下方说明增加免费接入服务，才能查询。旧 HTTP 服务返回 404、405 或 501 时，客户端提示“此服务器未提供版本查询接口。”；连接失败会另行提示地址、端口或证书问题。

此接口只查询正在运行的服务端版本，不检查 GitHub 最新版本，也不自动下载或安装更新。

## 部署需要 Key 的服务器

以下命令在解压后的完整服务端包目录执行，适用于 Linux x86_64、Python 3.6+ 和 systemd。此流程单独安装 Key 服务，不需要先创建免费共享网络。

```bash
sudo install -d -m 755 /opt/civ6-relay/bin
sudo install -m 755 relayctl.py keyservice.py /opt/civ6-relay/
sudo install -m 755 vendor/easytier/linux-x86_64/easytier-core vendor/easytier/linux-x86_64/easytier-cli vendor/linux-amd64/wg /opt/civ6-relay/bin/
sudo python3 /opt/civ6-relay/keyservice.py init --endpoint SERVER_PUBLIC_IP --enable-key --max-rooms 4 --max-players 6 --port-start 20000
sudo install -m 644 deploy/civ6-relay-keys.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now civ6-relay-keys.service
```

将 `SERVER_PUBLIC_IP` 换成服务器实际公网 IPv4。`--enable-key` 显式开启 Key 模式；不加时默认关闭，读取本机免费服务器的共享配置。初始化不会覆盖已有配置。

管理接口默认只监听 `127.0.0.1:15888`。在现有 HTTPS 站点内代理 `/v1/`，例如 Nginx 的 TLS `server` 块中加入：

```nginx
location /v1/ {
    client_max_body_size 4k;
    proxy_pass http://127.0.0.1:15888;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_connect_timeout 5s;
    proxy_read_timeout 30s;
}
```

客户端填写该 HTTPS 站点的域名或证书覆盖的 IP、HTTPS 端口，例如 `443`。证书需要被 Windows 信任，地址中不填写 `https://`、路径或端口。

也可直接使用已有证书启动 TLS 接口：

```bash
sudo python3 /opt/civ6-relay/keyservice.py serve --listen 0.0.0.0 --port 443 --cert /etc/civ6-relay-tls/fullchain.pem --cert-key /etc/civ6-relay-tls/privkey.pem
```

直接 TLS 与默认服务应二选一；同一配置只允许启动一个进程。部署前确认端口未被其他服务占用。

云安全组和服务器防火墙需放行：

| 端口 | 用途 |
| --- | --- |
| HTTPS 接入端口 / TCP | 获取 Key、连接配置和在线会话管理 |
| `20000–20003` / TCP、UDP | 默认 4 个独立虚拟局域网的组网与中继 |
| `15888`、`21100–21103` | 仅本机管理端口，不向公网放行 |

Key 服务不会自动修改防火墙。服务器不创建虚拟网卡，不需要开启 IP 转发或 NAT。游戏数据由组网核心直接处理，Python 接口只处理连接管理。

## 让通用客户端连接免费的自建服务器

普通 `install.sh` 部署和 `civ6-relay bundle` 导出继续免费使用。若还需要通用客户端的“获取 Key / 直接连接”接口，可在已部署的免费服务器上增加本服务：

```bash
sudo python3 /opt/civ6-relay/keyservice.py init --endpoint SERVER_PUBLIC_IP --free-profile /etc/civ6-relay/common-profile.json --free-mesh-port 9527
```

之后按上一节安装服务文件和 HTTPS 代理。客户端填写 HTTPS 接入端口；返回的配置会让组网核心使用 `--free-mesh-port` 指定的原组网端口。免费服务器的连接请求直接返回配置，不附带 Key 模式提示，也不建立计时会话。

`--free-profile` 必须使用该服务器自己导出的共享配置。原有组网服务继续运行；该模式不创建独立 Key 网络。

## 配置与维护

私有状态保存在 `/var/lib/civ6-relay-keys`。备份该目录即可保留 Key、到期时间、房间身份与会话；不要上传到 GitHub 或公开分发。客户端只保存当前填写的服务器和 Key，后台凭据不进入日志。

停止服务后可修改 `service.json`，然后重新启动：

| 配置 | 默认值 | 含义 |
| --- | --- | --- |
| `key_required` | `false` | 是否启用 Key；关闭时使用免费服务器的 `free-profile.json` 和端口 |
| `allow_generate` | `true` | 是否开放客户端获取新 Key；关闭后已签发的 Key 仍可连接 |
| `hours` | `48` | 新激活 Key 的有效小时数；不改变已有到期时间 |
| `max_players` | `6` | 每个 Key 的同时在线设备数 |
| `max_rooms` | `4` | 同时保留的有效 Key 网络数 |
| `port_start` | `20000` | 组网端口池起点，须同步更新防火墙 |

未使用的 Key 不启动核心进程、不占组网端口，7 天后清理；默认每个源 IP 每分钟最多获取 3 个。激活后保留该网络至到期，空房间也计入房间上限。

客户端每 30 秒续期一次在线会话，断开后撤销该设备的组网授权。网络异常退出的会话最多保留 180 秒；会话续期不会延长 Key 的 48 小时。取消“关闭窗口时自动断开连接”后，独立后台进程继续维护会话。

客户端按到期时间结束连接。组网核心自身也会清理过期授权，其现有周期最长为 60 秒；服务端拒绝新的过期连接不受这个清理周期影响。

```bash
sudo systemctl status civ6-relay-keys.service
sudo journalctl -u civ6-relay-keys.service -n 50
sudo systemctl restart civ6-relay-keys.service
```

## 验证范围

服务测试覆盖获取、共享、连接、人数限制、到期、重启恢复、会话释放和免费模式。`tests/key_network_integration.py` 使用真实 Linux 组网核心和隔离网络验证玩家发现、P2P、UDP、广播、授权撤销与到期；没有启动文明6游戏。

Windows UI 测试覆盖获取按钮、免费提示、同 Key 提醒及第一次连接请求；需在 Windows PowerShell 5.1 / STA 环境运行 `tests/windows-ui-smoke.ps1`。HTTP 接口集成可运行 `tests/client-key.Tests.ps1`。
