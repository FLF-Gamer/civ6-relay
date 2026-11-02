# 接入与 Key 配置

客户端通过 HTTP 获取连接配置、查询版本和管理 Key 会话。免费与 Key 模式共用一个 `civ6-relay.service`，由接入主程序管理一个组网进程，多个房间作为独立网络实例运行在该进程内。

## 安装

在完整服务端安装包目录执行免费模式安装：

```bash
sudo bash install.sh --endpoint SERVER_PUBLIC_IP --port 9527 --api-port 15888
sudo civ6-relay status
```

启用 Key 模式：

```bash
sudo bash install.sh --endpoint SERVER_PUBLIC_IP --api-port 15888 --enable-key --port-start 20000 --max-rooms 4 --max-players 6
```

将 `SERVER_PUBLIC_IP` 替换为服务器公网 IPv4。安装器创建配置、放行 firewalld 端口、启动服务并设置开机启动。云安全组需另外放行对应端口。

| 模式 | 对外端口 | 用途 |
| --- | --- | --- |
| 两种模式 | `15888/TCP` | HTTP 接入、版本查询和会话管理 |
| 免费模式 | `9527/TCP、UDP` | 共享虚拟局域网的组网与中继 |
| Key 模式 | `20000–20003/TCP、UDP` | 默认四个独立 Key 房间的组网与中继 |

`--api-port` 设置玩家填写的接入端口；`--port` 设置免费组网端口；`--port-start` 和 `--max-rooms` 设置 Key 房间的端口池。本机管理端口仅监听回环地址。

## 玩家连接

1. 完整解压通用 Windows 客户端，启动 `Civ6Relay.exe`。
2. 填写玩家昵称、服务器地址和接入端口，默认 `15888`。
3. 免费服务器直接点击“连接网络”。主动点击“获取 Key”会显示“此服务器无需 Key。”。
4. Key 服务器可点击“获取 Key”，或粘贴朋友提供的 Key；一起联机的玩家填写同一个 Key。
5. 所有玩家连接后，在文明6选择“多人游戏 → 局域网”，由一人创建游戏房间，其他人刷新加入。

客户端自动使用服务器返回的组网端口。服务器导出的专用 `windows.zip` 可继续填写免费组网端口直接连接。

## Key 房间

每个 Key 对应一个独立虚拟局域网。首次成功连接后，Key 有效期为连续 48 小时；重新连接或加入其他玩家不会延长。默认最多同时保留四个有效房间，每个房间六台在线设备。

获取 Key 时只创建记录。首次连接时分配房间端口和虚拟网段，并在组网进程中创建对应网络实例。相同 Key 的玩家进入同一网络；不同 Key 的广播和游戏数据相互隔离。游戏数据优先玩家直连，需要中继时由组网进程在对应网络内转发。

Key 到期后关闭对应网络实例、清理会话并释放端口，其他房间继续运行。尚未使用的 Key 七天后清理；默认每个源 IP 每分钟最多获取三个。

客户端每 30 秒续期在线会话。断开时撤销当前设备的组网授权，异常退出的会话最多保留 180 秒；会话续期不延长 Key 有效期。

## 配置与维护

运营配置位于 `/etc/civ6-relay/service.json`：

| 配置项 | 默认值 | 含义 |
| --- | --- | --- |
| `listen` | `0.0.0.0` | HTTP 监听地址 |
| `api_port` | `15888` | 客户端接入端口 |
| `key_required` | `false` | 是否要求 Key |
| `allow_generate` | `true` | 是否开放客户端获取 Key |
| `hours` | `48` | 新激活 Key 的有效小时数 |
| `max_players` | `6` | 每个房间的同时在线设备数 |
| `max_rooms` | `4` | 有效房间上限 |
| `port_start` | `20000` | Key 房间端口池起点 |
| `free_mesh_port` | `9527` | 免费模式组网端口 |

停止服务、修改配置并重新启动后生效。启动时会为配置的接入和组网端口补充 firewalld 规则，云安全组需同步调整。切换模式会断开当前组网连接。

```bash
sudo systemctl stop civ6-relay.service
sudo systemctl start civ6-relay.service
sudo systemctl status civ6-relay.service
```

服务停止时会同时关闭组网进程。组网进程意外退出后，接入主程序自动重建仍有效的房间。`/etc/civ6-relay` 包含服务器身份、共享接入信息、Key 数据库与会话，仅作私有备份。

## 版本查询

客户端“设置 → 关于与更新”的“查询服务端版本”请求大厅所填地址和接入端口的 `GET /v1/version`。查询无需昵称或 Key，不影响当前连接。

```json
{"server_version":"1.0.0","engine_version":"2.6.4-civ6.2","api_version":1}
```

免费与 Key 模式都提供版本接口。客户端中的 GitHub 地址和“下载新版”按钮用于打开项目主页及 Releases。
